using System.Text.Json;
using System.Text.Json.Nodes;

namespace PetQuota;

public enum Platform { Codex, CodeBuddy, Gemini }
public enum Credential { Login, Key, Token }
public record Account(Guid Id, string Name, Platform Platform, Credential Kind, string? Secret = null,
    bool China = false, string? Project = null, string? User = null, string? Enterprise = null, string? Domain = null)
{
    public override string ToString() => $"{Platform} · {Name}";
}
public record Instance(Guid Id, string Name, Guid AccountId, string Project, Guid? GatewayId = null);
public record Member(Guid Id, string Name, Guid AccountId, string LocalSecret)
{
    public override string ToString() => Name;
}
public record WorkspaceState
{
    public Account[] Accounts { get; init; } = [];
    public Instance[] Instances { get; init; } = [];
    public Member[] Members { get; init; } = [];
    public Dictionary<Platform, Guid> Selected { get; init; } = [];
    public int Port { get; init; } = 14550;
    public Platform OrbPlatform { get; init; } = Platform.Codex;
}
public interface ISecrets
{
    string Protect(string value);
    string Reveal(string value);
}

public sealed class Workspace(string root, ISecrets secrets)
{
    public string Root { get; } = root;
    public ISecrets Secrets { get; } = secrets;
    WorkspaceState state = Read<WorkspaceState>(Path.Combine(root, "settings.json")) ?? new();
    public WorkspaceState State => Volatile.Read(ref state);
    public string Home(Account account) => Path.Combine(Root, "accounts", account.Id.ToString("N"));
    public static T? Read<T>(string path) => File.Exists(path) ?
        JsonSerializer.Deserialize<T>(File.ReadAllBytes(path)) ?? throw new InvalidDataException("配置文件为空。") : default;

