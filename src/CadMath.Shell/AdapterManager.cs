using System.IO;
using System.Reflection;
#if NET
using System.Runtime.Loader;
#endif
using CadMath.Abstractions;
using CadMath.Core;

namespace CadMath.Shell;

/// <summary>
/// 适配器管理器：读清单 → 识别宿主 → 选适配器 → 装载并启动 → 出事时保护性关闭。
/// 它是 Shell 里唯一知道"有哪些适配器"的地方；真正的 CAD 接口细节都在适配器里。
/// </summary>
internal sealed class AdapterManager : IDisposable
{
    private const string ManifestFileName = "adapters.json";

    private readonly ILogSink _log;
    private readonly IAdapterHost _host;
#if NET
    private readonly List<AdapterLoadContext> _contexts = new();
#endif
    private readonly List<RejectedAdapter> _rejected = new();
    private readonly string _shellDirectory;

    private ICadAdapter? _adapter;
    private int _replacements;
    private bool _disposed;

#if !NET
    static AdapterManager()
    {
        AppDomain.CurrentDomain.AssemblyResolve += ResolveAdapterDependency;
    }
#endif

    public AdapterManager(ILogSink log)
    {
        _log = log;
        Feedback = new SwitchableFeedback(log, new CommandLineFeedback(log));
        _host = new AdapterHost(this, log);
        _shellDirectory = Path.GetDirectoryName(typeof(AdapterManager).Assembly.Location) is { Length: > 0 } dir
            ? dir
            : AppContext.BaseDirectory;
        Host = HostProbe.Detect();
    }

    /// <summary>拦截总开关。适配器每次处理按键都会读它。</summary>
    /// <summary>提示风格：AutoCAD = 与原生完全一致；Standard = 统一成现代提示（可加宽输入框）。</summary>
    public PromptStyle Style
    {
        get => _style;
        set
        {
            _style = value;
            _log.Write(LogLevel.Info, "prompt style=" + DescribeStyle(value));
        }
    }

    public static string DescribeStyle(PromptStyle style) =>
        style == PromptStyle.Standard ? "standard" : "autocad";

    private PromptStyle _style = PromptStyle.AutoCad;

    public bool Enabled { get; private set; } = true;

    public HostSeries Host { get; }

    /// <summary>给适配器的用户回显通道（0.5.0 起：输出 "= 结果"）。</summary>
    public SwitchableFeedback Feedback { get; }

    public AdapterManifest? Active { get; private set; }

    public IReadOnlyList<RejectedAdapter> Rejected => _rejected;

    public string? LastError { get; private set; }

    /// <summary>连续失败到第几次才保护性关闭。</summary>
    public const int FailureLimit = 3;

    private int _failureCount;

    public int Replacements => Volatile.Read(ref _replacements);

    public bool HasAdapter => _adapter is not null;

    public void Start()
    {
        _log.Write(LogLevel.Info, $"shell {ProductInfo.Version} start; host={Host}; dir={_shellDirectory}");

        AdapterManifestFile file;
        try
        {
            file = AdapterManifestReader.Parse(File.ReadAllText(Path.Combine(_shellDirectory, ManifestFileName)));
        }
        catch (ManifestException ex)
        {
            Fail($"清单无效（{ex.Code}）：{ex.Message}");
            return;
        }
        catch (Exception ex)
        {
            Fail("清单读取失败：" + ex.Message);
            return;
        }

        var selection = AdapterSelector.Select(file.Adapters, Host, AssemblyExists);
        _rejected.AddRange(selection.Rejected);

        if (!selection.HasCandidate)
        {
            Fail("没有可用的适配器。" + DescribeRejections());
            return;
        }

        foreach (var candidate in selection.Candidates)
        {
            if (TryActivate(candidate)) return;
        }

        Fail("所有候选适配器都启动失败。" + DescribeRejections());
    }

    public void Enable()
    {
        Enabled = true;
        Volatile.Write(ref _failureCount, 0);
        LastError = null;
        _log.Write(LogLevel.Info, "enabled");
    }

    public void Disable()
    {
        Enabled = false;
        _log.Write(LogLevel.Info, "disabled");
    }

