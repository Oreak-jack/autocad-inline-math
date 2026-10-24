using CadMath.Adapters;

namespace CadMath.Adapter.Legacy2015;

/// <summary>
/// AutoCAD 2015–2016（R20.0–R20.1） 适配器：与其它代共用同一份拦截源码，
/// 只有编译时引用的 AutoCAD 托管程序集（20.1.0）不同。
/// </summary>
public sealed class Legacy2015Adapter : KeystrokeAdapter
{
    public const string AdapterId = "legacy-r20";

    public Legacy2015Adapter() : base(AdapterId)
    {
    }
}