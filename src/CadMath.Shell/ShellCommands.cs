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
}