    /// <summary>
    /// 适配器自身抛异常。0.5.0 起不再"一次就永久关闭"：
    /// 连续 <see cref="FailureLimit"/> 次才保护性关闭，中间那次只记日志并计数。
    /// 这样一次瞬时的编辑器状态变化不会把功能关到底，而真的每键必炸也只损失 3 次按键。
    /// </summary>
    internal void HandleAdapterFailure(Exception exception)
    {
        var count = Interlocked.Increment(ref _failureCount);
        LastError = exception.GetType().Name + ": " + exception.Message;
        _log.Write(LogLevel.Error, $"adapter failure #{count}: {exception}");
        if (count < FailureLimit) return;

        Enabled = false;
        _log.Write(LogLevel.Error, $"adapter failed {count} times in a row, interception disabled; CLMON 可恢复");
    }

    /// <summary>一次成功处理会把连败计数清零。</summary>
    internal void NoteSuccess()
    {
        if (Volatile.Read(ref _failureCount) == 0) return;
        Volatile.Write(ref _failureCount, 0);
    }

    public int Failures => Volatile.Read(ref _failureCount);

    /// <summary>热路径：只做判定与计数，绝不写文件。</summary>
    internal Conversion Evaluate(SubmitRequest request)
    {
        var conversion = InputTranslator.Translate(request.Text, request.Kind);
        if (conversion.Decision != Decision.Replace) return conversion;

        Interlocked.Increment(ref _replacements);
        LastError = null; // 改写成功说明链路是通的，别让 CLMSTATUS 一直显示旧错误。
        return conversion;
    }

    public string Describe()
    {
        var text = $"{ProductInfo.Name} {ProductInfo.Version} 开启={Enabled} 适配器={Active?.Id ?? "-"} 宿主={Host} 替换请求={Replacements} 回显={(Feedback.Enabled ? "开" : "关")} 连败={Failures} 风格={DescribeStyle(Style)} 最后错误={(string.IsNullOrEmpty(LastError) ? "-" : LastError)}";
        if (_rejected.Count > 0) text += DescribeRejections();
        text += "\n生效范围：仅底部命令行（动态输入无托管入口，不支持）";
        return text + "\n日志：" + LogFile.Path;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        try
        {
            _adapter?.Stop();
        }
        catch (Exception ex)
        {
            _log.Write(LogLevel.Error, "adapter stop failed: " + ex);
        }

        _adapter = null;
#if NET
        foreach (var context in _contexts)
        {
            try
            {
                context.Unload();
            }
            catch
            {
                // 卸载失败不影响进程退出。
            }
        }
        _contexts.Clear();
#endif
    }

    private void Fail(string message)
    {
        LastError = message;
        _log.Write(LogLevel.Error, message);
    }

    private string DescribeRejections() =>
        _rejected.Count == 0
            ? string.Empty
            : "\n被排除：" + string.Join("；", _rejected.Select(r => $"{r.Manifest.Id}={r.Reason}"));

    private void Reject(AdapterManifest manifest, string reason)
    {
        _rejected.Add(new RejectedAdapter(manifest, reason));
        _log.Write(LogLevel.Warn, $"rejected {manifest.Id}: {reason}");
    }

    private string ResolvePath(string relative) =>
        Path.IsPathRooted(relative) ? relative : Path.Combine(_shellDirectory, relative);

    private bool AssemblyExists(string relative)
    {
        var path = ResolvePath(relative);
        return File.Exists(path) && IsInsideShellDirectory(path);
    }

    private bool IsInsideShellDirectory(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetFullPath(_shellDirectory) + Path.DirectorySeparatorChar;
        return full.StartsWith(root, StringComparison.OrdinalIgnoreCase);
    }

