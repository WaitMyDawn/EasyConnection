using System.Drawing;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text.Json;

namespace EasyConnection.Host;

internal static class HostSelfTest
{
    public static int Run()
    {
        var result = 1;
        using var icon = Branding.LoadIcon();
        Check(Branding.LicenseText("EasyConnection.License").StartsWith("MIT License", StringComparison.Ordinal), "Project license must be embedded");
        Check(Branding.LicenseText("EasyConnection.ThirdPartyNotices").Contains("Microsoft", StringComparison.Ordinal), "Runtime license notices must be embedded");
        using var fixture = new Form { Text = "EasyConnection isolated test surface", Icon = icon, ClientSize = new Size(600, 280), StartPosition = FormStartPosition.CenterScreen, TopMost = true };
        var input = new TextBox { Name = "FixtureInput", AccessibleName = "Fixture input", Location = new Point(30, 40), Width = 450, Height = 75, Multiline = true, AcceptsReturn = true };
        var button = new Button { Name = "FixtureButton", AccessibleName = "Commit test", Text = "Commit test", Location = new Point(30, 140), Width = 150 };
        using var menu = new ContextMenuStrip();
        menu.Items.Add("Fixture menu item");
        input.ContextMenuStrip = menu;
        var count = 0;
        button.Click += (_, _) => count++;
        fixture.Controls.AddRange([input, button]);
        fixture.Shown += async (_, _) =>
        {
            try
            {
                await TestAsync(fixture, input, () => count);
                Console.WriteLine("PASS: host integration (TLS, pairing, UIA, multiline focus input, stale-focus rejection, maximized-window preservation, right-click menu, pixel movement, snapshots, WSS, cache cleanup, revocation)");
                result = 0;
            }
            catch (Exception error)
            {
                for (Exception? current = error; current is not null; current = current.InnerException)
                    Console.WriteLine("FAIL: " + current.Message);
            }
            finally { fixture.Close(); }
        };
        Application.Run(fixture);
        return result;
    }

