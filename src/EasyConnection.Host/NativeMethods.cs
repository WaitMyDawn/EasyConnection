using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace EasyConnection.Host;

internal static class NativeMethods
{
    internal delegate bool EnumWindowProc(nint window, nint parameter);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumWindows(EnumWindowProc callback, nint parameter);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindow(nint window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(nint window, StringBuilder text, int maxCount);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetWindowRect(nint window, out RECT rectangle);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsZoomed(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
    [DllImport("user32.dll", SetLastError = true)] internal static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetCursorInfo(ref CURSORINFO cursor);
    [DllImport("user32.dll", SetLastError = true)] internal static extern nint OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CloseDesktop(nint desktop);

    [StructLayout(LayoutKind.Sequential)] internal struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] internal struct CURSORINFO { public uint Size, Flags; public nint Cursor; public POINT Position; }
    [StructLayout(LayoutKind.Sequential)] internal struct GUITHREADINFO
    {
        public uint Size, Flags;
        public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public RECT CaretBounds;
    }
    internal static nint FocusHandle()
    {
        var info = new GUITHREADINFO { Size = (uint)Marshal.SizeOf<GUITHREADINFO>() };
        return GetGUIThreadInfo(0, ref info) ? info.Focus : 0;
    }
    internal static CURSORINFO? ReadCursor()
    {
        var info = new CURSORINFO { Size = (uint)Marshal.SizeOf<CURSORINFO>() };
        return GetCursorInfo(ref info) ? info : null;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct INPUT { public uint Type; public INPUTUNION Data; }
    [StructLayout(LayoutKind.Explicit)] internal struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT Mouse;
        [FieldOffset(0)] public KEYBDINPUT Keyboard;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct MOUSEINPUT { public int X, Y; public uint MouseData, Flags, Time; public nuint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] internal struct KEYBDINPUT { public ushort VirtualKey, Scan; public uint Flags, Time; public nuint ExtraInfo; }

    internal static string WindowId(nint window)
    {
        GetWindowThreadProcessId(window, out var pid);
        using var process = Process.GetProcessById((int)pid);
        return $"{window:x}:{pid}:{process.StartTime.ToUniversalTime().Ticks}";
    }
    internal static nint ResolveWindow(string id)
    {
        var parts = id.Split(':');
        if (parts.Length != 3 || !long.TryParse(parts[0], System.Globalization.NumberStyles.HexNumber, null, out var handle))
            throw new CommandException("invalid_window", "窗口标识无效。");
        var window = (nint)handle;
        try { if (IsWindow(window) && WindowId(window) == id) return window; }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        throw new CommandException("window_changed", "目标窗口已关闭或发生变化，请重新选择。");
    }

    internal static void Send(params INPUT[] input)
    {
        if (SendInput((uint)input.Length, input, Marshal.SizeOf<INPUT>()) != input.Length)
            throw new CommandException("input_blocked", "系统未接受全部输入。请检查权限、锁屏和目标窗口。");
    }
    internal static INPUT Key(ushort key, bool up = false) => new() { Type = 1, Data = new() { Keyboard = new() { VirtualKey = key, Flags = up ? 2u : 0u } } };
    internal static INPUT Unicode(char character, bool up) => new() { Type = 1, Data = new() { Keyboard = new() { Scan = character, Flags = 4u | (up ? 2u : 0u) } } };
    internal static INPUT Mouse(uint flags, int data = 0) => new() { Type = 0, Data = new() { Mouse = new() { Flags = flags, MouseData = unchecked((uint)data) } } };
}
