using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;

namespace EasyConnection.Host;

public sealed class ApiServer : IAsyncDisposable
{
    private readonly WebApplication app;
    public ApiServer(SecurityStore security, Catalog catalog, DesktopRuntime desktop, SnapshotService snapshots, TaskEngine tasks, int port, bool loopbackOnly)
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(server =>
        {
            server.Limits.MaxRequestBodySize = 256 * 1024;
            if (loopbackOnly) server.Listen(IPAddress.Loopback, port, listen => listen.UseHttps(security.Certificate));
            else server.ListenAnyIP(port, listen => listen.UseHttps(security.Certificate));
        });
        builder.Services.ConfigureHttpJsonOptions(options =>
        {
            options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
            options.SerializerOptions.RespectNullableAnnotations = true;
            options.SerializerOptions.RespectRequiredConstructorParameters = true;
        });
        app = builder.Build();
        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(20) });
        app.Use(async (context, next) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            try
            {
                if (context.Request.Path != "/health" && context.Request.Path != "/api/v1/pair")
                {
                    var authorization = context.Request.Headers.Authorization.ToString();
                    var device = authorization.StartsWith("Bearer ", StringComparison.Ordinal) ? security.Authenticate(authorization[7..]) : null;
                    if (device is null) { context.Response.StatusCode = 401; return; }
                    context.Items["device"] = device;
                }
                await next(context);
            }
            catch (CommandException error)
            {
                if (context.Response.HasStarted) { context.Abort(); return; }
                context.Response.StatusCode = error.Code is "pairing_denied" ? 403 : error.Code is "request_conflict" or "desktop_busy" ? 409 : 400;
                await context.Response.WriteAsJsonAsync(new { error = error.Code, message = error.Message });
            }
            catch (Exception error) when (error is JsonException or BadHttpRequestException or ArgumentException)
            {
                if (!context.Response.HasStarted) { context.Response.StatusCode = 400; await context.Response.WriteAsJsonAsync(new { error = "invalid_request", message = "请求格式无效。" }); }
            }
            catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
            catch (Exception)
            {
                if (!context.Response.HasStarted) { context.Response.StatusCode = 500; await context.Response.WriteAsJsonAsync(new { error = "system_error", message = "系统操作失败，请检查电脑端状态。" }); }
            }
        });
        app.MapGet("/health", () => new { protocolVersion = Protocol.Version, product = "EasyConnection" });
        app.MapPost("/api/v1/pair", (PairRequest request) => security.Pair(request));
        app.MapGet("/api/v1/status", () => new { hostName = Environment.MachineName, protocolVersion = Protocol.Version, displays = snapshots.Displays(), transport = "https-wss", capabilities = Protocol.ActionTypes.Order().ToArray() });
        app.MapGet("/api/v1/windows", () => desktop.Windows());
        app.MapGet("/api/v1/pointer", (string? displayId) => snapshots.Cursor(displayId));
        app.MapPost("/api/v1/pointer", (ActionRequest request, HttpContext context) => tasks.PointerAsync(Device(context).Id, request));
        app.MapGet("/api/v1/focus", () => Task.Run(desktop.Focus));
        app.MapPost("/api/v1/interactions", (ActionRequest request, HttpContext context) => tasks.InteractAsync(Device(context).Id, request));
        app.MapGet("/api/v1/cache", () => snapshots.Usage);
        app.MapPost("/api/v1/cache/clear", () => tasks.ClearImageCache(snapshots.Clear));
        app.MapGet("/api/v1/windows/{id}/elements", (string id) => desktop.ElementsAsync(id));
        app.MapGet("/api/v1/apps", () => catalog.ListApps().Select(a => new { a.Id, a.Name }));
        app.MapGet("/api/v1/flows", () => catalog.ListFlows());
        app.MapPut("/api/v1/flows/{id}", (string id, FlowDefinition flow) =>
        {
            if (id != flow.Id) throw new CommandException("invalid_id", "路径与流程 ID 不一致。");
            catalog.SaveFlow(flow);
            return Results.Ok(flow);
        });
        app.MapDelete("/api/v1/flows/{id}", (string id) => { catalog.DeleteFlow(id); return Results.NoContent(); });
        app.MapPost("/api/v1/flows/{id}/run", (string id, RunRequest request, HttpContext context) =>
        {
            var flow = catalog.ListFlows().FirstOrDefault(f => f.Id == id) ?? throw new CommandException("flow_missing", "流程不存在。");
            return Results.Json(tasks.Submit(Device(context).Id, request.RequestId, flow, request.Arguments), statusCode: 202);
        });
        app.MapPost("/api/v1/actions", (ActionRequest request, HttpContext context) =>
        {
            Protocol.Validate(request.Action);
            var flow = new FlowDefinition("manual-action", "单步操作", "", [], [request.Action]);
            return Results.Json(tasks.Submit(Device(context).Id, request.RequestId, flow, new Dictionary<string, string>()), statusCode: 202);
        });
        app.MapGet("/api/v1/tasks", (HttpContext context) => tasks.List(Device(context).Id));
        app.MapGet("/api/v1/tasks/{id}", (string id, HttpContext context) => tasks.Get(id, Device(context).Id) is { } task ? Results.Ok(task) : Results.NotFound());
        app.MapPost("/api/v1/tasks/{id}/cancel", (string id, HttpContext context) => tasks.Cancel(id, Device(context).Id) ? Results.Accepted() : Results.NotFound());
        app.MapPost("/api/v1/snapshots", (ActionStep request) => snapshots.Capture(request.DisplayId).Info);
        app.MapGet("/api/v1/snapshots/{id}/image", (string id) => Results.Bytes(snapshots.Get(id).Image, "image/jpeg"));
        app.Map("/api/v1/live", async context =>
        {
            if (!context.WebSockets.IsWebSocketRequest) { context.Response.StatusCode = 400; return; }
            if (context.Request.Headers.Origin.Count > 0) { context.Response.StatusCode = 403; return; }
            using var socket = await context.WebSockets.AcceptWebSocketAsync();
            var displayId = context.Request.Query["displayId"].FirstOrDefault();
            var token = context.Request.Headers.Authorization.ToString()[7..];
            using var stopped = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
            var receive = Task.Run(async () =>
            {
                var buffer = new byte[256];
                try
                {
                    while (!stopped.IsCancellationRequested)
                    {
                        var message = await socket.ReceiveAsync(buffer, stopped.Token);
                        if (message.MessageType == WebSocketMessageType.Close) break;
                        if (!message.EndOfMessage || message.Count > 0) break;
                    }
                }
                catch (Exception error) when (error is WebSocketException or OperationCanceledException) { }
                finally { stopped.Cancel(); }
            });
            try
            {
                while (!stopped.IsCancellationRequested && socket.State == WebSocketState.Open && security.Authenticate(token) is not null)
                {
                    var frame = await Task.Run(() => snapshots.Capture(displayId, 1600, 70, live: true), stopped.Token);
                    await socket.SendAsync(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(frame.Info, Protocol.Json)), WebSocketMessageType.Text, true, stopped.Token);
                    await socket.SendAsync(frame.Image, WebSocketMessageType.Binary, true, stopped.Token);
                    await Task.Delay(65, stopped.Token);
                }
            }
            catch (Exception error) when (error is WebSocketException or OperationCanceledException) { }
            finally
            {
                stopped.Cancel();
                socket.Abort();
                await receive;
            }
        });
    }
    private static TrustedDevice Device(HttpContext context) => (TrustedDevice)context.Items["device"]!;
    public Task StartAsync() => app.StartAsync();
    public string Address => app.Urls.Single();
    public async ValueTask DisposeAsync() { await app.StopAsync(); await app.DisposeAsync(); }
}
