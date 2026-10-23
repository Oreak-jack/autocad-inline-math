using System.Text.Json;
using System.Text.Json.Serialization;

namespace CadMath.Abstractions;

/// <summary>
/// 清单里的一个适配器条目，对应 <c>adapters.json</c> 的 <c>adapters[]</c> 元素。
/// 这是"选谁"的唯一依据；适配器自身不参与选择。
/// </summary>
public sealed class AdapterManifest
{
    [JsonPropertyName("id")] public string Id { get; set; } = string.Empty;

    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = string.Empty;

    /// <summary>相对 Shell 所在目录的程序集文件名。</summary>
    [JsonPropertyName("assembly")] public string Assembly { get; set; } = string.Empty;

    /// <summary>完整类型名，必须实现 <see cref="ICadAdapter"/>。</summary>
    [JsonPropertyName("type")] public string Type { get; set; } = string.Empty;

    /// <summary>支持的宿主序列，如 <c>["R25.0","R25.1"]</c>。</summary>
    [JsonPropertyName("series")] public string[] Series { get; set; } = Array.Empty<string>();

    /// <summary>数字越大越先尝试。</summary>
    [JsonPropertyName("priority")] public int Priority { get; set; }

    /// <summary>是否经过真机验证。只用于诊断显示，不参与选择。</summary>
    [JsonPropertyName("verified")] public bool Verified { get; set; }

    /// <summary>适配器编译目标，仅用于诊断。</summary>
    [JsonPropertyName("runtime")] public string? Runtime { get; set; }

    public bool Supports(HostSeries host) =>
        Series.Any(s => string.Equals(s?.Trim(), host.ToString(), StringComparison.OrdinalIgnoreCase));

    public override string ToString() => string.IsNullOrEmpty(DisplayName) ? Id : $"{Id} ({DisplayName})";
}

/// <summary><c>adapters.json</c> 的根对象。</summary>
public sealed class AdapterManifestFile
{
    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; } = 1;

    [JsonPropertyName("adapters")] public AdapterManifest[] Adapters { get; set; } = Array.Empty<AdapterManifest>();
}

/// <summary>清单无效。宁可整份拒绝，也不要半懂地加载。</summary>
public sealed class ManifestException : Exception
{
    public ManifestException(string code, string message) : base(message) => Code = code;

    public string Code { get; }
}

/// <summary>清单解析与校验。只做文本 → 模型，不碰文件系统。</summary>
public static class AdapterManifestReader
{
    public const int SupportedSchemaVersion = 1;

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    /// <summary>解析并校验清单文本。</summary>
    public static AdapterManifestFile Parse(string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            throw new ManifestException("empty", "适配器清单为空。");
        }

        AdapterManifestFile? file;
        try
        {
            file = JsonSerializer.Deserialize<AdapterManifestFile>(json, Options);
        }
        catch (JsonException ex)
        {
            throw new ManifestException("malformed-json", "适配器清单不是合法 JSON：" + ex.Message);
        }

        if (file is null || file.Adapters.Length == 0)
        {
            throw new ManifestException("empty", "适配器清单里没有任何适配器。");
        }
        if (file.SchemaVersion != SupportedSchemaVersion)
        {
            throw new ManifestException(
                "unsupported-schema",
                $"不支持的清单版本 {file.SchemaVersion}，本版本只认 {SupportedSchemaVersion}。");
        }

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var adapter in file.Adapters)
        {
            if (string.IsNullOrWhiteSpace(adapter.Id))
            {
                throw new ManifestException("missing-id", "适配器缺少 id。");
            }
            if (!seen.Add(adapter.Id))
            {
                throw new ManifestException("duplicate-id", $"适配器 id 重复：{adapter.Id}。");
            }
            if (string.IsNullOrWhiteSpace(adapter.Assembly) || string.IsNullOrWhiteSpace(adapter.Type))
            {
                throw new ManifestException("missing-assembly", $"适配器 {adapter.Id} 缺少 assembly 或 type。");
            }
            if (adapter.Series.Length == 0)
            {
                throw new ManifestException("missing-series", $"适配器 {adapter.Id} 没有声明支持的 series。");
            }
            foreach (var series in adapter.Series)
            {
                if (!HostSeries.TryParse(series, out _))
                {
                    throw new ManifestException("bad-series", $"适配器 {adapter.Id} 的 series 无法解析：{series}。");
                }
            }
        }

        return file;
    }
}
