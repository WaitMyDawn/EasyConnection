using EasyConnection.Core;

var passed = 0;
void Check(bool condition, string message) { if (!condition) throw new Exception(message); passed++; }
void Reject(Action action, string code)
{
    try { action(); throw new Exception("Expected rejection: " + code); }
    catch (CommandException error) { Check(error.Code == code, "Wrong rejection: " + error.Code); }
}
Reject(() => Protocol.Validate(new ActionStep("click") { X = double.NaN, Y = 0 }), "invalid_coordinates");
Reject(() => Protocol.Validate(new ActionStep("click") { X = 0.3, Y = -0.01 }), "invalid_coordinates");
Reject(() => Protocol.Validate(new ActionStep("typeText") { Text = "test" }), "missing_window");
Reject(() => Protocol.Validate(new ActionStep("invoke") { Selector = new(Name: "Send") }), "unscoped_selector");
Reject(() => Protocol.Validate(new ActionStep("keyChord") { WindowId = "window", Keys = ["CTRL", "BOGUS"] }), "invalid_keys");
Reject(() => Protocol.Validate(new ActionStep("scroll") { X = 0.5, Y = 0.5, WheelDelta = 0 }), "invalid_scroll");
Reject(() => Protocol.Validate(new ActionStep("drag") { X = 0.5, Y = 0.5, FromX = 2, FromY = 0 }), "invalid_coordinates");
var flow = new FlowDefinition("unrelated", "Irregular application", "", [new("message", "Message")], [new("typeText") { WindowId = "fixture", Text = "before ${message} after" }]);
var bound = Protocol.Bind(flow, new Dictionary<string, string> { ["message"] = "🙂 ${message} $(not-shell)" });
Check(bound.Steps[0].Text == "before 🙂 ${message} $(not-shell) after", "Parameter replacement must be literal and single pass");
Reject(() => Protocol.Bind(flow, new Dictionary<string, string>()), "missing_parameter");
Reject(() => Protocol.Bind(flow, new Dictionary<string, string> { ["message"] = "text", ["extra"] = "x" }), "unknown_parameter");
var runtime = new FakeRuntime();
Reject(() => Protocol.Validate(new ActionStep("movePointer") { SnapshotId = "frame", DeltaX = 101 }), "invalid_delta");
Reject(() => Protocol.Validate(new ActionStep("clickPointer") { SnapshotId = "frame", DeltaY = 1 }), "invalid_delta");
Reject(() => Protocol.Validate(new ActionStep("movePointer") { DeltaX = 1 }), "missing_snapshot");
Reject(() => Protocol.Validate(new ActionStep("typeFocusedText") { Text = "unrelated" }), "missing_focus");
Reject(() => Protocol.Validate(new ActionStep("focusedKeyChord") { FocusId = "focus", Keys = ["BOGUS"] }), "invalid_keys");
Check(PointerGeometry.Move(-100, -50, -1, 1, -100, -100, 200, 100) == (-100, -49), "Pointer movement must clamp negative monitor origins without scaling the step");
Check(PointerGeometry.Move(99, -1, 20, 20, -100, -100, 200, 100) == (99, -1), "Pointer must stay inside its display");
Reject(() => PointerGeometry.Move(200, 200, 1, 0, -100, -100, 200, 100), "cursor_outside");
var clock = new TestClock();
var images = new BoundedCache<byte[]>(10, 3, TimeSpan.FromSeconds(10), v => v.LongLength, clock);
images.Put("first", new byte[8]); clock.Advance(TimeSpan.FromSeconds(1)); images.Put("second", new byte[4]);
Check(!images.TryGet("first", out _) && images.Usage.Bytes == 4, "Byte budgets must evict old images regardless of entry count");
clock.Advance(TimeSpan.FromSeconds(11)); images.Prune();
Check(images.Usage.Entries == 0 && images.Usage.Bytes == 0, "Idle cached images must expire without new frames");
images.Put("last", new byte[3]);
Check(images.Clear().Bytes == 3 && !images.TryGet("last", out _), "Explicit cleanup must invalidate old image references");
var pointerDirectory = Path.Combine(Environment.CurrentDirectory, ".test-state", Guid.NewGuid().ToString("N"));
using (var pointerEngine = new TaskEngine(new FakeRuntime(), pointerDirectory))
{
    var pointerRequest = new ActionRequest(Guid.NewGuid().ToString("N"), new("movePointer") { SnapshotId = "frame", DeltaX = 1 });
    var first = pointerEngine.PointerAsync("controller", pointerRequest);
    await first;
    Check(ReferenceEquals(first, pointerEngine.PointerAsync("controller", pointerRequest)), "Short-term pointer retries must return the same result");
    pointerEngine.ClearImageCache(() => images.Clear());
    Check(ReferenceEquals(first, pointerEngine.PointerAsync("controller", pointerRequest)), "Cleaning images must preserve pointer deduplication");
    Check(pointerEngine.List("controller").Count == 0 && Directory.GetFiles(pointerDirectory, "*.json").Length == 0, "Pixel adjustments must not produce disk task records");
    var interactive = new ActionRequest(Guid.NewGuid().ToString("N"), new("typeFocusedText") { FocusId = "test-focus", Text = "A\nB" });
    var interactiveResult = pointerEngine.InteractAsync("controller", interactive);
    await interactiveResult;
    Check(ReferenceEquals(interactiveResult, pointerEngine.InteractAsync("controller", interactive)), "Interactive text retries must not duplicate typing");
    Reject(() => pointerEngine.InteractAsync("controller", interactive with { Action = interactive.Action with { Text = "different" } }), "request_conflict");
    Reject(() => pointerEngine.InteractAsync("controller", new(Guid.NewGuid().ToString("N"), new("wait"))), "invalid_interaction");
    var waiting = pointerEngine.Submit("controller", Guid.NewGuid().ToString("N"), new("waiting", "Waiting", "", [], [new("wait") { DelayMs = 30000 }]), new Dictionary<string, string>());
    Reject(() => pointerEngine.ClearImageCache(() => images.Clear()), "desktop_busy");
    pointerEngine.Cancel(waiting.Id, "controller");
    await pointerEngine.StopAsync();
}
var ranked = PairingInvitation.RankAddresses([
    new("https://192.0.2.22:23456", "Quartz", false, true, false),
    new("https://[2001:db8::7]:23456", "Zephyr", true, true, true),
    new("https://198.51.100.9:23456", "Aether", true, true, false),
    new("https://192.0.2.22:23456", "Other", false, true, false)]);
