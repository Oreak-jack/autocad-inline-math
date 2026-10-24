using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Runtime;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

namespace CadMath.Shell;

/// <summary>面向用户的命令。只做"转交 + 输出"，不实现计算或 CAD 细节。</summary>
public static class ShellCommands
{
    [CommandMethod("CLMON")]
    public static void Enable() => ShellApplication.Manager?.Enable();

    [CommandMethod("CLMOFF")]
    public static void Disable() => ShellApplication.Manager?.Disable();

    /// <summary>
    /// 0.5.0：改写后的即时回显开关。关键字 ON / OFF，直接回车＝切换。
    /// 关闭后只写日志、不往命令行插字。
    /// </summary>
    [CommandMethod("CLMECHO")]
    public static void Echo()
    {
        var manager = ShellApplication.Manager;
        var document = AcApp.DocumentManager.MdiActiveDocument;
        if (manager is null || document is null) return;

        var feedback = manager.Feedback;
        var options = new PromptKeywordOptions(
            "\n回显 = 结果（当前：" + (feedback.Enabled ? "开" : "关") + "）[ON/OFF]",
            "ON OFF");
        options.AllowNone = true;

        var result = document.Editor.GetKeywords(options);
        switch (result.StringResult)
        {
            case "ON":
                feedback.Enabled = true;
                break;
            case "OFF":
                feedback.Enabled = false;
                break;
            default:
                feedback.Enabled = !feedback.Enabled;
                break;
        }

        document.Editor.WriteMessage("\n回显：" + (feedback.Enabled ? "开" : "关") + "\n");
    }

    /// <summary>
    /// 0.5.0：输入提示风格。AUTO = 跟随 AutoCAD 原生（默认），STANDARD = 统一提示。
    /// 直接回车＝在两者之间切换。
    /// </summary>
    [CommandMethod("CLMSTYLE")]
    public static void Style()
    {
        var manager = ShellApplication.Manager;
        var document = AcApp.DocumentManager.MdiActiveDocument;
        if (manager is null || document is null) return;

        var current = AdapterManager.DescribeStyle(manager.Style);
        var options = new PromptKeywordOptions("\n提示风格（当前：" + current + "）[AUTO/STANDARD]", "AUTO STANDARD");
        options.AllowNone = true;

        var result = document.Editor.GetKeywords(options);
        var next = manager.Style;
        if (result.Status == PromptStatus.OK)
        {
            next = result.StringResult == "STANDARD" ? CadMath.Abstractions.PromptStyle.Standard : CadMath.Abstractions.PromptStyle.AutoCad;
        }
        else
        {
            next = manager.Style == CadMath.Abstractions.PromptStyle.Standard
                ? CadMath.Abstractions.PromptStyle.AutoCad
                : CadMath.Abstractions.PromptStyle.Standard;
        }

        manager.Style = next;
        document.Editor.WriteMessage("\n提示风格：" + AdapterManager.DescribeStyle(next) + "\n");
    }

    [CommandMethod("CLMSTATUS")]
    public static void Status()
    {
        var editor = AcApp.DocumentManager.MdiActiveDocument?.Editor;
        if (editor is null) return;

        var manager = ShellApplication.Manager;
        editor.WriteMessage("\n" + (manager?.Describe() ?? "CadMath 尚未初始化。") + "\n");
    }

    /// <summary>读取选中的最后一条 LINE 的长度，用来核对表达式结果是否真的落到了几何上。</summary>
    [CommandMethod("CLMCHECK")]
    public static void Check()
    {
        var document = AcApp.DocumentManager.MdiActiveDocument;
        if (document is null) return;

        var editor = document.Editor;
        var selection = editor.SelectLast();
        if (selection.Status != PromptStatus.OK) return;

        using var transaction = document.Database.TransactionManager.StartOpenCloseTransaction();
        foreach (var id in selection.Value.GetObjectIds())
        {
            if (transaction.GetObject(id, OpenMode.ForRead) is not Line line) continue;

            var result = "last LINE length=" + line.Length.ToString("G17", System.Globalization.CultureInfo.InvariantCulture);
            editor.WriteMessage("\n" + result + "\n");
            LogFile.Write(Abstractions.LogLevel.Info, result);
        }
    }

