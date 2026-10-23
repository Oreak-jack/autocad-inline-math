namespace CadMath.Abstractions;

/// <summary>
/// AutoCAD 版本序列标识。用 <c>acmgd.dll</c> 的主次版本表示：
/// 2025 → <c>R25.0</c>，2026 → <c>R25.1</c>。年份不参与匹配，避免"2025.1"这种写法歧义。
/// </summary>
public readonly record struct HostSeries(int Major, int Minor)
{
    public override string ToString() => $"R{Major}.{Minor}";

    /// <summary>解析 <c>R25.1</c>（大小写不敏感）。</summary>
    public static bool TryParse(string? value, out HostSeries series)
    {
        series = default;
        if (string.IsNullOrWhiteSpace(value)) return false;

        var text = value.Trim();
        if (text.StartsWith("R", StringComparison.OrdinalIgnoreCase)) text = text.Substring(1);

        var dot = text.IndexOf('.');
        if (dot <= 0) return false;

        if (!int.TryParse(text.Substring(0, dot), out var major) || major <= 0) return false;
        if (!int.TryParse(text.Substring(dot + 1), out var minor) || minor < 0) return false;

        series = new HostSeries(major, minor);
        return true;
    }

    /// <summary>从 <c>25.1.60.0</c> 这类文件版本字符串提取主次版本。</summary>
    public static HostSeries FromFileVersion(string? fileVersion)
    {
        if (string.IsNullOrWhiteSpace(fileVersion)) return default;

        var parts = fileVersion.Trim().Split('.');
        var major = parts.Length > 0 && int.TryParse(parts[0], out var a) ? a : 0;
        var minor = parts.Length > 1 && int.TryParse(parts[1], out var b) ? b : 0;
        return new HostSeries(major, minor);
    }

    public static HostSeries FromVersion(Version? version) =>
        version is null ? default : new HostSeries(version.Major, version.Minor);

    public bool IsKnown => Major > 0;
}
