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

    /// <summary>诊断用：把关键宿主模块的名字与版本拼成一行（缺哪个就直接写 missing）。</summary>
    public static string DescribeModules()
    {
        var names = new[] { "acad.exe", "acmgd.dll", "accoremgd.dll", "acdbmgd.dll" };
        var parts = new List<string>();

        try
        {
            foreach (var name in names)
            {
                ProcessModule? found = null;
                foreach (ProcessModule module in Process.GetCurrentProcess().Modules)
                {
                    if (!string.Equals(module.ModuleName, name, StringComparison.OrdinalIgnoreCase)) continue;
                    found = module;
                    break;
                }

                if (found is null) parts.Add(name + "=missing");
                else parts.Add(name + "=" + (found.FileVersionInfo?.FileVersion ?? "?"));
            }
        }
        catch (Exception ex)
        {
            parts.Add("modules=<" + ex.GetType().Name + ">");
        }

        return string.Join("; ", parts);
    }
}
