using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace EasyConnection.Core;

public static class Protocol
{
    public const int Version = 1;
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    public static readonly HashSet<string> ActionTypes =
    ["launch", "focusWindow", "click", "clickPointer", "movePointer", "scroll", "drag", "typeText", "typeFocusedText", "focusedKeyChord", "keyChord", "wait", "waitForElement", "invoke", "setValue", "assertElement", "screenshot"];

    public static readonly HashSet<string> InteractiveTypes =
    ["click", "scroll", "drag", "movePointer", "clickPointer", "typeFocusedText", "focusedKeyChord"];

    public static void Validate(ActionStep step)
    {
        if (!ActionTypes.Contains(step.Type)) throw new CommandException("unsupported_action", "不支持的动作类型。");
        if (step.TimeoutMs is < 100 or > 30_000) throw new CommandException("invalid_timeout", "超时必须在 100–30000 毫秒之间。");
        if (step.DelayMs is < 0 or > 30_000) throw new CommandException("invalid_delay", "等待时间必须在 0–30000 毫秒之间。");
        if ((step.Text?.Length ?? 0) > 32_768) throw new CommandException("text_too_long", "文字长度超过限制。");
        if (step.Type == "launch" && string.IsNullOrWhiteSpace(step.AppId)) throw new CommandException("missing_app", "请选择电脑端已注册的应用。");
        if (step.Type is "click" or "scroll" or "drag" && (step.X is not >= 0 or > 1 || step.Y is not >= 0 or > 1 || double.IsNaN(step.X.Value) || double.IsNaN(step.Y.Value)))
            throw new CommandException("invalid_coordinates", "点击坐标必须在 0–1 范围内。");
        if (step.Type == "drag" && (step.FromX is not >= 0 or > 1 || step.FromY is not >= 0 or > 1 || double.IsNaN(step.FromX.Value) || double.IsNaN(step.FromY.Value)))
            throw new CommandException("invalid_coordinates", "拖拽起点必须在 0–1 范围内。");
        if (step.Type == "scroll" && step.WheelDelta is < -1200 or > 1200 or 0)
            throw new CommandException("invalid_scroll", "滚动距离必须在 -1200–1200 之间且不能为零。");
        if (step.Type is "click" or "clickPointer" && step.Button is not ("left" or "right" or "double")) throw new CommandException("invalid_button", "不支持的鼠标按钮。");
        if (step.Type is "movePointer" or "clickPointer" && string.IsNullOrEmpty(step.SnapshotId)) throw new CommandException("missing_snapshot", "鼠标微调需要当前显示器截图。");
        if (step.Type == "movePointer" && (step.DeltaX is < -100 or > 100 || step.DeltaY is < -100 or > 100 || (step.DeltaX == 0 && step.DeltaY == 0)))
            throw new CommandException("invalid_delta", "鼠标微调范围为每次 1–100 个电脑像素。");
        if (step.Type == "clickPointer" && (step.DeltaX != 0 || step.DeltaY != 0)) throw new CommandException("invalid_delta", "当前位置点击不接受移动量。");
        if (step.Type is "typeText" or "keyChord" or "focusWindow" && step.Selector is null && string.IsNullOrEmpty(step.WindowId))
            throw new CommandException("missing_window", "此动作必须指定目标窗口。");
        if (step.Type is "typeFocusedText" or "focusedKeyChord" && string.IsNullOrEmpty(step.FocusId))
            throw new CommandException("missing_focus", "请先点击电脑上的目标输入位置。");
        if (step.Type is "invoke" or "setValue" or "waitForElement" or "assertElement" && step.Selector is null)
            throw new CommandException("missing_selector", "此动作必须指定控件选择条件。");
        if (step.Selector is { } selector && string.IsNullOrWhiteSpace(selector.ProcessName) && string.IsNullOrWhiteSpace(selector.WindowTitle))
            throw new CommandException("unscoped_selector", "控件查找必须限定应用进程或窗口标题。");
        if (step.Type is "keyChord" or "focusedKeyChord" && (step.Keys is not { Length: > 0 and <= 5 } || step.Keys.Any(k => !AllowedKeys.Contains(k))))
            throw new CommandException("invalid_keys", "快捷键包含不支持的按键。");
    }

