namespace CadMath.Abstractions;

/// <summary>候选被排除的原因。写进 <c>CM3STATUS</c>，让"为什么没用这个适配器"可查。</summary>
public static class RejectionReasons
{
    public const string SeriesMismatch = "series-mismatch";
    public const string MissingAssembly = "missing-assembly";
    public const string PathEscapes = "path-escapes";
    public const string LoadFailed = "load-failed";
    public const string MissingType = "missing-type";
    public const string IdMismatch = "id-mismatch";
    public const string StartFailed = "start-failed";
}

/// <summary>被排除的适配器及原因。</summary>
public sealed record RejectedAdapter(AdapterManifest Manifest, string Reason);

/// <summary>选择结果：按优先级排序的候选，以及被排除的条目。</summary>
public sealed record SelectionResult(
    IReadOnlyList<AdapterManifest> Candidates,
    IReadOnlyList<RejectedAdapter> Rejected)
{
    public bool HasCandidate => Candidates.Count > 0;
}

/// <summary>
/// 纯选择逻辑：宿主版本决定"能用谁"，优先级决定"先试谁"。
/// 不读文件、不加载程序集——文件存在性由调用方以委托注入，因此可脱机单测。
/// </summary>
public static class AdapterSelector
{
    public static SelectionResult Select(
        IEnumerable<AdapterManifest> manifests,
        HostSeries host,
        Func<string, bool> assemblyExists)
    {
        if (manifests is null) throw new ArgumentNullException(nameof(manifests));
        if (assemblyExists is null) throw new ArgumentNullException(nameof(assemblyExists));

        var candidates = new List<AdapterManifest>();
        var rejected = new List<RejectedAdapter>();

        foreach (var manifest in manifests)
        {
            if (!manifest.Supports(host))
            {
                rejected.Add(new RejectedAdapter(manifest, RejectionReasons.SeriesMismatch));
                continue;
            }
            if (!assemblyExists(manifest.Assembly))
            {
                rejected.Add(new RejectedAdapter(manifest, RejectionReasons.MissingAssembly));
                continue;
            }
            candidates.Add(manifest);
        }

        candidates.Sort(static (left, right) =>
        {
            var byPriority = right.Priority.CompareTo(left.Priority);
            return byPriority != 0 ? byPriority : string.CompareOrdinal(left.Id, right.Id);
        });

        return new SelectionResult(candidates, rejected);
    }
}
