using System.Diagnostics;
using System.Drawing;
using System.Windows.Automation;
using System.Security.Cryptography;
using System.Text;

namespace EasyConnection.Host;

public sealed class DesktopRuntime(Catalog catalog, SnapshotService snapshots, Func<nint>? isolatedWindow = null) : IDesktopRuntime
{
    public Task<object> ElementsAsync(string windowId) => Task.Run<object>(() =>
    {
        var window = FindWindow(new ActionStep("focusWindow") { WindowId = windowId });
        var root = AutomationElement.FromHandle(window);
        var elements = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        var results = new List<object>();
        for (var index = 0; index < Math.Min(elements.Count, 500); index++)
        {
            var element = elements[index].Current;
            if (string.IsNullOrEmpty(element.Name) && string.IsNullOrEmpty(element.AutomationId)) continue;
            results.Add(new { name = element.Name, automationId = element.AutomationId,
                controlType = element.ControlType.ProgrammaticName.Replace("ControlType.", "", StringComparison.Ordinal), enabled = element.IsEnabled });
        }
        return new { elements = results.ToArray(), enumerated = elements.Count, truncated = elements.Count > 500, coverage = "uia-provider", windowId, capturedAt = DateTimeOffset.UtcNow };
    });

    public WindowInfo[] Windows()
    {
        var windows = new List<WindowInfo>();
        NativeMethods.EnumWindows((window, _) =>
        {
            if (!NativeMethods.IsWindowVisible(window) || (isolatedWindow is not null && window != isolatedWindow())) return true;
            var title = new System.Text.StringBuilder(512);
            NativeMethods.GetWindowText(window, title, title.Capacity);
            if (title.Length == 0 || !NativeMethods.GetWindowRect(window, out var bounds)) return true;
            try
            {
                NativeMethods.GetWindowThreadProcessId(window, out var pid);
                using var process = Process.GetProcessById((int)pid);
                windows.Add(new(NativeMethods.WindowId(window), title.ToString(), process.ProcessName, bounds.Left, bounds.Top, bounds.Right - bounds.Left, bounds.Bottom - bounds.Top));
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
            return true;
        }, 0);
        return windows.ToArray();
    }

    public Task<ActionResult> ExecuteAsync(ActionStep step, CancellationToken cancellationToken) => Task.Run<ActionResult>(async () =>
    {
        Protocol.Validate(step);
        cancellationToken.ThrowIfCancellationRequested();
        switch (step.Type)
        {
            case "wait":
                await Task.Delay(step.DelayMs, cancellationToken);
                return new("等待完成。");
            case "screenshot": return new("截图已获取。", snapshots.Capture(step.DisplayId).Info);
            case "launch":
                if (isolatedWindow is not null) throw new CommandException("test_scope", "隔离测试不允许启动外部应用。");
                var app = catalog.ListApps().FirstOrDefault(a => a.Id == step.AppId) ?? throw new CommandException("app_missing", "应用未在电脑端注册。");
                var start = new ProcessStartInfo(app.Executable) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(app.Executable)! };
                foreach (var argument in app.Arguments) start.ArgumentList.Add(argument);
                using (var process = Process.Start(start)) { }
                return new("应用启动请求已提交。");
            case "focusWindow":
                await FocusAsync(FindWindow(step), cancellationToken);
                return new("目标窗口已激活。");
            case "movePointer":
            case "clickPointer":
                var reference = snapshots.ValidSnapshot(step.SnapshotId!);
                var currentPointer = NativeMethods.ReadCursor() ?? throw new CommandException("cursor_unavailable", "无法读取电脑鼠标位置。");
                var region = reference.Bounds;
                var destination = PointerGeometry.Move(currentPointer.Position.X, currentPointer.Position.Y, step.DeltaX, step.DeltaY, region.X, region.Y, region.Width, region.Height);
                EnsureIsolatedPoint(new Point(destination.X, destination.Y));
                EnsureNoModifiers();
                if (step.Type == "movePointer")
                {
                    if (!NativeMethods.SetCursorPos(destination.X, destination.Y)) throw new CommandException("input_blocked", "无法移动鼠标。");
                    return new("鼠标已微调。", Cursor: SnapshotService.CursorAt(region));
                }
                await ClickAsync(step.Button, cancellationToken);
                return new("已在鼠标当前位置点击。", Cursor: SnapshotService.CursorAt(region), Focus: Focus());
            case "click":
            case "scroll":
            case "drag":
                Point point;
                Point? dragStart = null;
                if (step.Selector is not null || step.WindowId is not null)
                {
                    var window = FindWindow(step);
                    await FocusAsync(window, cancellationToken);
                    NativeMethods.GetWindowRect(window, out var bounds);
                    point = new(bounds.Left + (int)(step.X!.Value * (bounds.Right - bounds.Left - 1)), bounds.Top + (int)(step.Y!.Value * (bounds.Bottom - bounds.Top - 1)));
                    if (step.Type == "drag") dragStart = new(bounds.Left + (int)(step.FromX!.Value * (bounds.Right - bounds.Left - 1)), bounds.Top + (int)(step.FromY!.Value * (bounds.Bottom - bounds.Top - 1)));
                }
                else point = snapshots.ResolvePoint(step.SnapshotId ?? throw new CommandException("missing_snapshot", "截图点击必须指定截图 ID。"), step.X!.Value, step.Y!.Value);
                if (step.Type == "drag" && dragStart is null) dragStart = snapshots.ResolvePoint(step.SnapshotId!, step.FromX!.Value, step.FromY!.Value);
                EnsureIsolatedPoint(point);
                EnsureNoModifiers();
                if (step.Type == "drag")
                {
                    EnsureIsolatedPoint(dragStart!.Value);
                    if (!NativeMethods.SetCursorPos(dragStart.Value.X, dragStart.Value.Y)) throw new CommandException("input_blocked", "无法移动鼠标。");
                    try
                    {
                        NativeMethods.Send(NativeMethods.Mouse(0x0002));
                        for (var move = 1; move <= 12; move++)
                        {
                            cancellationToken.ThrowIfCancellationRequested();
                            if (!NativeMethods.SetCursorPos(dragStart.Value.X + (point.X - dragStart.Value.X) * move / 12, dragStart.Value.Y + (point.Y - dragStart.Value.Y) * move / 12))
                                throw new CommandException("input_blocked", "鼠标移动被系统阻止。");
                            await Task.Delay(15, cancellationToken);
                        }
                    }
                    finally { NativeMethods.Send(NativeMethods.Mouse(0x0004)); }
                    return new("拖拽已执行。");
                }
                if (!NativeMethods.SetCursorPos(point.X, point.Y)) throw new CommandException("input_blocked", "无法移动鼠标。");
                if (step.Type == "scroll") { NativeMethods.Send(NativeMethods.Mouse(0x0800, step.WheelDelta)); return new("滚动已执行。"); }
                await ClickAsync(step.Button, cancellationToken);
                return new("点击已执行。", Focus: Focus());
            case "typeFocusedText":
                var focused = RequireFocus(step.FocusId!);
                if (focused.Editable == false) throw new CommandException("not_editable", "当前控件不可编辑，请先点击输入框。");
                await TypeAsync(step.Text ?? "", NativeMethods.ResolveWindow(focused.WindowId), cancellationToken);
                return new("文字已输入到当前焦点，换行使用 Shift+Enter。", Focus: Focus());
            case "focusedKeyChord":
                var keyFocus = RequireFocus(step.FocusId!);
                SendKeys(step.Keys!, NativeMethods.ResolveWindow(keyFocus.WindowId));
                return new("按键已发送到当前焦点。", Focus: Focus());
            case "typeText":
                var textWindow = FindWindow(step);
                await FocusAsync(textWindow, cancellationToken);
                await TypeAsync(step.Text ?? "", textWindow, cancellationToken);
                return new("文字输入已提交。");
            case "keyChord":
                var keyWindow = FindWindow(step);
                await FocusAsync(keyWindow, cancellationToken);
                SendKeys(step.Keys!, keyWindow);
                return new("快捷键已执行。");
            case "waitForElement":
                var deadline = DateTimeOffset.UtcNow.AddMilliseconds(step.TimeoutMs);
                while (true)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    try { _ = FindElement(step); return new("目标控件已出现。"); }
                    catch (CommandException error) when (error.Code is "window_missing" or "element_missing")
                    {
                        if (DateTimeOffset.UtcNow >= deadline) throw new CommandException("element_timeout", "等待目标控件超时。");
                        await Task.Delay(150, cancellationToken);
                    }
                }
            case "assertElement":
                var assertion = FindElement(step);
                if (step.Text is not null && (!assertion.TryGetCurrentPattern(ValuePattern.Pattern, out var current) || ((ValuePattern)current).Current.Value != step.Text))
                    throw new CommandException("assertion_failed", "控件内容与预期不一致。");
                return new("控件检查通过。");
            case "invoke":
                var element = FindElement(step);
                if (!element.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke)) throw new CommandException("pattern_unavailable", "此控件不支持直接调用。");
                ((InvokePattern)invoke).Invoke();
                return new("控件调用已提交；请检查应用结果。");
            case "setValue":
                var input = FindElement(step);
                if (!input.TryGetCurrentPattern(ValuePattern.Pattern, out var value) || ((ValuePattern)value).Current.IsReadOnly)
                    throw new CommandException("pattern_unavailable", "此控件不支持直接写入，请改用文字输入动作。");
                ((ValuePattern)value).SetValue(step.Text ?? "");
                return new("控件内容已设置。");
            default: throw new CommandException("unsupported_action", "不支持的动作。");
        }
    }, cancellationToken);

    private nint FindWindow(ActionStep step)
    {
        var window = step.WindowId is not null ? NativeMethods.ResolveWindow(step.WindowId) : FindWindow(step.Selector!);
        if (isolatedWindow is not null && window != isolatedWindow()) throw new CommandException("test_scope", "目标不属于隔离测试窗口。");
        return window;
    }
    private nint FindWindow(ElementSelector selector)
    {
        var matches = Windows().Where(w => (selector.ProcessName is null || string.Equals(w.ProcessName, selector.ProcessName, StringComparison.OrdinalIgnoreCase)) &&
            (selector.WindowTitle is null || w.Title == selector.WindowTitle)).ToArray();
        if (matches.Length == 0) throw new CommandException("window_missing", "找不到目标窗口。");
        if (matches.Length != 1) throw new CommandException("ambiguous_window", "匹配了多个窗口，请补充准确窗口标题。");
        return NativeMethods.ResolveWindow(matches[0].Id);
    }
    private AutomationElement FindElement(ActionStep step)
    {
        var selector = step.Selector!;
        var root = AutomationElement.FromHandle(FindWindow(step));
        var conditions = new List<Condition>();
        if (selector.AutomationId is not null) conditions.Add(new PropertyCondition(AutomationElement.AutomationIdProperty, selector.AutomationId));
        if (selector.Name is not null) conditions.Add(new PropertyCondition(AutomationElement.NameProperty, selector.Name));
        if (selector.ControlType is not null)
        {
            var type = typeof(ControlType).GetField(selector.ControlType)?.GetValue(null) as ControlType
                ?? throw new CommandException("invalid_control_type", "控件类型无效。");
            conditions.Add(new PropertyCondition(AutomationElement.ControlTypeProperty, type));
        }
        if (conditions.Count == 0) throw new CommandException("missing_element_condition", "请指定控件名称、AutomationId 或类型。");
        var matches = root.FindAll(TreeScope.Descendants, conditions.Count == 1 ? conditions[0] : new AndCondition(conditions.ToArray()));
        if (matches.Count == 0) throw new CommandException("element_missing", "找不到目标控件。");
        if (matches.Count != 1) throw new CommandException("ambiguous_element", "匹配了多个控件，请补充选择条件。");
        if (!matches[0].Current.IsEnabled) throw new CommandException("element_disabled", "目标控件当前不可用。");
        return matches[0];
    }
    private static async Task FocusAsync(nint window, CancellationToken cancellationToken)
    {
        if (NativeMethods.IsIconic(window)) NativeMethods.ShowWindow(window, 9);
        NativeMethods.SetForegroundWindow(window);
        await Task.Delay(100, cancellationToken);
        EnsureForeground(window);
    }
    public FocusInfo Focus()
    {
        var window = NativeMethods.GetForegroundWindow();
        if (window == 0) throw new CommandException("focus_missing", "电脑当前没有可输入的窗口。");
        if (isolatedWindow is not null && window != isolatedWindow()) throw new CommandException("test_scope", "焦点不属于隔离测试窗口。");
        var windowId = NativeMethods.WindowId(window);
        var identity = $"{windowId}:{NativeMethods.FocusHandle():x}";
        bool? editable = null;
        var description = "应用未提供输入框识别，可向当前焦点输入";
        try
        {
            var element = AutomationElement.FocusedElement;
            NativeMethods.GetWindowThreadProcessId(window, out var processId);
            if (element is not null && element.Current.ProcessId == processId)
            {
                identity += ":" + string.Join(",", element.GetRuntimeId());
                var properties = element.Current;
                editable = !properties.IsEnabled ? false :
                    element.TryGetCurrentPattern(ValuePattern.Pattern, out var value) ? !((ValuePattern)value).Current.IsReadOnly :
                    properties.ControlType == ControlType.Edit && properties.HasKeyboardFocus ? true : null;
                description = editable == true ? "已识别当前输入框" : editable == false ? "当前焦点不是可编辑输入框" : description;
            }
        }
        catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or System.Runtime.InteropServices.COMException) { }
        return new(Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity))), windowId, editable, description);
    }
    private FocusInfo RequireFocus(string expected)
    {
        var focus = Focus();
        if (focus.Id != expected) throw new CommandException("focus_changed", "电脑焦点已经改变，请重新点击目标输入位置。");
        return focus;
    }
    private static async Task ClickAsync(string button, CancellationToken token)
    {
        var down = button == "right" ? 0x0008u : 0x0002u;
        var up = button == "right" ? 0x0010u : 0x0004u;
        for (var count = 0; count < (button == "double" ? 2 : 1); count++)
        {
            try { NativeMethods.Send(NativeMethods.Mouse(down)); await Task.Delay(25, token); }
            finally { NativeMethods.Send(NativeMethods.Mouse(up)); }
        }
        // Popup menus are created after button release; snapshot callers must observe the resulting UI state.
        await Task.Delay(100, token);
    }
    private static async Task TypeAsync(string text, nint window, CancellationToken token)
    {
        EnsureNoModifiers();
        var focusHandle = NativeMethods.FocusHandle();
        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n');
        for (var line = 0; line < lines.Length; line++)
        {
            token.ThrowIfCancellationRequested();
            EnsureForeground(window);
            if (NativeMethods.FocusHandle() != focusHandle) throw new CommandException("focus_changed", "输入焦点已经改变，后续文字已停止。");
            if (line > 0) SendKeys(["SHIFT", "ENTER"], window);
            for (var offset = 0; offset < lines[line].Length; offset += 32)
            {
                token.ThrowIfCancellationRequested();
                EnsureForeground(window);
                if (NativeMethods.FocusHandle() != focusHandle) throw new CommandException("focus_changed", "输入焦点已经改变，后续文字已停止。");
                NativeMethods.Send(lines[line].Skip(offset).Take(32).SelectMany(c => new[] { NativeMethods.Unicode(c, false), NativeMethods.Unicode(c, true) }).ToArray());
                await Task.Yield();
            }
        }
        await Task.Delay(40, token);
    }
    private static void SendKeys(string[] chord, nint window)
    {
        EnsureNoModifiers();
        var keys = chord.Select(KeyCode).Distinct().ToArray();
        try { EnsureForeground(window); NativeMethods.Send(keys.Select(k => NativeMethods.Key(k)).ToArray()); }
        finally { NativeMethods.Send(keys.Reverse().Select(k => NativeMethods.Key(k, true)).ToArray()); }
    }
    private static void EnsureForeground(nint window)
    {
        if (NativeMethods.GetForegroundWindow() != window) throw new CommandException("focus_denied", "目标窗口未获得焦点，已停止输入。");
    }
    private void EnsureIsolatedPoint(Point point)
    {
        if (isolatedWindow is null) return;
        NativeMethods.GetWindowRect(isolatedWindow(), out var rectangle);
        if (point.X < rectangle.Left || point.Y < rectangle.Top || point.X >= rectangle.Right || point.Y >= rectangle.Bottom)
            throw new CommandException("test_scope", "点击位置不属于隔离测试窗口。");
    }
    private static void EnsureNoModifiers()
    {
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => NativeMethods.GetAsyncKeyState(key) < 0))
            throw new CommandException("modifier_pressed", "电脑本地正按住修饰键，请释放后再试。");
    }
    private static ushort KeyCode(string key) => key.ToUpperInvariant() switch
    {
        "CTRL" => 0x11, "ALT" => 0x12, "SHIFT" => 0x10, "WIN" => 0x5B, "ENTER" => 0x0D, "TAB" => 0x09, "ESC" => 0x1B,
        "BACKSPACE" => 0x08, "DELETE" => 0x2E, "SPACE" => 0x20, "UP" => 0x26, "DOWN" => 0x28, "LEFT" => 0x25, "RIGHT" => 0x27,
        "HOME" => 0x24, "END" => 0x23, "PAGEUP" => 0x21, "PAGEDOWN" => 0x22,
        _ when key.Length == 1 && char.IsAsciiLetterOrDigit(key[0]) => char.ToUpperInvariant(key[0]),
        _ when key.StartsWith("F", StringComparison.OrdinalIgnoreCase) && int.TryParse(key.AsSpan(1), out var number) && number is >= 1 and <= 12 => (ushort)(0x6F + number),
        _ => throw new CommandException("invalid_keys", "不支持的按键。")
    };
}
