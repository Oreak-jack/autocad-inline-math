namespace CadMath.Abstractions;

/// <summary>
/// 当前提示需要的值类型。由适配器从 AutoCAD 的 PromptingFor* 事件翻译而来，
/// Core 只根据它决定坐标/整数这类约束，不关心提示来自哪个命令。
/// </summary>
public enum PromptKind
{
    /// <summary>无法归类，按普通标量处理。</summary>
    Other = 0,

    /// <summary>点输入：支持 <c>x,y[,z]</c> 与 <c>距离&lt;角度</c>，可带 <c>@</c> / <c>#</c> 前缀。</summary>
    Point,

    Distance,
    Double,
    Angle,

    /// <summary>整数输入：结果必须是 32 位整数。</summary>
    Integer
}