    /// <summary>
    /// 诊断用：把"这套适配器在这个 CAD 里到底看到了什么"打印出来并写入日志。
    /// 2024 适配器没有真机验证过，这一条命令就是让对方把现场贴回来的工具。
    /// </summary>
    [CommandMethod("CLMPROBE")]
    public static void Probe()
    {
        var document = AcApp.DocumentManager.MdiActiveDocument;
        var editor = document?.Editor;
        if (editor is null) return;

        var lines = new List<string>
        {
            "product=" + ProductInfo.Name + " " + ProductInfo.Version,
            "clr=" + Environment.Version,
            "host=" + (ShellApplication.Manager?.Host.ToString() ?? "?"),
            "activeAdapter=" + (ShellApplication.Manager?.Active?.Id ?? "-"),
            "hostModules=" + HostProbe.DescribeModules()
        };

        try
        {
            var focused = System.Windows.Input.Keyboard.FocusedElement;
            lines.Add("focused=" + (focused?.GetType().FullName ?? "(null)"));
        }
        catch (System.Exception ex)
        {
            lines.Add("focused=<" + ex.GetType().Name + ">");
        }

        try
        {
            var editor_ = AcApp.UIBindings.CommandEditorManager.ActiveEditor;
            var prompt = editor_?.PromptAndInput;
            var buffer = prompt?.InputBuffer;
            lines.Add("commandEditor=" + (editor_ is null ? "(null)" : "ok"));
            lines.Add("promptAndInput=" + (prompt is null ? "(null)" : "ok"));
            lines.Add("inputBuffer=" + (buffer is null ? "(null)" : "ok"));
            if (buffer is not null) lines.Add("inputText=" + buffer.Text + " promptingForCommandName=" + buffer.IsPromptingForCommandName());
        }
        catch (System.Exception ex)
        {
            lines.Add("uibindings=<" + ex.GetType().Name + ": " + ex.Message + ">");
        }

        foreach (var line in lines)
        {
            editor.WriteMessage("\n" + line);
            LogFile.Write(Abstractions.LogLevel.Info, "probe " + line);
        }

        editor.WriteMessage("\n");
    }

    /// <summary>
    /// 焦点取证：在命令行里敲它，立刻把"插件眼里的焦点长什么样"写进日志。
    /// 拦截失效时先用它定性是焦点判定没中、还是输入缓冲取不到。
    /// </summary>
    [CommandMethod("CM3FOCUS")]
    public static void Focus()
    {
        var document = AcApp.DocumentManager.MdiActiveDocument;
        var editor = document?.Editor;
        if (editor is null) return;

        var lines = new List<string>();

        try
        {
            var focused = System.Windows.Input.Keyboard.FocusedElement;
            lines.Add("wpfFocused=" + (focused?.GetType().FullName ?? "(null)"));
            lines.Add("wpfIsTextBox=" + (focused is System.Windows.Controls.TextBox).ToString().ToLowerInvariant());
        }
        catch (System.Exception ex)
        {
            lines.Add("wpfFocused=<" + ex.GetType().Name + ">");
        }

        try
        {
            var native = GetFocus();
            var className = "(0)";
            if (native != IntPtr.Zero)
            {
                var buffer = new System.Text.StringBuilder(256);
                var length = GetClassName(native, buffer, buffer.Capacity);
                className = length > 0 ? buffer.ToString(0, length) : "(empty)";
            }

            var documentWindow = document.Window.Handle;
            lines.Add("nativeClass=" + className);
            lines.Add("nativeIsDocument=" + (native == documentWindow).ToString().ToLowerInvariant());
            lines.Add("nativeIsChildOfDocument=" + (native != IntPtr.Zero && IsChild(documentWindow, native)).ToString().ToLowerInvariant());
        }
        catch (System.Exception ex)
        {
            lines.Add("native=<" + ex.GetType().Name + ">");
        }

        try
        {
            var buffer = AcApp.UIBindings.CommandEditorManager.ActiveEditor?.PromptAndInput?.InputBuffer;
            lines.Add("inputBuffer=" + (buffer is null ? "(null)" : "ok"));
            if (buffer is not null)
            {
                lines.Add("inputText=[" + buffer.Text + "]");
                lines.Add("promptingForCommandName=" + buffer.IsPromptingForCommandName().ToString().ToLowerInvariant());
            }
        }
        catch (System.Exception ex)
        {
            lines.Add("inputBuffer=<" + ex.GetType().Name + ": " + ex.Message + ">");
        }

        lines.Add("activeCommand=" + (AcApp.GetSystemVariable("CMDNAMES")?.ToString() ?? "(null)"));

        foreach (var line in lines)
        {
            editor.WriteMessage("\n" + line);
            LogFile.Write(Abstractions.LogLevel.Info, "focus " + line);
        }

        editor.WriteMessage("\n");
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr GetFocus();

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool IsChild(IntPtr parent, IntPtr child);

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int maxCount);
}
