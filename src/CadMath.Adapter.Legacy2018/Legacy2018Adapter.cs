using CadMath.Adapters;

namespace CadMath.Adapter.Legacy2018;

/// <summary>
/// AutoCAD 2018（R22.0） 适配器：与其它代共用同一份拦截源码，
/// 只有编译时引用的 AutoCAD 托管程序集（22.0.0）不同。
/// </summary>
public sealed class Legacy2018Adapter : KeystrokeAdapter
{
    public const string AdapterId = "legacy-r22";

    public Legacy2018Adapter() : base(AdapterId)
    {
    }
}