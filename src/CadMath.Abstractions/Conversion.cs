namespace CadMath.Abstractions;

/// <summary>对一次用户提交（回车/空格）的处理结论。</summary>
public enum Decision
{
    /// <summary>保持原样，交给 AutoCAD 原生处理。</summary>
    Pass,

    /// <summary>用 <see cref="Conversion.Value"/> 替换输入缓冲区后，让原按键继续。</summary>
    Replace,

    /// <summary>拦下这次提交并提示用户，不产生任何几何。</summary>
    Reject
}

/// <summary>
/// 判定结果。<see cref="Message"/> 只用于日志与诊断，不直接拼进 CAD 命令行。
/// </summary>
public readonly record struct Conversion(Decision Decision, string Value, string? Code, string? Message)
{
    public static Conversion Pass(string original) => new(Decision.Pass, original, null, null);

    public static Conversion Replace(string value) => new(Decision.Replace, value, null, null);

    public static Conversion Reject(string original, string code, string message) =>
        new(Decision.Reject, original, code, message);

    /// <summary>
    /// 回显用的短文本：坐标类（含逗号）折成 <c>(15, 40)</c>，角度类保持 <c>70&lt;45</c>，
    /// 其余原样。只影响显示，不影响真正写回输入队列的值。
    /// </summary>
    public static string FormatForEcho(string? value)
    {
        return string.IsNullOrEmpty(value) ? string.Empty : value!.Replace(",", ", ");
    }
}
