using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Oreak.ContextInput;

internal static class NativeInput
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref Gui info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("imm32.dll")] static extern IntPtr ImmGetContext(IntPtr hwnd);
    [DllImport("imm32.dll")] static extern bool ImmReleaseContext(IntPtr hwnd, IntPtr context);
    [DllImport("imm32.dll")] static extern bool ImmGetConversionStatus(IntPtr context, out uint conversion, out uint sentence);
    [DllImport("imm32.dll")] static extern bool ImmSetConversionStatus(IntPtr context, uint conversion, uint sentence);
    [DllImport("imm32.dll")] static extern bool ImmGetOpenStatus(IntPtr context);
    [DllImport("imm32.dll")] static extern bool ImmSetOpenStatus(IntPtr context, bool open);
    [DllImport("imm32.dll")] static extern uint ImmGetVirtualKey(IntPtr hwnd);
    public static int OriginalKey(IntPtr hwnd, int key) =>
        key == 0xE5 && hwnd != IntPtr.Zero && Focus() == hwnd ? (int)ImmGetVirtualKey(hwnd) : key;
    [DllImport("imm32.dll", CharSet = CharSet.Unicode)] static extern int ImmGetCompositionStringW(IntPtr context, uint index, IntPtr buffer, uint size);
    [DllImport("user32.dll")] static extern short GetKeyState(int key);
    public static bool KeyDown(int key) => (GetKeyState(key) & 0x8000) != 0;
    public static bool CompositionIdle(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || Focus() != hwnd) return false;
        var context = ImmGetContext(hwnd);
        if (context == IntPtr.Zero) return false;
        // Length only: do not read or log composition text. Errors are not idle.
        try { return ImmGetCompositionStringW(context, 8, IntPtr.Zero, 0) == 0; }
        finally { ImmReleaseContext(hwnd, context); }
    }
    [StructLayout(LayoutKind.Sequential)] struct Gui
    { public int Size, Flags; public IntPtr Active, Focus, Capture, Menu, Move, Caret; public int L,T,R,B; }

    public static IntPtr Focus()
    {
        uint pid; var thread = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        if (pid != (uint)Process.GetCurrentProcess().Id) return IntPtr.Zero;
        var g = new Gui { Size = Marshal.SizeOf(typeof(Gui)) };
        if (!GetGUIThreadInfo(thread, ref g)) return IntPtr.Zero;
        GetWindowThreadProcessId(g.Focus, out pid);
        return pid == (uint)Process.GetCurrentProcess().Id ? g.Focus : IntPtr.Zero;
    }
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
    public static bool BelongsTo(IntPtr child, IntPtr parent) =>
        child != IntPtr.Zero && parent != IntPtr.Zero && (child == parent || IsChild(parent, child));
    public static string Class(IntPtr hwnd)
    { var text = new StringBuilder(256); GetClassName(hwnd, text, text.Capacity); return text.ToString(); }
    public static InputMode Read(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || Focus() != hwnd) return InputMode.Unknown;
        var context = ImmGetContext(hwnd);
        if (context == IntPtr.Zero) return InputMode.Unknown;
        try
        {
            uint c, s;
            if (!ImmGetConversionStatus(context, out c, out s)) return InputMode.Unknown;
            return ImmGetOpenStatus(context) && (c & 1) != 0 ? InputMode.Chinese : InputMode.English;
        }
        finally { ImmReleaseContext(hwnd, context); }
    }
    public static bool Set(IntPtr hwnd, InputMode target)
    {
        if (hwnd == IntPtr.Zero || Focus() != hwnd || target == InputMode.Unknown) return false;
        var context = ImmGetContext(hwnd);
        if (context == IntPtr.Zero) return false;
        try
        {
            uint c, s;
            if (!ImmGetConversionStatus(context, out c, out s)) return false;
            // Weasel 0.17 maps open/close to ascii_mode. Conversion alone may
            // report success without changing the engine's language mode.
            // Set an explicit state, never toggle or inject Shift.
            bool chinese = target == InputMode.Chinese;
            if (Focus() != hwnd) return false;
            bool openAccepted = ImmGetOpenStatus(context) == chinese || ImmSetOpenStatus(context, chinese);
            if (Focus() != hwnd) return false;
            // Re-read after open/close callbacks and preserve width/punctuation/sentence bits.
            if (!ImmGetConversionStatus(context, out c, out s)) return false;
            bool conversionAccepted = ImmSetConversionStatus(context, chinese ? c | 1u : c & ~1u, s);
            // This return is API acceptance only; the controller must confirm readback.
            return openAccepted && conversionAccepted;
        }
        finally { ImmReleaseContext(hwnd, context); }
    }

    public static string Describe(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || Focus() != hwnd) return "focus-unavailable";
        var context = ImmGetContext(hwnd);
        if (context == IntPtr.Zero) return "context-unavailable";
        try
        {
            uint conversion, sentence;
            bool readable = ImmGetConversionStatus(context, out conversion, out sentence);
            return "open=" + ImmGetOpenStatus(context) + ",conversion-readable=" + readable +
                ",conversion=0x" + conversion.ToString("X") + ",sentence=0x" + sentence.ToString("X");
        }
        finally { ImmReleaseContext(hwnd, context); }
    }
}

