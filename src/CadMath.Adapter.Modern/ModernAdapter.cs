using CadMath.Adapters;

namespace CadMath.Adapter.Modern;

/// <summary>
/// AutoCAD 2025/2026 适配器。真正的拦截逻辑在 <c>src/CadMath.Adapter.Shared/KeystrokeAdapter.cs</c>，
/// 本程序集只负责声明自己是谁、以及引用哪一代 AutoCAD 托管程序集。
/// </summary>
public sealed class ModernAdapter : KeystrokeAdapter
{
    public const string AdapterId = "modern-r25";

    public ModernAdapter() : base(AdapterId)
    {
    }
}