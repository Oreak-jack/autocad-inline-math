using CadMath.Adapters;

namespace CadMath.Adapter.Legacy2024;

/// <summary>
/// AutoCAD 2024（R24.x）适配器：与 2025/2026 共用同一份拦截源码，
/// 但编译目标是 .NET Framework 4.8、引用的是 AutoCAD 2024 的托管程序集。
/// 2024 进程里没有 .NET 8 运行时，所以这一代必须单独出一个程序集。
/// </summary>
public sealed class Legacy2024Adapter : KeystrokeAdapter
{
    public const string AdapterId = "legacy-r24";

    public Legacy2024Adapter() : base(AdapterId)
    {
    }
}