namespace CadMath.Abstractions;

/// <summary>
/// 输入提示的呈现口径。
/// <para>
/// <see cref="AutoCad"/> 完全跟随 AutoCAD 自己的提示与输入框；<see cref="Standard"/>
/// 让各版本都套同一套体验（0.5.0 先把开关与链路铺好，具体呈现由适配器逐步接管）。
/// </para>
/// </summary>
public enum PromptStyle
{
    /// <summary>与 AutoCAD 原生保持一致（默认）。</summary>
    AutoCad = 0,

    /// <summary>统一的标准样式。</summary>
    Standard = 1,
}