    private bool TryActivate(AdapterManifest manifest)
    {
        var path = ResolvePath(manifest.Assembly);
        if (!File.Exists(path))
        {
            Reject(manifest, RejectionReasons.MissingAssembly);
            return false;
        }
        if (!IsInsideShellDirectory(path))
        {
            Reject(manifest, RejectionReasons.PathEscapes);
            return false;
        }

        Assembly assembly;
        try
        {
#if NET
            var context = new AdapterLoadContext(Path.GetDirectoryName(path)!);
            _contexts.Add(context);
            assembly = context.LoadFromAssemblyPath(path);
#else
            // .NET Framework 没有可卸载的 AssemblyLoadContext；同一 AppDomain 里
            // CadMath.Abstractions / CadMath.Core 本来就是 Shell 已加载的那一份，类型身份天然一致。
            assembly = Assembly.LoadFrom(path);
#endif
        }
        catch (Exception ex)
        {
            Reject(manifest, RejectionReasons.LoadFailed);
            _log.Write(LogLevel.Error, $"{manifest.Id} 程序集加载失败：{ex}");
            return false;
        }

        var type = assembly.GetType(manifest.Type, throwOnError: false);
        if (type is null || !typeof(ICadAdapter).IsAssignableFrom(type))
        {
            Reject(manifest, RejectionReasons.MissingType);
            _log.Write(LogLevel.Error, $"{manifest.Id} 找不到 ICadAdapter 实现：{manifest.Type}");
            return false;
        }

        ICadAdapter adapter;
        try
        {
            adapter = (ICadAdapter)Activator.CreateInstance(type)!;
        }
        catch (Exception ex)
        {
            Reject(manifest, RejectionReasons.LoadFailed);
            _log.Write(LogLevel.Error, $"{manifest.Id} 无法实例化：{ex}");
            return false;
        }

        if (!string.Equals(adapter.Id, manifest.Id, StringComparison.OrdinalIgnoreCase))
        {
            Reject(manifest, RejectionReasons.IdMismatch);
            _log.Write(LogLevel.Error, $"{manifest.Id} 的 Id 与清单不一致：{adapter.Id}");
            return false;
        }

        try
        {
            if (!adapter.TryStart(_host, CancellationToken.None, out var error))
            {
                Reject(manifest, RejectionReasons.StartFailed);
                _log.Write(LogLevel.Error, $"{manifest.Id} 启动被拒绝：{error}");
                return false;
            }
        }
        catch (Exception ex)
        {
            Reject(manifest, RejectionReasons.StartFailed);
            _log.Write(LogLevel.Error, $"{manifest.Id} 启动异常：{ex}");
            return false;
        }

        _adapter = adapter;
        Active = manifest;
        _log.Write(LogLevel.Info, $"adapter {manifest.Id} active");
        return true;
    }

    /// <summary>
    /// 适配器装载上下文：契约程序集必须与 Shell 共享同一份，否则
    /// <see cref="ICadAdapter"/> 会出现两个版本的类型，转换必然失败。
    /// </summary>
#if NET
    private sealed class AdapterLoadContext : AssemblyLoadContext
    {
        private static readonly Dictionary<string, Assembly> Shared = new(StringComparer.OrdinalIgnoreCase)
        {
            ["CadMath.Abstractions"] = typeof(ICadAdapter).Assembly,
            ["CadMath.Core"] = typeof(Conversion).Assembly
        };

        public AdapterLoadContext(string directory) : base($"CadMath adapter @ {directory}", isCollectible: true)
        {
        }

        protected override Assembly? Load(AssemblyName assemblyName)
        {
            if (assemblyName.Name is not null && Shared.TryGetValue(assemblyName.Name, out var shared))
            {
                return shared;
            }

            // 其余（acmgd/acdbmgd 等）交给宿主默认上下文。
            return null;
        }
    }
#else
    /// <summary>
    /// .NET Framework 用 AppDomain 解析：适配器目录里的程序集可能引用 Shell 目录下的
    /// CadMath.Abstractions / CadMath.Core，必须解析到已加载的那一份，否则类型身份会分裂。
    /// </summary>
    private static Assembly? ResolveAdapterDependency(object sender, ResolveEventArgs args)
    {
        var name = new AssemblyName(args.Name).Name;
        if (string.Equals(name, "CadMath.Abstractions", StringComparison.OrdinalIgnoreCase)) return typeof(ICadAdapter).Assembly;
        if (string.Equals(name, "CadMath.Core", StringComparison.OrdinalIgnoreCase)) return typeof(Conversion).Assembly;
        return null;
    }
#endif
}
