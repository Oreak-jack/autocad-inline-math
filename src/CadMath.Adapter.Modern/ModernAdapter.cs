using CadMath.Adapters;

namespace CadMath.Adapter.Modern;

/// <summary>
/// AutoCAD 2026（R25.1）适配器。真正的拦截逻辑在 <c>src/CadMath.Adapter.Shared/KeystrokeAdapter.cs</c>，
/// 本程序集只负责声明自己是谁、以及引用哪一代 AutoCAD 托管程序集。
/// 2025（R25.0）见 <c>src/CadMath.Adapter.Modern2025</c>：同一份源码，但用 2025 的 SDK 编译。
/// </summary>
public sealed class ModernAdapter : KeystrokeAdapter
{
    public const string AdapterId = "modern-r26";

    public ModernAdapter() : base(AdapterId)
    {
    }
}