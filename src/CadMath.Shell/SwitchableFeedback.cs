using CadMath.Abstractions;

namespace CadMath.Shell;

/// <summary>
/// 0.5.0：CM3ECHO 用。包一层真正的回显实现，按配置决定是否转出去。
/// 关闭时只写日志，不往命令行插字。
/// </summary>
internal sealed class SwitchableFeedback : IUserFeedback
{
    private readonly ILogSink _log;
    private readonly IUserFeedback _inner;
    private int _enabled;

    public SwitchableFeedback(ILogSink log, IUserFeedback inner)
    {
        _log = log;
        _inner = inner;
        _enabled = 1;
    }

    public bool Enabled
    {
        get => Volatile.Read(ref _enabled) != 0;
        set
        {
            Volatile.Write(ref _enabled, value ? 1 : 0);
            _log.Write(LogLevel.Info, "echo " + (value ? "on" : "off"));
        }
    }

    public void OnReplaced(string original, string value)
    {
        if (Enabled) _inner.OnReplaced(original, value);
    }

    public void OnRejected(string original, string code, string message)
    {
        if (Enabled) _inner.OnRejected(original, code, message);
    }
}
