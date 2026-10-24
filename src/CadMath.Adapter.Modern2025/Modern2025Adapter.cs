using CadMath.Adapters;

namespace CadMath.Adapter.Modern2025;

/// <summary>
/// AutoCAD 2025（R25.0）适配器：与 2026 共用同一份拦截源码，
/// 但编译时引用的是 2025 的 SDK（25.0.1），只用到 2025 就有的 API。
/// </summary>
public sealed class Modern2025Adapter : KeystrokeAdapter
{
    public const string AdapterId = "modern-r25";

    public Modern2025Adapter() : base(AdapterId)
    {
    }
}