    public static readonly HashSet<string> AllowedKeys = new(StringComparer.OrdinalIgnoreCase)
    { "CTRL", "ALT", "SHIFT", "WIN", "ENTER", "TAB", "ESC", "BACKSPACE", "DELETE", "SPACE", "UP", "DOWN", "LEFT", "RIGHT", "HOME", "END", "PAGEUP", "PAGEDOWN",
      "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
      "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };

    public static void Validate(FlowDefinition flow)
    {
        if (flow.Version != Version) throw new CommandException("invalid_version", "流程版本不受支持。");
        if (!Regex.IsMatch(flow.Id, "^[a-zA-Z0-9_-]{1,64}$")) throw new CommandException("invalid_id", "流程 ID 只能包含字母、数字、下划线和短横线。");
        if (string.IsNullOrWhiteSpace(flow.Name) || flow.Name.Length > 100) throw new CommandException("invalid_name", "流程名称必须为 1–100 个字符。");
        if (flow.Steps.Count is < 1 or > 100) throw new CommandException("invalid_steps", "流程必须包含 1–100 个步骤。");
        if (flow.Parameters.Count > 20 || flow.Parameters.Select(p => p.Name).Distinct().Count() != flow.Parameters.Count ||
            flow.Parameters.Any(p => !Regex.IsMatch(p.Name, "^[a-zA-Z][a-zA-Z0-9_]{0,31}$")))
            throw new CommandException("invalid_parameters", "参数名称必须唯一，并使用字母、数字和下划线。");
        foreach (var step in flow.Steps) Validate(step);
    }

    public static FlowDefinition Bind(FlowDefinition flow, IReadOnlyDictionary<string, string> arguments)
    {
        Validate(flow);
        var names = flow.Parameters.Select(p => p.Name).ToHashSet(StringComparer.Ordinal);
        if (arguments.Keys.Any(k => !names.Contains(k))) throw new CommandException("unknown_parameter", "请求包含未定义的参数。");
        foreach (var parameter in flow.Parameters)
            if (parameter.Required && (!arguments.TryGetValue(parameter.Name, out var value) || string.IsNullOrEmpty(value)))
                throw new CommandException("missing_parameter", $"缺少参数：{parameter.Name}");
        var steps = flow.Steps.Select(step => step with
        {
            Text = step.Text is null ? null : Regex.Replace(step.Text, @"\$\{([a-zA-Z][a-zA-Z0-9_]*)\}", match =>
                names.Contains(match.Groups[1].Value) ? arguments.GetValueOrDefault(match.Groups[1].Value, "") :
                throw new CommandException("unknown_parameter", "文字模板引用了未定义的参数。"))
        }).ToList();
        foreach (var step in steps) Validate(step);
        return flow with { Steps = steps };
    }
}

public sealed class CommandException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

public sealed record ElementSelector(string? ProcessName = null, string? WindowTitle = null, string? AutomationId = null, string? Name = null, string? ControlType = null);
public sealed record ActionStep(string Type)
{
    public string? AppId { get; init; }
    public string? WindowId { get; init; }
    public string? FocusId { get; init; }
    public ElementSelector? Selector { get; init; }
    public string? Text { get; init; }
    public string[]? Keys { get; init; }
    public double? X { get; init; }
    public double? Y { get; init; }
    public double? FromX { get; init; }
    public double? FromY { get; init; }
    public int DeltaX { get; init; }
    public int DeltaY { get; init; }
    public int WheelDelta { get; init; } = -120;
    public string Button { get; init; } = "left";
    public string? DisplayId { get; init; }
    public string? SnapshotId { get; init; }
    public int TimeoutMs { get; init; } = 5000;
    public int DelayMs { get; init; }
}
public sealed record FlowParameter(string Name, string Label, bool Required = true);
public sealed record FlowDefinition(string Id, string Name, string Description, List<FlowParameter> Parameters, List<ActionStep> Steps, int Version = 1);
public sealed record AppRegistration(string Id, string Name, string Executable, string[] Arguments);
public sealed record WindowInfo(string Id, string Title, string ProcessName, int X, int Y, int Width, int Height);
public sealed record DisplayInfo(string Id, string Name, int X, int Y, int Width, int Height, bool Primary);
public sealed record CursorInfo(double X, double Y, bool Inside, bool Visible);
public sealed record SnapshotInfo(string Id, string DisplayId, int Width, int Height, DateTimeOffset CapturedAt, string LayoutId, CursorInfo? Cursor = null);
public sealed record FocusInfo(string Id, string WindowId, bool? Editable, string Description);
public sealed record ActionResult(string Message, SnapshotInfo? Snapshot = null, CursorInfo? Cursor = null, FocusInfo? Focus = null);
public sealed record ActionRequest(string RequestId, ActionStep Action);
public sealed record RunRequest(string RequestId, Dictionary<string, string> Arguments);
public sealed record StepResult(int Index, string Type, string State, string? Message, SnapshotInfo? Snapshot = null);
public sealed record TaskRecord(string Id, string DeviceId, string RequestId, string RequestHash, string FlowId, string FlowName,
    string State, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt, List<StepResult> Steps, string? Error = null);

public interface IDesktopRuntime
{
    Task<ActionResult> ExecuteAsync(ActionStep step, CancellationToken cancellationToken);
}
