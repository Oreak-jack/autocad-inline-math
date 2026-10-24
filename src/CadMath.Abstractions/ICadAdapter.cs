
namespace CadMath.Abstractions;

/// <summary>用户按下回车/空格时，适配器交给宿主的一条记录。</summary>
/// <param name="Kind">当前提示需要的值类型。</param>
/// <param name="Command">正在执行的命令名（去掉 <c>_</c> / <c>.</c> 前缀）。</param>
/// <param name="Text">命令输入缓冲区里的原始文本。</param>
public sealed record SubmitRequest(PromptKind Kind, string Command, string Text);

/// <summary>
/// 适配器能看到的宿主能力。适配器不知道数学怎么算、日志写到哪里，只负责转手。
/// </summary>
public interface IAdapterHost
{
    /// <summary>是否启用拦截。为 <c>false</c> 时适配器必须立即放行。</summary>
    bool Enabled { get; }

    /// <summary>把一次提交交给 Core 判定。必须同步返回。</summary>
    Conversion Evaluate(SubmitRequest request);

    /// <summary>记录一条事实。</summary>
    void Report(LogLevel level, string message);

    /// <summary>
    /// 给用户的即时回显（可选）。宿主永远给一个非 <c>null</c> 的实现，
    /// 至于要不要真的显示，由宿主按配置决定。
    /// </summary>
    IUserFeedback Feedback { get; }

    /// <summary>适配器自身出错（通常意味着 API 契约变了）。宿主负责计数，连败到阈值才保护性关闭。</summary>
    void OnFailure(Exception exception);

    /// <summary>一次按键被成功处理（放行/改写/拒绝都算）。宿主用它清零连败计数。</summary>
    void NoteSuccess();
}

/// <summary>
/// 一个版本适配器：把某个 AutoCAD 大版本的输入/提示事件翻译成 <see cref="SubmitRequest"/>，
/// 并按判定结果改写命令输入缓冲区。
/// </summary>
/// <remarks>
/// 线程契约：<see cref="TryStart"/> 与所有回调都在 AutoCAD 主线程执行；
/// 拦截回调每秒可能被调用数百次，实现里不得做文件 I/O。
/// </remarks>
public interface ICadAdapter
{
    /// <summary>稳定标识，必须与清单里的 <c>id</c> 一致。</summary>
    string Id { get; }

    /// <summary>开始拦截。返回 <c>false</c> 时不得留下任何订阅。</summary>
    bool TryStart(IAdapterHost host, CancellationToken cancellationToken, out string? error);

    /// <summary>停止拦截并释放所有订阅。可重复调用。</summary>
    void Stop();
}