Check(ranked[0] == "https://198.51.100.9:23456" && ranked.Length == 3, "Gateway evidence must outrank enumeration order and duplicate addresses");
Check(ranked.Contains("https://[2001:db8::7]:23456"), "IPv6 candidates must be preserved");
Reject(() => PairingInvitation.NormalizeEndpoint("https://test-user:test-value@example.test"), "invalid_endpoint");
var encoded = new PairingInvitation(2, "Irregular device Ω", ranked, "https://relay.example.test:4443", new string('a', 64), "12345678", DateTimeOffset.UtcNow.AddMinutes(5)).Encode();
var payload = encoded[PairingInvitation.Prefix.Length..].Replace('-', '+').Replace('_', '/');
payload = payload.PadRight((payload.Length + 3) / 4 * 4, '=');
var invitation = System.Text.Json.JsonSerializer.Deserialize<PairingInvitation>(System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(payload)), Protocol.Json)!;
Check(invitation.Endpoints.SequenceEqual(ranked) && invitation.CandidateCount == ranked.Length && invitation.HostName == "Irregular device Ω", "Invitation must preserve identity, addresses and coverage");
var persistentRequestId = Guid.NewGuid().ToString("N");
var directory = Path.Combine(Environment.CurrentDirectory, ".test-state", Guid.NewGuid().ToString("N"));
using (var engine = new TaskEngine(runtime, directory))
{
    var requestId = persistentRequestId;
    var record = engine.Submit("a", requestId, flow, new Dictionary<string, string> { ["message"] = "hello" });
    for (var i = 0; i < 100 && engine.Get(record.Id, "a")!.State is "queued" or "running"; i++) await Task.Delay(10);
    Check(engine.Get(record.Id, "a")!.State == "succeeded", "Task must complete");
    Check(engine.Get(record.Id, "b") is null, "Task ownership must be enforced");
    Check(engine.Submit("a", requestId, flow, new Dictionary<string, string> { ["message"] = "hello" }).Id == record.Id && runtime.Calls == 1, "Request retry must not repeat input");
    Reject(() => engine.Submit("a", requestId, flow, new Dictionary<string, string> { ["message"] = "changed" }), "request_conflict");
    var waiting = new FlowDefinition("wait", "Wait", "", [], [new("wait") { DelayMs = 30000 }]);
    var pending = engine.Submit("a", Guid.NewGuid().ToString("N"), waiting, new Dictionary<string, string>());
    Check(engine.Cancel(pending.Id, "b") == false, "Another device cannot cancel tasks");
    Check(engine.Cancel(pending.Id, "a"), "Owner can cancel task");
    await engine.StopAsync();
    Check(engine.Get(pending.Id, "a")!.State == "cancelled", "Cancellation must persist");
}
using (var restored = new TaskEngine(runtime, directory))
{
    Check(restored.List("a").Count == 2, "Task records must survive restart");
    var before = runtime.Calls;
    _ = restored.Submit("a", persistentRequestId, flow, new Dictionary<string, string> { ["message"] = "hello" });
    Check(runtime.Calls == before, "Persisted request IDs must prevent replay after restart");
    await restored.StopAsync();
}
var interrupted = new TaskRecord(Guid.NewGuid().ToString("N"), "a", "interrupted", "hash", "test", "Test", "running", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, []);
File.WriteAllText(Path.Combine(directory, interrupted.Id + ".json"), System.Text.Json.JsonSerializer.Serialize(interrupted, Protocol.Json));
using (var recovered = new TaskEngine(runtime, directory))
{
    Check(recovered.Get(interrupted.Id, "a")!.State == "unknown", "Interrupted tasks must never resume external actions automatically");
    await recovered.StopAsync();
}
Console.WriteLine($"PASS: {passed} core assertions");

sealed class FakeRuntime : IDesktopRuntime
{
    public int Calls;
    public async Task<ActionResult> ExecuteAsync(ActionStep step, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref Calls);
        if (step.Type == "wait") await Task.Delay(step.DelayMs, cancellationToken);
        return new("completed");
    }
}

sealed class TestClock : TimeProvider
{
    private DateTimeOffset now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset GetUtcNow() => now;
    public void Advance(TimeSpan duration) => now += duration;
}
