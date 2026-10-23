namespace CadMath.Abstractions;

/// <summary>
/// 清单里的一个适配器条目，对应 <c>adapters.json</c> 的 <c>adapters[]</c> 元素。
/// 这是"选谁"的唯一依据；适配器自身不参与选择。
/// </summary>
public sealed class AdapterManifest
{
    public string Id { get; set; } = string.Empty;

    public string DisplayName { get; set; } = string.Empty;

    /// <summary>相对 Shell 所在目录的程序集文件名。</summary>
    public string Assembly { get; set; } = string.Empty;

    /// <summary>完整类型名，必须实现 <see cref="ICadAdapter"/>。</summary>
    public string Type { get; set; } = string.Empty;

    /// <summary>支持的宿主序列，如 <c>["R25.0","R25.1"]</c>。</summary>
    public string[] Series { get; set; } = Array.Empty<string>();

    /// <summary>数字越大越先尝试。</summary>
    public int Priority { get; set; }

    /// <summary>是否经过真机验证。只用于诊断显示，不参与选择。</summary>
    public bool Verified { get; set; }

    /// <summary>适配器编译目标，仅用于诊断。</summary>
    public string? Runtime { get; set; }

    /// <summary>发行侧状态（planned/built/automated-tested/host-tested/released/disabled），仅诊断用。</summary>
    public string? Status { get; set; }

    public bool Supports(HostSeries host) =>
        Series.Any(s => string.Equals(s?.Trim(), host.ToString(), StringComparison.OrdinalIgnoreCase));

    public override string ToString() => string.IsNullOrEmpty(DisplayName) ? Id : $"{Id} ({DisplayName})";
}

/// <summary><c>adapters.json</c> 的根对象。</summary>
public sealed class AdapterManifestFile
{
    public int SchemaVersion { get; set; } = 1;

    public AdapterManifest[] Adapters { get; set; } = Array.Empty<AdapterManifest>();
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

    /// <summary>解析并校验清单文本。</summary>
    public static AdapterManifestFile Parse(string json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            throw new ManifestException("empty", "适配器清单为空。");
        }

        Dictionary<string, object?>? root;
        try
        {
            root = Json.AsObject(Json.Parse(json));
        }
        catch (Json.JsonFormatException ex)
        {
            throw new ManifestException("malformed-json", "适配器清单不是合法 JSON：" + ex.Message);
        }

        if (root is null)
        {
            throw new ManifestException("malformed-json", "适配器清单的根必须是对象。");
        }

        var schemaVersion = Json.GetInt(root, "schemaVersion") ?? 1;
        var adaptersJson = Json.GetArray(root, "adapters");
        if (adaptersJson is null || adaptersJson.Count == 0)
        {
            throw new ManifestException("empty", "适配器清单里没有任何适配器。");
        }

        if (schemaVersion != SupportedSchemaVersion)
        {
            throw new ManifestException(
                "unsupported-schema",
                $"不支持的清单版本 {schemaVersion}，本版本只认 {SupportedSchemaVersion}。");
        }

        var adapters = new List<AdapterManifest>(adaptersJson.Count);
        foreach (var item in adaptersJson)
        {
            var entry = Json.AsObject(item);
            if (entry is null)
            {
                throw new ManifestException("malformed-json", "adapters[] 里的元素必须是对象。");
            }

            var series = new List<string>();
            var seriesJson = Json.GetArray(entry, "series");
            if (seriesJson is not null)
            {
                foreach (var value in seriesJson)
                {
                    if (value is string text) series.Add(text);
                }
            }

            adapters.Add(new AdapterManifest
            {
                Id = Json.GetString(entry, "id") ?? string.Empty,
                DisplayName = Json.GetString(entry, "displayName") ?? string.Empty,
                Assembly = Json.GetString(entry, "assembly") ?? string.Empty,
                Type = Json.GetString(entry, "type") ?? string.Empty,
                Series = series.ToArray(),
                Priority = Json.GetInt(entry, "priority") ?? 0,
                Verified = Json.GetBool(entry, "verified") ?? false,
                Runtime = Json.GetString(entry, "runtime"),
                Status = Json.GetString(entry, "status")
            });
        }

        foreach (var adapter in adapters)
        {
            if (string.IsNullOrWhiteSpace(adapter.Id))
            {
                throw new ManifestException("missing-id", "适配器缺少 id。");
            }

            if (adapters.Count(a => string.Equals(a.Id, adapter.Id, StringComparison.OrdinalIgnoreCase)) > 1)
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

        return new AdapterManifestFile { SchemaVersion = schemaVersion, Adapters = adapters.ToArray() };
    }
}
