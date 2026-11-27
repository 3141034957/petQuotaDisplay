using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json.Nodes;

namespace PetQuota;

public record Quota(string Label, int? Percent, string? Detail = null, DateTimeOffset? Reset = null);

public static class Quotas
{
    private static readonly HttpClient Http = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
        { Timeout = TimeSpan.FromSeconds(30), MaxResponseContentBufferSize = 2 * 1024 * 1024 };

    static double? Number(JsonNode? v) => double.TryParse(v?.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture,
        out var n) && double.IsFinite(n) ? n : null;
    static int Percent(double n) => (int)Math.Round(Math.Clamp(n, 0, 100), MidpointRounding.AwayFromZero);
    static DateTimeOffset? Time(JsonNode? value)
    {
        if (long.TryParse(value?.ToString(), out var n))
        {
            try { return n > 100_000_000_000 ? DateTimeOffset.FromUnixTimeMilliseconds(n) : DateTimeOffset.FromUnixTimeSeconds(n); }
            catch (ArgumentOutOfRangeException) { return null; }
        }
        return DateTimeOffset.TryParse(value?.ToString(), out var t) ? t : null;
    }

    public static List<Quota> Parse(Platform platform, JsonNode root)
    {
        List<Quota> rows = [];
        if (platform == Platform.Codex)
        {
            var groups = root["rateLimitsByLimitId"] as JsonObject;
            var primary = root["rateLimits"];
            void Add(JsonNode? group, string prefix)
            {
                foreach (var key in new[] { "primary", "secondary" })
                {
                    var w = group?[key];
                    if (Number(w?["usedPercent"]) is not double used) continue;
                    var window = Number(w?["windowDurationMins"]) switch { 300 => "5 小时", 10080 => "每周", double mins => $"{mins:g} 分钟", _ => key };
                    rows.Add(new(prefix + window, Percent(100 - used), Reset: Time(w?["resetsAt"])));
                }
            }
            Add(primary, "");
            if (rows.Count == 0) Add(groups?["codex"], "");
            if (groups != null) foreach (var (id, group) in groups)
                if (id != "codex" && id != primary?["limitId"]?.ToString()) Add(group, (group?["limitName"]?.ToString() ?? id) + " · ");
        }
        else if (platform == Platform.Gemini)
        {
            foreach (var b in root["buckets"] as JsonArray ?? [])
                if (b?["modelId"]?.ToString() is string name && Number(b["remainingFraction"]) is double f && f is >= 0 and <= 1)
                    rows.Add(new(name, Percent(f * 100), Reset: Time(b["resetTime"])));
        }
        else
        {
            if (Number(root["code"]) is double code && code != 0 && code != 200) throw new InvalidDataException("CodeBuddy 拒绝了额度查询。");
            var data = root["data"]?["data"] ?? root["data"] ?? root;
            var items = data["resources"] as JsonArray ?? data["Response"]?["Data"]?["Accounts"] as JsonArray;
            IEnumerable<JsonNode?> plans = items?.AsEnumerable() ?? Enumerable.Repeat(data, 1);
            foreach (var p in plans)
            {
                var total = Number(p?["CycleCapacitySizePrecise"] ?? p?["total"] ?? p?["limit_num"] ?? p?["limitNum"]);
                var left = Number(p?["CycleCapacityRemainPrecise"] ?? p?["remaining"] ?? p?["remain"])
                    ?? total - Number(p?["used_num"] ?? p?["usedNum"] ?? p?["credit"]);
                bool unlimited = total == -1 || bool.TryParse((p?["Unlimited"] ?? p?["unlimited"])?.ToString(), out var flag) && flag;
                if (left == null && !unlimited) continue;
                rows.Add(new((p?["PackageName"] ?? p?["name"] ?? p?["package_name"])?.ToString() ?? "Credits",
                    !unlimited && total > 0 && left.HasValue ? Percent(100 * left.Value / total.Value) : null,
                    unlimited ? "不限量" : $"{Math.Max(0, left!.Value):g} Credits", Time(p?["CycleResetTime"] ?? p?["ExpiredTime"])));
            }
        }
        return rows.Count == 0 ? throw new InvalidDataException("平台未提供可显示的额度。") : rows;
    }

    public static async Task<List<Quota>> ReadAsync(Workspace store, Account account, CancellationToken cancellation)
    {
        if (account.Kind == Credential.Key) throw new InvalidOperationException("API Key 用量请查看平台控制台。");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(40));
        var token = deadline.Token;
        async Task<JsonNode> Post(string uri, string secret, object body)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, uri) {
                Content = JsonContent.Create(body, options: System.Text.Json.JsonSerializerOptions.Default)
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secret);
            if (account.Platform == Platform.CodeBuddy)
                foreach (var (key, value) in new[] { ("X-User-Id", account.User), ("X-Enterprise-Id", account.Enterprise),
                         ("X-Tenant-Id", account.Enterprise), ("X-Domain", account.Domain) })
                    if (!string.IsNullOrWhiteSpace(value)) request.Headers.Add(key, value);
            using var response = await Http.SendAsync(request, token);
            if (!response.IsSuccessStatusCode) throw new HttpRequestException($"额度查询返回 HTTP {(int)response.StatusCode}。", null, response.StatusCode);
            return JsonNode.Parse(await response.Content.ReadAsStringAsync(token)) ?? throw new InvalidDataException("平台返回空内容。");
        }
        JsonNode result;
        if (account.Platform == Platform.Codex)
        {
            var home = store.Home(account);
            result = await Clients.ReadCodexAsync(Clients.Prepare(store, account, Clients.Resolve(Platform.Codex), account.Id, home), token);
        }
        else if (account.Platform == Platform.Gemini)
        {
            const string url = "https://cloudcode-pa.googleapis.com/v1internal:";
            var auth = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(store.Home(account), ".gemini", "oauth_creds.json"), token));
            var secret = auth?["access_token"]?.GetValue<string>() ?? throw new InvalidDataException("需要重新导入 Gemini 登录。");
            var project = account.Project;
            if (string.IsNullOrEmpty(project))
                project = (await Post(url + "loadCodeAssist", secret, new { metadata = new { ideType = "IDE_UNSPECIFIED", platform = "PLATFORM_UNSPECIFIED", pluginType = "GEMINI" }, mode = "HEALTH_CHECK" }))["cloudaicompanionProject"]?.GetValue<string>();
            if (string.IsNullOrEmpty(project)) throw new InvalidDataException("此账号需要 Google Cloud 项目 ID。");
            result = await Post(url + "retrieveUserQuota", secret, new { project });
        }
        else
        {
            var url = $"https://www.codebuddy.{(account.China ? "cn" : "ai")}/v2/billing/meter/";
            var secret = store.Secrets.Reveal(account.Secret!);
            var now = DateTime.Now;
            result = account.Enterprise != null ? await Post(url + "get-enterprise-user-usage", secret, new { })
                : await Post(url + "get-user-resource", secret, new { PageNumber = 1, PageSize = 100, ProductCode = "p_tcaca",
                    Status = new[] { 0, 3 }, PackageEndTimeRangeBegin = now.ToString("yyyy-MM-dd HH:mm:ss"),
                    PackageEndTimeRangeEnd = now.AddYears(100).ToString("yyyy-MM-dd HH:mm:ss") });
        }
        return Parse(account.Platform, result);
    }
}
