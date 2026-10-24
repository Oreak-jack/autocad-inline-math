using System.Threading;
using Autodesk.AutoCAD.ApplicationServices;
using CadMath.Abstractions;

namespace CadMath.Shell;

/// <summary>
/// 把回显写到命令行：改写成功后补一行 <c>← 5+6 = 11</c>，被拒绝时补一行原因。
/// <para>
/// 时序（0.5.2 的观感缺陷全在这里）：回显发生在按键处理那一刻，而 AutoCAD 把
/// <c>5+6</c> 替换成 <c>11</c> 要等这条消息处理完。当场写 = 叠字
/// （<c>5+6 = 1111</c>）；写成队列末尾的 Post = 命令行正忙时不可靠。
/// 所以现在延后 90 ms 再派回 UI 线程写，等替换落地后单独占一行。
/// </para>
/// <para>
/// 只影响观感，任何异常都必须被吞掉——它绝不能影响已经完成的输入改写。
/// </para>
/// </summary>
internal sealed class CommandLineFeedback : IUserFeedback
{
    private const int DelayMilliseconds = 90;
    private const int DedupeMilliseconds = 800;

    private readonly ILogSink _log;
    private readonly SynchronizationContext? _context;
    private Timer? _timer;
    private string _lastText = string.Empty;
    private DateTime _lastAt = DateTime.MinValue;

    public CommandLineFeedback(ILogSink log)
    {
        _log = log;
        _context = SynchronizationContext.Current;
    }

    public void OnReplaced(string original, string value)
    {
        Schedule("  ← " + Short(original) + " = " + Conversion.FormatForEcho(value));
        _log.Write(LogLevel.Info, "echo " + original + " => " + value);
    }

    public void OnRejected(string original, string code, string message)
    {
        Schedule("  无法计算：" + message + "（输入 " + Short(original) + "）");
        _log.Write(LogLevel.Info, "echo rejected " + code + " " + original);
    }

    /// <summary>提示里的原文本别太长，回显是给人看的，不是日志。</summary>
    private static string Short(string text)
    {
        if (string.IsNullOrEmpty(text)) return string.Empty;
        var trimmed = text.Trim();
        return trimmed.Length <= 24 ? trimmed : trimmed.Substring(0, 24) + "…";
    }

    private void Schedule(string text)
    {
        var now = DateTime.UtcNow;
        if (string.Equals(text, _lastText, StringComparison.Ordinal) &&
            (now - _lastAt).TotalMilliseconds < DedupeMilliseconds)
        {
            return;
        }

        _lastText = text;
        _lastAt = now;

        var context = _context;
        if (context is null)
        {
            Write(text);
            return;
        }

        try
        {
            _timer?.Dispose();
            _timer = new Timer(
                _ => context.Post(state => Write((string)state!), text),
                null,
                DelayMilliseconds,
                Timeout.Infinite);
        }
        catch
        {
            Write(text);
        }
    }

    private static void Write(string text)
    {
        try
        {
            var document = Application.DocumentManager.MdiActiveDocument;
            document?.Editor.WriteMessage("\n" + text);
        }
        catch
        {
            // 编辑器在命令切换间隙可能不可用，忽略。
        }
    }
}
