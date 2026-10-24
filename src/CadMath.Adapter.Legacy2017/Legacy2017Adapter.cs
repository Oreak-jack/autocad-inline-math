using CadMath.Adapters;

namespace CadMath.Adapter.Legacy2017;

/// <summary>
/// AutoCAD 2017（R21.0） 适配器：与其它代共用同一份拦截源码，
/// 只有编译时引用的 AutoCAD 托管程序集（21.0.2）不同。
/// </summary>
public sealed class Legacy2017Adapter : KeystrokeAdapter
{
    public const string AdapterId = "legacy-r21";

    public Legacy2017Adapter() : base(AdapterId)
    {
    }
}