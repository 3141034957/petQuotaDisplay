using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace PetQuota;

public record RequestRecord(DateTimeOffset Time, string Member, string Path, string? Model, int Status, long Milliseconds, bool Interrupted);

public sealed class Gateway : IAsyncDisposable
{
    const int BodyLimit = 16 * 1024 * 1024;
    readonly Workspace store;
    readonly HttpClient upstream;
    readonly object sync = new();
    readonly string logPath;
    RequestRecord[] records;
    WebApplication? app;
    public bool Running => app != null;
    public string? Address => app?.Urls.Single();
    public RequestRecord[] Records { get { lock (sync) return [..records]; } }
    public string? LogError { get; private set; }
    public Gateway(Workspace store, HttpMessageHandler? handler = null)
    {
        this.store = store;
        upstream = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = Timeout.InfiniteTimeSpan };
        logPath = Path.Combine(store.Root, "gateway-history.json");
        try { records = (Workspace.Read<RequestRecord[]>(logPath) ?? []).Take(200).ToArray(); }
        catch (JsonException) { records = []; LogError = "旧请求记录无法读取。"; }
    }
    public async Task StartAsync(int port)
    {
        if (app != null) return;
        if (store.State.Members.Length == 0) throw new InvalidOperationException("请先添加网关成员。");
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { Args = [] });
        builder.Configuration.Sources.Clear();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(options => {
            options.AddServerHeader = false;
            options.Limits.MaxRequestBodySize = BodyLimit;
            options.Limits.MaxConcurrentConnections = 32;
            options.Listen(IPAddress.Loopback, port);
        });
        var server = builder.Build();
        server.Run(Forward);
        try { await server.StartAsync(); app = server; }
        catch { await server.DisposeAsync(); throw; }
    }
    async Task Forward(HttpContext context)
    {
        var local = context.Request;
        var reply = context.Response;
        var path = local.Path.Value ?? "";
        if (local.Method == "GET" && path == "/health") { await reply.WriteAsJsonAsync(new { status = "ok" }); return; }
        var auth = local.Headers.Authorization.ToString();
        if (!auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) { reply.StatusCode = 401; return; }
        var candidate = Encoding.UTF8.GetBytes(auth[7..]);
        var state = store.State;
        var member = state.Members.FirstOrDefault(m => CryptographicOperations.FixedTimeEquals(candidate,
            Encoding.UTF8.GetBytes(store.Secrets.Reveal(m.LocalSecret))));
        var account = state.Accounts.FirstOrDefault(a => a.Id == member?.AccountId && a.Platform == Platform.Codex && a.Kind == Credential.Key);
        if (member == null || account?.Secret == null) { reply.StatusCode = 401; return; }
        var post = local.Method == "POST";
        if (local.QueryString.HasValue || !(local.Method == "GET" && path == "/v1/models" ||
            post && path is "/v1/responses" or "/v1/responses/compact" or "/v1/chat/completions"))
        { reply.StatusCode = 404; return; }
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
        deadline.CancelAfter(TimeSpan.FromMinutes(10));
        var token = deadline.Token;
        var started = DateTimeOffset.Now;
        var timer = Stopwatch.StartNew();
        string? model = null;
        bool interrupted = false;
        try
        {
            using var request = new HttpRequestMessage(post ? HttpMethod.Post : HttpMethod.Get, "https://api.openai.com" + path);
            request.Headers.Authorization = new("Bearer", store.Secrets.Reveal(account.Secret));
            if (post)
            {
                using var buffer = new MemoryStream();
                await local.Body.CopyToAsync(buffer, token);
                var body = buffer.ToArray();
                using (var parsed = JsonDocument.Parse(body))
                {
                    if (parsed.RootElement.ValueKind != JsonValueKind.Object) { reply.StatusCode = 400; return; }
                    if (parsed.RootElement.TryGetProperty("model", out var value) && value.ValueKind == JsonValueKind.String &&
                        value.GetString() is { Length: > 0 and <= 128 } name &&
                        name.All(c => char.IsAsciiLetterOrDigit(c) || "-._:/".Contains(c))) model = name;
                }
                request.Content = new ByteArrayContent(body);
                request.Content.Headers.ContentType = new("application/json");
            }
            using var response = await upstream.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            reply.StatusCode = (int)response.StatusCode;
            reply.ContentType = response.Content.Headers.ContentType?.MediaType == "text/event-stream" ? "text/event-stream" : "application/json";
            if (response.Headers.RetryAfter != null) reply.Headers.RetryAfter = response.Headers.RetryAfter.ToString();
            await using var stream = await response.Content.ReadAsStreamAsync(token);
            var block = new byte[16 * 1024];
            int count;
            while ((count = await stream.ReadAsync(block, token)) > 0)
            {
                await reply.Body.WriteAsync(block.AsMemory(0, count), token);
                await reply.Body.FlushAsync(token);
            }
        }
        catch (BadHttpRequestException e) { if (!reply.HasStarted) reply.StatusCode = e.StatusCode; }
        catch (JsonException) { reply.StatusCode = 400; }
        catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException)
        {
            interrupted = true;
            if (reply.HasStarted) context.Abort();
            else reply.StatusCode = context.RequestAborted.IsCancellationRequested ? 499 : e is OperationCanceledException ? 504 : 502;
        }
        finally
        {
            lock (sync)
            {
                records = [new(started, member.Name, path, model, reply.StatusCode, timer.ElapsedMilliseconds, interrupted), ..records.Take(199)];
                try { Workspace.Write(logPath, JsonSerializer.SerializeToUtf8Bytes(records)); LogError = null; }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { LogError = "本次请求记录未能写入磁盘。"; }
            }
        }
    }
    public async Task StopAsync()
    {
        if (app is not { } server) return;
        try { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3)); await server.StopAsync(timeout.Token); }
        finally { await server.DisposeAsync(); app = null; }
    }
    public async ValueTask DisposeAsync() { await StopAsync(); upstream.Dispose(); }
}
