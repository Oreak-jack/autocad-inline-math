using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Runtime;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

namespace CadMath.Shell;

/// <summary>面向用户的命令。只做"转交 + 输出"，不实现计算或 CAD 细节。</summary>
public static class ShellCommands
{
    [CommandMethod("CM3ON")]
    public static void Enable() => ShellApplication.Manager?.Enable();

    [CommandMethod("CM3OFF")]
    public static void Disable() => ShellApplication.Manager?.Disable();

    [CommandMethod("CM3STATUS")]
    public static void Status()
    {
        var editor = AcApp.DocumentManager.MdiActiveDocument?.Editor;
        if (editor is null) return;

        var manager = ShellApplication.Manager;
        editor.WriteMessage("\n" + (manager?.Describe() ?? "CadMath 尚未初始化。") + "\n");
    }

    /// <summary>读取选中的最后一条 LINE 的长度，用来核对表达式结果是否真的落到了几何上。</summary>
    [CommandMethod("CM3CHECK")]
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
    [CommandMethod("CM3PROBE")]
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
}
