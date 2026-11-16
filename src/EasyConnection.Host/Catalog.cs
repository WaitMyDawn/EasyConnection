using System.Text.Json;

namespace EasyConnection.Host;

public sealed class Catalog
{
    private readonly string directory;
    private readonly object sync = new();
    private List<FlowDefinition> flows;
    private List<AppRegistration> apps;
    public Catalog(string directory)
    {
        this.directory = directory;
        Directory.CreateDirectory(directory);
        flows = Read<List<FlowDefinition>>("flows.json") ?? [
            new("capture-screen", "获取桌面截图", "按需获取指定显示器的截图。", [], [new("screenshot")])
        ];
        apps = Read<List<AppRegistration>>("apps.json") ?? [];
        foreach (var flow in flows) Protocol.Validate(flow);
    }
    private T? Read<T>(string name) => File.Exists(Path.Combine(directory, name)) ? JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(directory, name)), Protocol.Json) : default;
    private void Save<T>(string name, T value)
    {
        var path = Path.Combine(directory, name);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(value, Protocol.Json));
        File.Move(path + ".tmp", path, true);
    }
    public FlowDefinition[] ListFlows() { lock (sync) return flows.ToArray(); }
    public AppRegistration[] ListApps() { lock (sync) return apps.ToArray(); }
    public void SaveFlow(FlowDefinition flow)
    {
        Protocol.Validate(flow);
        lock (sync)
        {
            if (flows.Count >= 200 && flows.All(f => f.Id != flow.Id)) throw new CommandException("catalog_full", "流程数量超过限制。");
            flows = flows.Where(f => f.Id != flow.Id).Append(flow).ToList();
            Save("flows.json", flows);
        }
    }
    public void DeleteFlow(string id) { lock (sync) { flows.RemoveAll(f => f.Id == id); Save("flows.json", flows); } }
    public void RegisterApp(AppRegistration app)
    {
        if (!Path.IsPathFullyQualified(app.Executable) || !File.Exists(app.Executable) || !string.Equals(Path.GetExtension(app.Executable), ".exe", StringComparison.OrdinalIgnoreCase))
            throw new CommandException("invalid_executable", "请选择存在的 EXE 文件。");
        lock (sync) { apps = apps.Where(a => a.Id != app.Id).Append(app).ToList(); Save("apps.json", apps); }
    }
}