    private static async Task TestAsync(Form fixture, TextBox input, Func<int> invocationCount)
    {
        NativeMethods.ShowWindow(fixture.Handle, 9);
        await Task.Delay(100);
        var directory = Path.Combine(Environment.CurrentDirectory, ".test-state", Guid.NewGuid().ToString("N"));
        using var security = new SecurityStore(Path.Combine(directory, "credentials"));
        var catalog = new Catalog(directory);
        var bounds = fixture.Bounds;
        var handle = fixture.Handle;
        using var snapshots = new SnapshotService(() => bounds);
        var runtime = new DesktopRuntime(catalog, snapshots, () => handle);
        using var tasks = new TaskEngine(runtime, Path.Combine(directory, "tasks"));
        await using var server = new ApiServer(security, catalog, runtime, snapshots, tasks, 0, true);
        await server.StartAsync();
        using var handler = new HttpClientHandler { ServerCertificateCustomValidationCallback = (_, cert, _, _) => cert?.GetCertHashString(HashAlgorithmName.SHA256).ToLowerInvariant() == security.Fingerprint };
        using var client = new HttpClient(handler) { BaseAddress = new Uri(server.Address), Timeout = TimeSpan.FromSeconds(15) };
        Check((await client.GetAsync("/api/v1/status")).StatusCode == HttpStatusCode.Unauthorized, "Unauthenticated access must fail");
        var wrong = await client.PostAsJsonAsync("/api/v1/pair", new PairRequest("invalid", "Integration test"), Protocol.Json);
        Check(wrong.StatusCode == HttpStatusCode.Forbidden, "Incorrect pairing code must fail");
        var pairCode = security.GetPairingCode();
        var paired = await client.PostAsJsonAsync("/api/v1/pair", new PairRequest(pairCode, "Integration test"), Protocol.Json);
        paired.EnsureSuccessStatusCode();
        var device = (await paired.Content.ReadFromJsonAsync<PairResponse>(Protocol.Json))!;
        Check(!(await client.PostAsJsonAsync("/api/v1/pair", new PairRequest(pairCode, "Replay"), Protocol.Json)).IsSuccessStatusCode, "Pairing code must be single use");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", device.Token);
        var windows = (await client.GetFromJsonAsync<WindowInfo[]>("/api/v1/windows", Protocol.Json))!;
        Check(windows.Length == 1 && windows[0].Title == fixture.Text, $"Test enumeration must be isolated (count={windows.Length})");
        var elements = await client.GetFromJsonAsync<JsonElement>($"/api/v1/windows/{windows[0].Id}/elements", Protocol.Json);
        Check(elements.GetProperty("elements").EnumerateArray().Any(e => e.GetProperty("name").GetString() == "Fixture input"), "Element discovery must return actual fixture controls");
        var selector = new ElementSelector(WindowTitle: fixture.Text, Name: "Fixture input", ControlType: "Edit");
        var flow = new FlowDefinition("integration", "Integration fixture", "", [new("text", "Text")],
        [
            new("waitForElement") { Selector = selector },
            new("setValue") { Selector = selector, Text = "${text}" },
            new("assertElement") { Selector = selector, Text = "${text}" },
            new("invoke") { Selector = new(WindowTitle: fixture.Text, Name: "Commit test", ControlType: "Button") },
            new("screenshot") { DisplayId = "fixture" }
        ]);
        (await client.PutAsJsonAsync("/api/v1/flows/integration", flow, Protocol.Json)).EnsureSuccessStatusCode();
        var request = new RunRequest(Guid.NewGuid().ToString("N"), new() { ["text"] = "测试🙂 — unrelated name 42" });
        var task = await RunFlow(client, request);
        Check(task.State == "succeeded", "Flow failed: " + task.Error);
        Check(input.Text == request.Arguments["text"] && invocationCount() == 1, "UIA must update and invoke only the fixture");
        var replay = await RunFlow(client, request);
        Check(replay.Id == task.Id && invocationCount() == 1, "Retries must not duplicate side effects");
        var imageId = task.Steps.Last().Snapshot!.Id;
        var image = await client.GetByteArrayAsync($"/api/v1/snapshots/{imageId}/image");
        Check(image.Length > 100 && image[0] == 0xff && image[1] == 0xd8, "Screenshot must be JPEG");
        var conflict = await client.PostAsJsonAsync("/api/v1/flows/integration/run", request with { Arguments = new() { ["text"] = "different" } }, Protocol.Json);
        Check(conflict.StatusCode == HttpStatusCode.Conflict, "Changed content with same request ID must fail");
        var invalidClick = await client.PostAsJsonAsync("/api/v1/actions", new ActionRequest(Guid.NewGuid().ToString("N"), new("click") { X = 2, Y = 0 }), Protocol.Json);
        Check(invalidClick.StatusCode == HttpStatusCode.BadRequest, "Out-of-range coordinates must fail");
        input.Focus();
        input.SelectionStart = input.Text.Length;
        var action = await client.PostAsJsonAsync("/api/v1/actions", new ActionRequest(Guid.NewGuid().ToString("N"), new("typeText") { WindowId = windows[0].Id, Text = "追加" }), Protocol.Json);
        action.EnsureSuccessStatusCode();
        var actionTask = (await action.Content.ReadFromJsonAsync<TaskRecord>(Protocol.Json))!;
        var typed = await WaitTask(client, actionTask.Id);
        Check(typed.State == "succeeded" && input.Text.Contains("追加", StringComparison.Ordinal), $"Unicode input must reach the selected fixture (state={typed.State}, error={typed.Error})");
        var focus = (await client.GetFromJsonAsync<FocusInfo>("/api/v1/focus", Protocol.Json))!;
        Check(focus.Editable == true, "Focused text box must be discovered without choosing a window");
        input.Clear();
        var focusedInput = await client.PostAsJsonAsync("/api/v1/interactions", new ActionRequest(Guid.NewGuid().ToString("N"), new("typeFocusedText") { FocusId = focus.Id, Text = "One\nTwo\r\nThree\r末行🙂" }), Protocol.Json);
        focusedInput.EnsureSuccessStatusCode();
        Check(input.Text.Replace("\r\n", "\n", StringComparison.Ordinal) == "One\nTwo\nThree\n末行🙂", "Focused input must preserve LF, CRLF and CR as line breaks");
        fixture.Controls.OfType<Button>().Single().Focus();
        var changedFocus = await client.PostAsJsonAsync("/api/v1/interactions", new ActionRequest(Guid.NewGuid().ToString("N"), new("typeFocusedText") { FocusId = focus.Id, Text = "must not type" }), Protocol.Json);
        Check(changedFocus.StatusCode == HttpStatusCode.BadRequest, "Changed input focus must reject stale text requests");
        NativeMethods.ShowWindow(fixture.Handle, 3);
        input.Focus();
        await Task.Delay(80);
        var maximizedInput = await client.PostAsJsonAsync("/api/v1/actions", new ActionRequest(Guid.NewGuid().ToString("N"), new("typeText") { WindowId = windows[0].Id, Text = " keep size" }), Protocol.Json);
        maximizedInput.EnsureSuccessStatusCode();
        Check((await WaitTask(client, (await maximizedInput.Content.ReadFromJsonAsync<TaskRecord>(Protocol.Json))!.Id)).State == "succeeded" && NativeMethods.IsZoomed(fixture.Handle), "Typing must preserve maximized windows");
        NativeMethods.ShowWindow(fixture.Handle, 9);
        input.Focus();
        await Task.Delay(80);
        var originalTaskCount = (await client.GetFromJsonAsync<TaskRecord[]>("/api/v1/tasks", Protocol.Json))!.Length;
        var pixel = input.PointToScreen(new Point(8, 8));
        NativeMethods.SetCursorPos(pixel.X, pixel.Y);
        var nudge = new ActionRequest(Guid.NewGuid().ToString("N"), new("movePointer") { SnapshotId = imageId, DeltaX = 1 });
        var nudged = await client.PostAsJsonAsync("/api/v1/pointer", nudge, Protocol.Json);
        nudged.EnsureSuccessStatusCode();
        var position = NativeMethods.ReadCursor()!.Value.Position;
        Check(position.X == pixel.X + 1 && position.Y == pixel.Y, "Micro adjustment must move exactly one physical pixel");
        (await client.PostAsJsonAsync("/api/v1/pointer", nudge, Protocol.Json)).EnsureSuccessStatusCode();
        Check(NativeMethods.ReadCursor()!.Value.Position.X == pixel.X + 1, "Pointer retries must not move twice");
        var target = fixture.Controls.OfType<Button>().Single().PointToScreen(new Point(8, 8));
        NativeMethods.SetCursorPos(target.X, target.Y);
        (await client.PostAsJsonAsync("/api/v1/pointer", new ActionRequest(Guid.NewGuid().ToString("N"), new("clickPointer") { SnapshotId = imageId, Button = "left" }), Protocol.Json)).EnsureSuccessStatusCode();
        await Task.Delay(50);
        Check(invocationCount() == 2, "Left mouse button must act at the actual cursor position");
        var contextMenu = input.ContextMenuStrip!;
        NativeMethods.SetCursorPos(pixel.X, pixel.Y);
        (await client.PostAsJsonAsync("/api/v1/interactions", new ActionRequest(Guid.NewGuid().ToString("N"), new("clickPointer") { SnapshotId = imageId, Button = "right" }), Protocol.Json)).EnsureSuccessStatusCode();
        Check(contextMenu.Visible, "Right click must open the fixture context menu before the response");
        contextMenu.Close();
        Check((await client.GetFromJsonAsync<TaskRecord[]>("/api/v1/tasks", Protocol.Json))!.Length == originalTaskCount, "Micro control must not grow disk history");
        using (var socket = new ClientWebSocket())
        {
            socket.Options.RemoteCertificateValidationCallback = (_, cert, _, _) => cert?.GetCertHashString(HashAlgorithmName.SHA256).ToLowerInvariant() == security.Fingerprint;
            socket.Options.SetRequestHeader("Authorization", "Bearer " + device.Token);
            var address = new UriBuilder(server.Address) { Scheme = "wss", Path = "/api/v1/live", Query = "displayId=fixture" }.Uri;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await socket.ConnectAsync(address, timeout.Token);
            var buffer = new byte[1024 * 1024];
            var metadata = await socket.ReceiveAsync(buffer, timeout.Token);
            Check(metadata.MessageType == WebSocketMessageType.Text, "Live stream metadata missing");
            var frame = await socket.ReceiveAsync(buffer, timeout.Token);
            Check(frame.MessageType == WebSocketMessageType.Binary && frame.Count > 100, "Live stream JPEG missing");
            socket.Abort();
        }
        (await client.PostAsync("/api/v1/cache/clear", null)).EnsureSuccessStatusCode();
        Check((await client.GetAsync($"/api/v1/snapshots/{imageId}/image")).StatusCode == HttpStatusCode.BadRequest, "Cleaning must invalidate old images");
        Check((await client.GetFromJsonAsync<TaskRecord[]>("/api/v1/tasks", Protocol.Json))!.Length == originalTaskCount, "Cache cleanup must preserve task history");
        Check((await client.GetAsync("/api/v1/status")).IsSuccessStatusCode, "Cache cleanup must preserve pairing");
        security.Revoke(device.DeviceId);
        Check((await client.GetAsync("/api/v1/status")).StatusCode == HttpStatusCode.Unauthorized, "Revoked device must lose access");
        await DartInteropAsync(server.Address, security);
        await tasks.StopAsync();
    }
    private static async Task DartInteropAsync(string address, SecurityStore security)
    {
        var root = Environment.CurrentDirectory;
        var dart = Path.Combine(root, ".tools", "flutter", "bin", "cache", "dart-sdk", "bin", "dart.exe");
        var source = Path.Combine(root, "apps", "mobile", "tool", "transport_smoke.dart");
        if (!File.Exists(dart) || !File.Exists(source)) { Console.WriteLine("SKIP: Dart SDK or interop test unavailable"); return; }
        security.RefreshPairingCode();
        var invitation = new PairingInvitation(2, "Isolated transport fixture", ["https://127.0.0.1:1", address], "", security.Fingerprint, security.GetPairingCode(), security.PairingExpiresAt);
        var start = new System.Diagnostics.ProcessStartInfo(dart) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("--packages=" + Path.Combine(root, "apps", "mobile", ".dart_tool", "package_config.json"));
        start.ArgumentList.Add(source);
        using var process = System.Diagnostics.Process.Start(start)!;
        Console.WriteLine($"Dart interop test PID: {process.Id}");
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        try
        {
            await process.StandardInput.WriteLineAsync(invitation.Encode());
            process.StandardInput.Close();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
            var result = await output;
            _ = await errors;
            Check(process.ExitCode == 0 && result.StartsWith("PASS:", StringComparison.Ordinal), "Dart transport smoke test failed");
            Console.Write(result);
        }
        finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); } }
    }
    private static async Task<TaskRecord> RunFlow(HttpClient client, RunRequest request)
    {
        var response = await client.PostAsJsonAsync("/api/v1/flows/integration/run", request, Protocol.Json);
        response.EnsureSuccessStatusCode();
        return await WaitTask(client, (await response.Content.ReadFromJsonAsync<TaskRecord>(Protocol.Json))!.Id);
    }
    private static async Task<TaskRecord> WaitTask(HttpClient client, string id)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            var record = (await client.GetFromJsonAsync<TaskRecord>("/api/v1/tasks/" + id, Protocol.Json))!;
            if (record.State is not ("running" or "queued")) return record;
            await Task.Delay(100);
        }
        throw new InvalidOperationException("Task timed out");
    }
    private static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
}
