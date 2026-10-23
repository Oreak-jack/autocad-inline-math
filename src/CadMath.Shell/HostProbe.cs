using System.Diagnostics;
using CadMath.Abstractions;

namespace CadMath.Shell;

/// <summary>
/// 识别当前宿主序列。以 <c>acmgd.dll</c> 的文件版本为准（2025 → 25.0，2026 → 25.1），
/// 因为程序集版本在各年度版之间可能保持不变，只有文件版本可靠。
/// 可用环境变量 <c>CADMATH_HOST_SERIES</c> 强制覆盖（排障与预演用）。
/// </summary>
internal static class HostProbe
{
    public const string OverrideVariable = "CADMATH_HOST_SERIES";

    public static HostSeries Detect()
    {
        var overridden = Environment.GetEnvironmentVariable(OverrideVariable);
        if (HostSeries.TryParse(overridden, out var forced)) return forced;

        try
        {
            foreach (ProcessModule module in Process.GetCurrentProcess().Modules)
            {
                if (!string.Equals(module.ModuleName, "acmgd.dll", StringComparison.OrdinalIgnoreCase)) continue;

                var series = HostSeries.FromFileVersion(module.FileVersionInfo?.FileVersion);
                if (series.IsKnown) return series;
            }
        }
        catch
        {
            // 枚举模块失败时退回程序集版本。
        }

        return HostSeries.FromVersion(typeof(Autodesk.AutoCAD.ApplicationServices.Application).Assembly.GetName().Version);
    }
}
