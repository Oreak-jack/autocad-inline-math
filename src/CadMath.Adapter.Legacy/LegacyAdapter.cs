using CadMath.Abstractions;

namespace CadMath.Adapter.Legacy;

/// <summary>
/// AutoCAD 2024 及更早版本的适配器占位。
/// 契约已经就位，但真实拦截需要针对 2024 的输入 API 单独构建（引用 24.x 的 acmgd）。
/// 在接入之前，它只如实报告"未实现"，宿主会提示用户而不是静默失效。
/// </summary>
public sealed class LegacyAdapter : ICadAdapter
{
    public string Id => "legacy-r24";

    public bool TryStart(IAdapterHost host, CancellationToken cancellationToken, out string? error)
    {
        error = "AutoCAD 2024 适配器尚未实现：需要引用 24.x 版 acmgd 构建后接入。";
        return false;
    }

    public void Stop()
    {
    }
}
