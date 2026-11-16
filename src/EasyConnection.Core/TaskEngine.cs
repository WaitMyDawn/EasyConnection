using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace EasyConnection.Core;

public sealed class TaskEngine : IDisposable
{
    private readonly IDesktopRuntime runtime;
    private readonly string directory;
    private readonly SemaphoreSlim desktopGate = new(1, 1);
    private readonly object sync = new();
    private readonly Dictionary<string, TaskRecord> records = [];
    private readonly Dictionary<string, CancellationTokenSource> cancellations = [];
    private readonly Dictionary<string, Task> running = [];
    private readonly CancellationTokenSource shutdown = new();
    private readonly Dictionary<(string Device, string Request), (string Hash, DateTimeOffset At, Task<ActionResult> Execution)> pointerRequests = [];

    public Task<ActionResult> PointerAsync(string deviceId, ActionRequest request)
    {
        if (request.Action.Type is not ("movePointer" or "clickPointer")) throw new CommandException("invalid_pointer_action", "此接口仅接受鼠标微调与当前位置点击。");
        return InteractAsync(deviceId, request);
    }

    public Task<ActionResult> InteractAsync(string deviceId, ActionRequest request)
    {
        Protocol.Validate(request.Action);
        if (!Protocol.InteractiveTypes.Contains(request.Action.Type)) throw new CommandException("invalid_interaction", "此接口仅接受桌面交互动作。");
        if (request.RequestId.Length is < 8 or > 100) throw new CommandException("invalid_request_id", "请求 ID 长度无效。");
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(request.Action, Protocol.Json))));
        lock (sync)
        {
            foreach (var key in pointerRequests.Where(p => p.Value.Execution.IsCompleted && DateTimeOffset.UtcNow - p.Value.At > TimeSpan.FromSeconds(30)).Select(p => p.Key).ToArray()) pointerRequests.Remove(key);
            var identity = (deviceId, request.RequestId);
            if (pointerRequests.TryGetValue(identity, out var previous))
            {
                if (previous.Hash != hash) throw new CommandException("request_conflict", "此请求 ID 已用于其他内容。");
                return previous.Execution;
            }
            if (pointerRequests.Count >= 512 || !desktopGate.Wait(0)) throw new CommandException("desktop_busy", "电脑正在执行其他操作，请稍后再微调。");
            // Interactive input shares the workflow lock without writing a journal entry for every gesture.
            var execution = Task.Run(async () =>
            {
                try { return await runtime.ExecuteAsync(request.Action, shutdown.Token); }
                finally { desktopGate.Release(); }
            });
            pointerRequests.Add(identity, (hash, DateTimeOffset.UtcNow, execution));
            return execution;
        }
    }

    public T ClearImageCache<T>(Func<T> clear)
    {
        lock (sync)
        {
            if (running.Count > 0 || !desktopGate.Wait(0)) throw new CommandException("desktop_busy", "任务尚未结束，请稍后清理电脑截图缓存。");
            try { return clear(); }
            finally { desktopGate.Release(); }
        }
    }

    public TaskEngine(IDesktopRuntime runtime, string directory)
    {
        this.runtime = runtime;
        this.directory = directory;
        Directory.CreateDirectory(directory);
        foreach (var file in Directory.EnumerateFiles(directory, "*.json"))
        {
            var record = JsonSerializer.Deserialize<TaskRecord>(File.ReadAllText(file), Protocol.Json);
            if (record is null) continue;
            if (record.State is "queued" or "running")
            {
                record = record with { State = "unknown", Error = "执行端上次退出时任务未完成。请核对实际状态后再执行。", UpdatedAt = DateTimeOffset.UtcNow,
                    Steps = record.Steps.Select(s => s.State == "running" ? s with { State = "unknown", Message = "执行端中断，请核对实际结果。" } : s).ToList() };
                Save(record);
            }
            records[record.Id] = record;
        }
    }

    public IReadOnlyList<TaskRecord> List(string deviceId)
    {
        lock (sync) return records.Values.Where(r => r.DeviceId == deviceId).OrderByDescending(r => r.CreatedAt).Take(100).ToArray();
    }

    public TaskRecord? Get(string id, string deviceId)
    {
        lock (sync) return records.TryGetValue(id, out var record) && record.DeviceId == deviceId ? record : null;
    }

    public TaskRecord Submit(string deviceId, string requestId, FlowDefinition flow, IReadOnlyDictionary<string, string> arguments)
    {
        if (requestId.Length is < 8 or > 100) throw new CommandException("invalid_request_id", "请求 ID 长度无效。");
        var bound = Protocol.Bind(flow, arguments);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(bound, Protocol.Json))));
        lock (sync)
        {
            var existing = records.Values.FirstOrDefault(r => r.DeviceId == deviceId && r.RequestId == requestId);
            if (existing is not null)
            {
                if (existing.RequestHash != hash) throw new CommandException("request_conflict", "此请求 ID 已用于其他内容。");
                return existing;
            }
            if (running.Count >= 20) throw new CommandException("queue_full", "任务队列已满。");
            var now = DateTimeOffset.UtcNow;
            var record = new TaskRecord(Guid.NewGuid().ToString("N"), deviceId, requestId, hash, flow.Id, flow.Name, "queued", now, now, []);
            Save(record);
            records.Add(record.Id, record);
            var cancellation = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            cancellations.Add(record.Id, cancellation);
            running.Add(record.Id, Task.Run(() => RunAsync(record.Id, bound, cancellation.Token)));
            return record;
        }
    }

    public bool Cancel(string id, string deviceId)
    {
        lock (sync)
        {
            if (Get(id, deviceId) is null || !cancellations.TryGetValue(id, out var cancellation)) return false;
            cancellation.Cancel();
            return true;
        }
    }

    private async Task RunAsync(string id, FlowDefinition flow, CancellationToken cancellationToken)
    {
        var acquired = false;
        try
        {
            await desktopGate.WaitAsync(cancellationToken);
            acquired = true;
            Update(id, r => r with { State = "running" });
            for (var index = 0; index < flow.Steps.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var step = flow.Steps[index];
                Update(id, r => r with { Steps = [.. r.Steps, new StepResult(index, step.Type, "running", null)] });
                var result = await runtime.ExecuteAsync(step, cancellationToken);
                Update(id, r => r with { Steps = r.Steps.Select(s => s.Index == index ? s with { State = "succeeded", Message = result.Message, Snapshot = result.Snapshot } : s).ToList() });
            }
            Update(id, r => r with { State = "succeeded" });
        }
        catch (OperationCanceledException)
        {
            Update(id, r => r with { State = "cancelled", Error = "后续步骤已取消；已经完成的操作不会自动撤销。",
                Steps = r.Steps.Select(s => s.State == "running" ? s with { State = "cancelled", Message = "步骤已中断，已发生的操作不会撤销。" } : s).ToList() });
        }
        catch (Exception error)
        {
            Update(id, r => r with
            {
                State = "failed", Error = error is CommandException ? error.Message : "系统操作失败，请检查目标应用状态。",
                Steps = r.Steps.Select(s => s.State == "running" ? s with { State = "failed", Message = error is CommandException ? error.Message : "系统操作失败。" } : s).ToList()
            });
        }
        finally
        {
            if (acquired) desktopGate.Release();
            lock (sync)
            {
                if (cancellations.Remove(id, out var cancellation)) cancellation.Dispose();
                running.Remove(id);
            }
        }
    }

    public async Task StopAsync()
    {
        shutdown.Cancel();
        Task[] tasks;
        lock (sync) tasks = running.Values.Concat(pointerRequests.Values.Select(p => p.Execution)).ToArray();
        try { await Task.WhenAll(tasks); }
        catch (Exception) when (shutdown.IsCancellationRequested) { }
    }

    private void Update(string id, Func<TaskRecord, TaskRecord> change)
    {
        lock (sync)
        {
            var record = change(records[id]) with { UpdatedAt = DateTimeOffset.UtcNow };
            Save(record);
            records[id] = record;
        }
    }

    private void Save(TaskRecord record)
    {
        var path = Path.Combine(directory, record.Id + ".json");
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(record, Protocol.Json));
        File.Move(path + ".tmp", path, true);
    }

    public void Dispose()
    {
        shutdown.Dispose();
        desktopGate.Dispose();
    }
}
