namespace CadMath.Core;

/// <summary>
/// .NET Framework / netstandard2.0 缺少的几个小工具：char.IsAsciiDigit、double.IsFinite。
/// 行为与 .NET 8 的实现一致（IsFinite 等价于 !IsNaN &amp;&amp; !IsInfinity）。
/// </summary>
internal static class Ascii
{
    public static bool IsDigit(char c) => c >= '0' && c <= '9';

    public static bool IsFinite(double value) => !double.IsNaN(value) && !double.IsInfinity(value);
}