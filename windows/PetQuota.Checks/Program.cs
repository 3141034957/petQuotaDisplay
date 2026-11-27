using System.Diagnostics;
using System.IO.Pipelines;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using PetQuota;

if (args.Contains("app-server"))
{
    while (Console.ReadLine() is string packet)
    {
        var json = JsonNode.Parse(packet)!;
        if (json["method"]?.ToString() == "initialize") Console.WriteLine("""{"id":1,"result":{}}""");
        if (json["method"]?.ToString() == "account/read") Console.WriteLine("""{"id":2,"result":{"account":{"type":"chatgpt"}}}""");
        if (json["method"]?.ToString() == "account/rateLimits/read")
        { Console.WriteLine("""{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}}"""); break; }
    }
    return;
}
void Check(bool test, string name) { if (!test) throw new Exception(name); Console.WriteLine("PASS " + name); }
var temp = Path.Combine(Path.GetTempPath(), "petquota-check-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(temp);
try
{
    var secrets = new FixtureSecrets();
    var store = new Workspace(temp, secrets);
    var key = store.Add("Dev", Platform.Codex, Credential.Key, "fixture-upstream");
    var member = store.AddMember(key);
    var local = secrets.Reveal(member.LocalSecret);
    Check(!File.ReadAllText(Path.Combine(temp, "settings.json")).Contains("fixture-upstream"), "no plaintext key in settings");
    var file = Path.Combine(temp, "auth.json");
    File.WriteAllText(file, """{"tokens":{"access_token":"fixture-access","refresh_token":"fixture-refresh"}}""");
    var account = store.Add("Login", Platform.Codex, Credential.Login, file);
    var second = store.Add("Other", Platform.Codex, Credential.Login, file);
    Check(File.Exists(Path.Combine(store.Home(account), "auth.json")) && store.Home(account) != store.Home(second), "isolated Codex profiles");
    File.WriteAllText(file, """{"access_token":"gemini-token"}""");
    var gemini = store.Add("Gemini", Platform.Gemini, Credential.Login, file);
    Check(File.Exists(Path.Combine(store.Home(gemini), ".gemini", "oauth_creds.json")), "isolated Gemini profile");
    File.WriteAllText(file, """{"access_token":"buddy-token","enterprise_id":"team"}""");
    var buddy = store.Add("Buddy", Platform.CodeBuddy, Credential.Login, file);
    Check(buddy.Kind == Credential.Token && buddy.Enterprise == "team", "CodeBuddy login import");
    var instance = store.SaveInstance("Project", account.Id, temp, member.Id);
    var plan = Clients.Prepare(store, account, new ProcessStartInfo("unused"), instance.Id, temp, member);
    Check(plan.Environment["PETQUOTA_KEY"] == local && !plan.ArgumentList.Any(s => s.Contains(local)), "gateway key stays in child environment");
    Check(plan.WorkingDirectory == temp && plan.Environment["CODEX_HOME"] == store.Home(account), "instance binds account and project");
    Check(new Workspace(temp, secrets).State.Instances.Single().Id == instance.Id, "workspace survives restart");
    var edit = store.SaveInstance("Renamed", second.Id, temp, null, instance.Id);
    Check(store.State.Instances.Single() == edit && edit.Id == instance.Id, "editing retains instance identity");
    try { store.RemoveAccount(second); throw new Exception("bound account was removed"); }
    catch (InvalidOperationException) { Check(store.State.Accounts.Contains(second), "bound account protected"); }
    store.RemoveAccount(account);
    Check(!Directory.Exists(store.Home(account)) && !store.State.Accounts.Contains(account), "removed profile retired");
    var process = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
    if (Path.GetFileNameWithoutExtension(process.FileName).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
        process.ArgumentList.Add(typeof(FixtureSecrets).Assembly.Location);
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
    var codex = Quotas.Parse(Platform.Codex, await Clients.ReadCodexAsync(process, timeout.Token)).Single();
    Check(codex.Percent == 80 && codex.Label == "5 小时", "Codex app-server protocol");
    Check(Quotas.Parse(Platform.Gemini, JsonNode.Parse("""{"buckets":[{"modelId":"gemini","remainingFraction":0.73}]}""")!).Single().Percent == 73, "Gemini model quota");
    Check(Quotas.Parse(Platform.CodeBuddy, JsonNode.Parse("""{"data":{"limit_num":50,"used_num":15}}""")!).Single().Percent == 70, "CodeBuddy credits");

    var fixture = new FixtureUpstream();
    await using var gateway = new Gateway(store, fixture);
    await gateway.StartAsync(0);
    using var client = new HttpClient { BaseAddress = new Uri(gateway.Address!), Timeout = TimeSpan.FromSeconds(5) };
    Check((await client.GetAsync("/v1/models")).StatusCode == HttpStatusCode.Unauthorized, "local bearer required");
    client.DefaultRequestHeaders.Authorization = new("Bearer", local);
    Check((await client.GetAsync("/unknown")).StatusCode == HttpStatusCode.NotFound, "fixed upstream routes");
    using var limited = await client.GetAsync("/v1/models");
    Check(limited.StatusCode == HttpStatusCode.TooManyRequests && limited.Headers.RetryAfter?.Delta == TimeSpan.FromSeconds(9),
        "upstream status and retry delay preserved");
    using var request = new HttpRequestMessage(HttpMethod.Post, "/v1/responses") {
        Content = new StringContent("""{"model":"test-model","input":"private-input"}""", Encoding.UTF8, "application/json") };
    using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
    using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
    Check(response.IsSuccessStatusCode && await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(3)) == "data: first",
        "first SSE event arrives before upstream completion");
    await fixture.Events.Writer.WriteAsync("data: [DONE]\n\n"u8.ToArray());
    await fixture.Events.Writer.CompleteAsync();
    Check((await reader.ReadToEndAsync().WaitAsync(TimeSpan.FromSeconds(3))).Contains("[DONE]"), "loopback SSE completion");
    var until = DateTime.UtcNow.AddSeconds(2);
    while (gateway.Records.Length < 2 && DateTime.UtcNow < until) await Task.Delay(10);
    Check(gateway.Records.Any(r => r.Model == "test-model" && r.Member == member.Name), "request attributed to member and model");
    var log = File.ReadAllText(Path.Combine(temp, "gateway-history.json"));
    Check(!log.Contains(local) && !log.Contains("fixture-upstream") && !log.Contains("private-input"), "no keys or prompts in logs");
    await gateway.StopAsync();
    Check(!gateway.Running, "gateway stops");
}
finally { Directory.Delete(temp, true); }

sealed class FixtureSecrets : ISecrets
{
    public string Protect(string value) => Convert.ToBase64String(Encoding.UTF8.GetBytes(value));
    public string Reveal(string value) => Encoding.UTF8.GetString(Convert.FromBase64String(value));
}
sealed class FixtureUpstream : HttpMessageHandler
{
    public Pipe Events { get; } = new();
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        if (request.RequestUri?.Host != "api.openai.com" || request.RequestUri.Scheme != "https" || request.Headers.Authorization?.Parameter != "fixture-upstream")
            throw new InvalidOperationException("wrong upstream route or account");
        if (request.RequestUri.AbsolutePath == "/v1/models") {
            var limited = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
            limited.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromSeconds(9));
            return limited;
        }
        if (request.RequestUri.AbsolutePath != "/v1/responses") throw new InvalidOperationException("unexpected route");
        await Events.Writer.WriteAsync("data: first\n\n"u8.ToArray(), token);
        var content = new StreamContent(Events.Reader.AsStream());
        content.Headers.ContentType = new MediaTypeHeaderValue("text/event-stream");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
    }
}
