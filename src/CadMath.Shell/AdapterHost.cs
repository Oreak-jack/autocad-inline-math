using CadMath.Abstractions;
using CadMath.Core;

namespace CadMath.Shell;

/// <summary>Manager 暴露给适配器的最小能力集。</summary>
internal sealed class AdapterHost : IAdapterHost
{
    private readonly AdapterManager _manager;
    private readonly ILogSink _log;

    public AdapterHost(AdapterManager manager, ILogSink log)
    {
        _manager = manager;
        _log = log;
    }

    public bool Enabled => _manager.Enabled;

    public Conversion Evaluate(SubmitRequest request) => _manager.Evaluate(request);

    public void Report(LogLevel level, string message) => _log.Write(level, message);

    public void OnFailure(Exception exception) => _manager.HandleAdapterFailure(exception);
}
