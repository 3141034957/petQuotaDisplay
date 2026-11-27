using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PetQuota;

public static class Clients
{
    private static readonly Dictionary<Platform, (string Name, string Package)> Tools = new() {
        [Platform.Codex] = ("codex", "@openai/codex"), [Platform.CodeBuddy] = ("codebuddy", "@tencent-ai/codebuddy-code"),
        [Platform.Gemini] = ("gemini", "@google/gemini-cli")
    };

    public static ProcessStartInfo Resolve(Platform platform)
    {
        var (name, package) = Tools[platform];
        var variable = name.ToUpperInvariant() + "_CLI_PATH";
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(path => path.Trim().Trim('"')).Where(Path.IsPathFullyQualified).Distinct().ToArray();
        var custom = Environment.GetEnvironmentVariable(variable);
        if (!string.IsNullOrEmpty(custom))
        {
            if (!Path.IsPathFullyQualified(custom) || !File.Exists(custom) || !custom.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                throw new FileNotFoundException(variable + " 应指向已安装的 .exe 文件。");
            return new(custom) { UseShellExecute = false };
        }
        foreach (var dir in dirs)
        {
            var native = Path.Combine(dir, name + ".exe");
            if (File.Exists(native)) return new(native) { UseShellExecute = false };
            var folder = Path.Combine(dir, "node_modules", package);
            var manifest = Path.Combine(folder, "package.json");
            if (!File.Exists(manifest)) continue;
            var bin = JsonNode.Parse(File.ReadAllText(manifest))?["bin"];
            var script = bin is JsonObject ? bin[name]?.ToString() : bin?.ToString();
            var node = dirs.Select(p => Path.Combine(p, "node.exe")).FirstOrDefault(File.Exists);
            if (script == null || node == null || !File.Exists(Path.Combine(folder, script))) continue;
            var info = new ProcessStartInfo(node) { UseShellExecute = false };
            info.ArgumentList.Add(Path.GetFullPath(Path.Combine(folder, script)));
            return info;
        }
        throw new FileNotFoundException($"找不到 {name}。请安装官方 CLI，并将它加入 PATH。");
    }

    public static ProcessStartInfo Prepare(Workspace store, Account account, ProcessStartInfo info, Guid instance,
        string directory, Member? member = null)
    {
        info.WorkingDirectory = directory;
        info.UseShellExecute = false;
        var home = store.Home(account);
        Directory.CreateDirectory(home);
        string[] clean = ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "PETQUOTA_KEY",
            "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA",
            "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT_ID",
            "CODEBUDDY_BASE_URL", "CODEBUDDY_CUSTOM_HEADERS", "CODEBUDDY_API_KEY", "CODEBUDDY_AUTH_TOKEN",
            "CODEBUDDY_INTERNET_ENVIRONMENT", "CODEBUDDY_COPILOT_INTERNET_ENVIRONMENT", "CODEBUDDY_AUTH_SNAPSHOT_PATH",
            "CODEBUDDY_AUTH_SESSION_FILE_DESCRIPTOR", "CODEBUDDY_AUTH_TOKEN_FILE_DESCRIPTOR", "CODEBUDDY_API_KEY_FILE_DESCRIPTOR"];
        foreach (var key in clean) info.Environment.Remove(key);
        switch (account.Platform)
        {
            case Platform.Codex:
                info.Environment["CODEX_HOME"] = home;
                void Config(string setting) { info.ArgumentList.Add("-c"); info.ArgumentList.Add(setting); }
                Config("cli_auth_credentials_store=\"file\"");
                if (member != null || account.Kind == Credential.Key)
                {
                    var url = member == null ? "https://api.openai.com/v1" : $"http://127.0.0.1:{store.State.Port}/v1";
                    info.Environment["PETQUOTA_KEY"] = store.Secrets.Reveal(member?.LocalSecret ?? account.Secret!);
                    Config("model_provider=\"petquota\"");
                    Config("model_providers.petquota.name=\"PetQuota\"");
                    Config($"model_providers.petquota.base_url=\"{url}\"");
                    Config("model_providers.petquota.env_key=\"PETQUOTA_KEY\"");
                    Config("model_providers.petquota.wire_api=\"responses\"");
                    Config("model_providers.petquota.supports_websockets=false");
                }
                break;
            case Platform.CodeBuddy:
                var config = Path.Combine(store.Root, "instances", instance.ToString("N"), "codebuddy");
                Directory.CreateDirectory(config);
                info.Environment["CODEBUDDY_CONFIG_DIR"] = config;
                info.Environment[account.Kind == Credential.Key ? "CODEBUDDY_API_KEY" : "CODEBUDDY_AUTH_TOKEN"] = store.Secrets.Reveal(account.Secret!);
                if (account.China) info.Environment["CODEBUDDY_INTERNET_ENVIRONMENT"] = "internal";
                break;
            case Platform.Gemini:
                info.Environment["GEMINI_CLI_HOME"] = home;
                if (account.Kind == Credential.Key) info.Environment["GEMINI_API_KEY"] = store.Secrets.Reveal(account.Secret!);
                else if (!string.IsNullOrEmpty(account.Project)) info.Environment["GOOGLE_CLOUD_PROJECT"] = account.Project;
                break;
        }
        return info;
    }