    public static void Write(string path, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllBytes(temp, data); File.Move(temp, path, true); }
        finally { File.Delete(temp); }
    }
    public void Save(WorkspaceState state)
    {
        Write(Path.Combine(Root, "settings.json"), JsonSerializer.SerializeToUtf8Bytes(state));
        Volatile.Write(ref this.state, state);
    }
    public Account? Current(Platform platform) =>
        State.Accounts.FirstOrDefault(a => a.Id == State.Selected.GetValueOrDefault(platform) && a.Platform == platform)
        ?? State.Accounts.FirstOrDefault(a => a.Platform == platform);
    public void Select(Account account) => Save(State with {
        Selected = new(State.Selected) { [account.Platform] = account.Id }, OrbPlatform = account.Platform
    });

    public Account Add(string name, Platform platform, Credential kind, string input, bool china = false, string? project = null)
    {
        name = name.Trim();
        if (name.Length is 0 or > 80) throw new ArgumentException("请输入 1 至 80 字的账号名称。");
        var account = new Account(Guid.NewGuid(), name, platform, kind, China: china, Project: project?.Trim());
        var home = Home(account);
        try
        {
            if (kind == Credential.Login)
            {
                using var file = File.OpenRead(input);
                if (file.Length is 0 or > 2097152) throw new InvalidDataException("请选择小于 2 MB 的登录 JSON。");
                var json = JsonNode.Parse(file) ?? throw new InvalidDataException("登录 JSON 为空。");
                switch (platform)
                {
                    case Platform.Codex:
                        if (json["tokens"] is JsonObject tokens) {
                            Token(tokens["access_token"]); Token(tokens["refresh_token"]);
                            Write(Path.Combine(home, "auth.json"), JsonSerializer.SerializeToUtf8Bytes(json));
                        } else account = account with { Kind = Credential.Key, Secret = Secrets.Protect(Token(json["OPENAI_API_KEY"])) };
                        break;
                    case Platform.Gemini:
                        Token(json["access_token"]);
                        account = account with { Project = string.IsNullOrWhiteSpace(project) ? json["project_id"]?.ToString() : project.Trim() };
                        Write(Path.Combine(home, ".gemini", "oauth_creds.json"), JsonSerializer.SerializeToUtf8Bytes(json));
                        break;
                    case Platform.CodeBuddy:
                        var data = json["data"] ?? json;
                        account = account with { Kind = Credential.Token, Secret = Secrets.Protect(Token(data["access_token"] ?? data["accessToken"])),
                            User = (data["uid"] ?? data["userId"])?.ToString(), Enterprise = (data["enterprise_id"] ?? data["enterpriseId"])?.ToString(), Domain = data["domain"]?.ToString() };
                        break;
                }
            }
            else
            {
                if (kind == Credential.Token && platform != Platform.CodeBuddy) throw new ArgumentException("此平台不支持访问令牌导入。");
                account = account with { Secret = Secrets.Protect(Token(JsonValue.Create(input.Trim()))) };
            }
            if (platform == Platform.Gemini)
            {
                var auth = new { security = new { auth = new { selectedType = account.Kind == Credential.Key ? "gemini-api-key" : "oauth-personal" } } };
                Write(Path.Combine(home, ".gemini", "settings.json"), JsonSerializer.SerializeToUtf8Bytes(auth));
            }
            Save(State with { Accounts = [..State.Accounts, account], Selected = new(State.Selected) { [platform] = account.Id }, OrbPlatform = platform });
            return account;
        }
        catch { if (Directory.Exists(home)) Directory.Delete(home, true); throw; }
    }

    static string Token(JsonNode? node)
    {
        var value = node?.GetValue<string>() ?? "";
        if (value.Length is 0 or > 16384 || value.Any(c => c < 33 || c > 126)) throw new InvalidDataException("缺少有效的登录凭据。");
        return value;
    }

    public void RemoveAccount(Account account)
    {
        if (State.Instances.Any(i => i.AccountId == account.Id) || State.Members.Any(m => m.AccountId == account.Id))
            throw new InvalidOperationException("请先移除账号绑定的实例和网关成员。");
        var selected = new Dictionary<Platform, Guid>(State.Selected);
        if (selected.GetValueOrDefault(account.Platform) == account.Id) selected.Remove(account.Platform);
        var home = Home(account);
        var moved = Directory.Exists(home);
        var trash = home + ".removing-" + Guid.NewGuid().ToString("N");
        if (moved) Directory.Move(home, trash);
        try { Save(State with { Accounts = State.Accounts.Where(a => a.Id != account.Id).ToArray(), Selected = selected }); }
        catch { if (moved) Directory.Move(trash, home); throw; }
        if (moved) Directory.Delete(trash, true);
    }

    public Instance SaveInstance(string name, Guid accountId, string project, Guid? memberId, Guid? existingId = null)
    {
        if (string.IsNullOrWhiteSpace(name) || !Path.IsPathFullyQualified(project) || !Directory.Exists(project))
            throw new ArgumentException("请输入名称并选择现有项目目录。");
        var account = State.Accounts.Single(a => a.Id == accountId);
        if (memberId != null && (account.Platform != Platform.Codex || !State.Members.Any(m => m.Id == memberId)))
            throw new ArgumentException("请选择有效的 Codex 网关成员。");
        var item = new Instance(existingId ?? Guid.NewGuid(), name.Trim(), accountId, Path.GetFullPath(project), memberId);
        if (existingId != null && !State.Instances.Any(i => i.Id == existingId)) throw new InvalidOperationException("找不到原实例。");
        Save(State with { Instances = existingId == null ? [..State.Instances, item]
            : State.Instances.Select(i => i.Id == existingId ? item : i).ToArray() });
        return item;
    }

    public Member AddMember(Account account)
    {
        if (account.Platform != Platform.Codex || account.Kind != Credential.Key || account.Secret == null)
            throw new ArgumentException("请选择保存 OpenAI API Key 的 Codex 账号。");
        if (State.Members.Any(m => m.AccountId == account.Id)) throw new ArgumentException("该账号已加入网关。");
        var key = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
        var member = new Member(Guid.NewGuid(), account.Name, account.Id, Secrets.Protect(key));
        Save(State with { Members = [..State.Members, member] });
        return member;
    }
}
