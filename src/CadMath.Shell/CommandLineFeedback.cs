using CadMath.Abstractions;

namespace CadMath.Shell;

/// <summary>
/// 把回显写到命令行：改写成功后回一行 <c>= 结果</c>，被拒绝时回一行原因。
/// 只影响观感，任何异常都必须被吞掉——它绝不能影响已经完成的输入改写。
/// </summary>
internal sealed class CommandLineFeedback : IUserFeedback
{
    private readonly ILogSink _log;

    public CommandLineFeedback(ILogSink log) => _log = log;

    public void OnReplaced(string original, string value)
    {
        Write("= " + Conversion.FormatForEcho(value));
        _log.Write(LogLevel.Info, "echo " + original + " => " + value);
    }

    public void OnRejected(string original, string code, string message)
    {
        Write("无法计算：" + message);
        _log.Write(LogLevel.Info, "echo rejected " + code + " " + original);
    }

    private static void Write(string text)
    {
        try
        {
            var document = Autodesk.AutoCAD.ApplicationServices.Application.DocumentManager.MdiActiveDocument;
            document?.Editor.WriteMessage("\n" + text + "\n");
        }
        catch
        {
            // 编辑器在命令切换间隙可能不可用，忽略。
        }
    }
}
