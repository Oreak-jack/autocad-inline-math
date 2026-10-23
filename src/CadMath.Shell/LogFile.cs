using System.IO;
using System.Text;
using CadMath.Abstractions;

namespace CadMath.Shell;

/// <summary>
/// 落盘日志：<c>%TEMP%\CadMath03.log</c>，超过 1 MB 停止追加（与 v0.3.3 一致）。
/// 所有写入都吞异常——日志坏了也不能让插件停摆。
/// </summary>
internal static class LogFile
{
    private const long MaxBytes = 1_048_576;

    private static readonly object Gate = new();

    public static readonly string Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "CadMath03.log");

    public static void Write(LogLevel level, string message)
    {
        try
        {
            lock (Gate)
            {
                var file = new FileInfo(Path);
                if (file.Exists && file.Length > MaxBytes) return;

                var line = new StringBuilder(96)
                    .Append(DateTime.Now.ToString("O"))
                    .Append(' ')
                    .Append(level switch
                    {
                        LogLevel.Debug => "DEBUG",
                        LogLevel.Info => "INFO ",
                        LogLevel.Warn => "WARN ",
                        _ => "ERROR"
                    })
                    .Append(' ')
                    .Append(message)
                    .AppendLine()
                    .ToString();

                File.AppendAllText(Path, line);
            }
        }
        catch
        {
            // 日志不可写不是故障。
        }
    }

    /// <summary>给 Manager 用的接口实现。</summary>
    internal sealed class Sink : ILogSink
    {
        public void Write(LogLevel level, string message) => LogFile.Write(level, message);
    }
}
