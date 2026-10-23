using CadMath.Adapters;

namespace CadMath.Adapter.Legacy2020;

/// <summary>
/// AutoCAD 2020（R23.1）适配器：与 2024 共用同一份拦截源码，
/// 但编译时引用的是 AutoCAD 2020 的托管程序集（23.1.0）。
/// 官方兼容表里 2020 只接受 23.x 编出来的程序集，所以这一代必须单独出一个程序集。
/// </summary>
public sealed class Legacy2020Adapter : KeystrokeAdapter
{
    public const string AdapterId = "legacy-r23";

    public Legacy2020Adapter() : base(AdapterId)
    {
    }
}
