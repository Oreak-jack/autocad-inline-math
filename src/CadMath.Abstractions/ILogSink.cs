namespace CadMath.Abstractions;

/// <summary>日志级别。落盘策略由 Shell 决定，适配器只描述事实。</summary>
public enum LogLevel
{
    Debug = 0,
    Info,
    Warn,
    Error
}

/// <summary>日志落点。实现必须吞掉自身异常，不能因为写日志让插件停摆。</summary>
public interface ILogSink
{
    void Write(LogLevel level, string message);
}