    public static void Launch(Workspace store, Instance instance, bool gatewayReady)
    {
        if (!Directory.Exists(instance.Project)) throw new DirectoryNotFoundException("项目目录已移动。");
        var account = store.State.Accounts.Single(a => a.Id == instance.AccountId);
        var member = instance.GatewayId is Guid id ? store.State.Members.Single(m => m.Id == id) : null;
        if (member != null && !gatewayReady) throw new InvalidOperationException("请先启动本机网关。");
        var info = Prepare(store, account, Resolve(account.Platform), instance.Id, instance.Project, member);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("无法启动实例。");
    }

    public static async Task<JsonNode> ReadCodexAsync(ProcessStartInfo info, CancellationToken cancellation)
    {
        info.ArgumentList.Add("app-server");
        info.CreateNoWindow = true;
        info.RedirectStandardInput = info.RedirectStandardOutput = info.RedirectStandardError = true;
        info.StandardInputEncoding = info.StandardOutputEncoding = new UTF8Encoding(false);
        using var process = Process.Start(info) ?? throw new InvalidOperationException("Codex 启动失败。");
        process.BeginErrorReadLine();
        async Task<JsonNode> Reply(int id)
        {
            while (await process.StandardOutput.ReadLineAsync(cancellation) is string line)
            {
                var json = JsonNode.Parse(line);
                if (json?["id"]?.ToString() != id.ToString()) continue;
                if (json["error"] != null) throw new InvalidOperationException("Codex 未返回额度，请确认账号已登录。");
                return json["result"] ?? throw new InvalidDataException("Codex 返回结果为空。");
            }
            throw new IOException("Codex 连接已关闭。");
        }
        async Task Send(object packet) {
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(packet).AsMemory(), cancellation);
            await process.StandardInput.FlushAsync(cancellation);
        }
        try
        {
            await Send(new { id = 1, method = "initialize", @params = new {
                clientInfo = new { name = "pet-quota-display", title = "PetQuota", version = "1.0" },
                capabilities = new { experimentalApi = true } } });
            await Reply(1);
            await Send(new { method = "initialized" });
            await Send(new { id = 2, method = "account/read", @params = new { refreshToken = false } });
            if ((await Reply(2))["account"] == null) throw new UnauthorizedAccessException("Codex 账号已退出，请重新登录或导入。");
            await Send(new { id = 3, method = "account/rateLimits/read", @params = (object?)null });
            return await Reply(3);
        }
        finally
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            await process.WaitForExitAsync();
        }
    }
}
