namespace CadMath.Core;

/// <summary>数值格式化：去掉多余尾零，永远用 <c>.</c> 作小数点，不受系统区域设置影响。</summary>
public static class NumberFormat
{
    /// <summary>把 <paramref name="value"/> 格式化成 AutoCAD 能接受的十进制文本。</summary>
    public static string Format(double value) => value.ToString("0.################", System.Globalization.CultureInfo.InvariantCulture);
}
