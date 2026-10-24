using System;
using System.Collections.Generic;
using System.Reflection;
using System.Threading;
using System.Runtime.InteropServices;
using System.Windows.Controls;
using System.Windows.Input;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Windows;
using CadMath.Abstractions;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;
using Window = Autodesk.AutoCAD.Windows.Window;

namespace CadMath.Adapters;

/// <summary>
/// 键盘拦截适配器的公共实现：2025/2026（net8）与 2024 及更早（net48）共用同一份源码，
/// 只有编译引用不同。逻辑是 v0.3.3 里 Plugin 的拦截部分逐行搬过来的：
/// 宿主版本差异、策略、格式化全部在本程序集之外，这里只负责"什么时候拦、拦到什么都交出去、怎么把结果写回输入队列"。
/// </summary>
public abstract class KeystrokeAdapter : ICadAdapter
{
    /// <summary>
    /// 0.5.0 起不再靠这份白名单放行：命令态取自 AutoCAD 自己的 CMDNAMES 系统变量
    /// （`'` 分隔的嵌套命令名），任何需要距离/角度的命令都能用。
    /// 这份清单只在读不到 CMDNAMES 时才作为兜底判据。
    /// </summary>
    private static readonly HashSet<string> FallbackAllowedCommands = new(StringComparer.OrdinalIgnoreCase)
    {
        "LINE", "PLINE", "CIRCLE", "ARC", "RECTANG", "OFFSET", "MOVE", "COPY", "ROTATE", "SCALE",
        "STRETCH", "FILLET", "CHAMFER", "POLYGON", "ELLIPSE", "LENGTHEN"
    };

    private readonly string _id;
    private IAdapterHost _host = null!;
    private bool _started;
    private bool _inHandler;

    /// <summary>
    /// 一次按键会先来 WM_KEYDOWN(0x100)、再来 WM_CHAR(0x102)。如果 KeyDown 已经改写/拒绝过，
    /// 紧随其后的 WM_CHAR 必须跳过：此时输入队列还是旧文本（改写要到消息循环才生效），
    /// 否则同一次回车会改写两遍、计数也加两次。
    /// 每个新的 KeyDown 都会先把标记清掉，所以它绝不会跨按键残留。
    /// </summary>
    private long _consumedKeyDownKey = -1;
    private Document? _contextDocument;
    private PromptKind _contextKind;
    private string _contextCommand = string.Empty;
    private readonly Dictionary<Document, PromptHooks> _hooks = new();

    protected KeystrokeAdapter(string id) => _id = id;

    public string Id => _id;

    public bool TryStart(IAdapterHost host, CancellationToken cancellationToken, out string? error)
    {
        _host = host;
        error = null;

        try
        {
            DisableFormerPlugins();

            foreach (Document document in AcApp.DocumentManager) Attach(document);
            AcApp.DocumentManager.DocumentCreated += OnDocumentCreated;
            AcApp.DocumentManager.DocumentToBeDestroyed += OnDocumentDestroyed;
            AcApp.DocumentManager.DocumentActivated += OnDocumentActivated;
            AcApp.EnterModal += OnModal;
            AcApp.PreTranslateMessage += OnPreTranslateMessage;

            _started = true;
            return true;
        }
        catch (Exception ex)
        {
            error = ex.ToString();
            Stop();
            return false;
        }
    }

    public void Stop()
    {
        if (!_started) return;
        _started = false;

        AcApp.PreTranslateMessage -= OnPreTranslateMessage;
        AcApp.EnterModal -= OnModal;
        AcApp.DocumentManager.DocumentCreated -= OnDocumentCreated;
        AcApp.DocumentManager.DocumentToBeDestroyed -= OnDocumentDestroyed;
        AcApp.DocumentManager.DocumentActivated -= OnDocumentActivated;

        foreach (var hooks in _hooks.Values) hooks.Dispose();
        _hooks.Clear();
        ClearContext();
    }

    /// <summary>
    /// 只关闭我们自己早期发布过的插件（CadMath / CadMathNative）。
    /// 不改任何 CAD 设置，不猜别人的插件。
    /// </summary>
    private static void DisableFormerPlugins()
    {
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            var name = assembly.GetName().Name;
            if (name is not ("CadMath" or "CadMathNative")) continue;

            var type = assembly.GetType(name == "CadMath" ? "CadMath.Plugin" : "CadMathNative.NativePlugin");
            try
            {
                type?.GetMethod("Off", BindingFlags.Public | BindingFlags.Static)?.Invoke(null, null);
            }
            catch
            {
                // 旧版关闭失败不影响新版。
            }
        }
    }

    private void Attach(Document document)
    {
        if (!_hooks.ContainsKey(document)) _hooks[document] = new PromptHooks(document, this);
    }

    private void OnDocumentCreated(object sender, DocumentCollectionEventArgs e) => Attach(e.Document);

    private void OnDocumentDestroyed(object sender, DocumentCollectionEventArgs e)
    {
        ClearContext();
        if (_hooks.TryGetValue(e.Document, out var hooks))
        {
            _hooks.Remove(e.Document);
            hooks.Dispose();
        }
    }

    private void OnDocumentActivated(object sender, DocumentCollectionEventArgs e) => ClearContext();

    private void OnModal(object? sender, EventArgs e) => ClearContext();

    private void ClearContext()
    {
        _contextDocument = null;
        _contextKind = PromptKind.Other;
        _contextCommand = string.Empty;
    }

    /// <summary>
    /// 记住"这次按键已经消费掉了"，让紧随其后的 WM_CHAR 不要重复处理。
    /// 只有 WM_KEYDOWN 才需要这样标记：WM_CHAR 本身就是兜底路径。
    /// </summary>
    private void NoteKeystrokeConsumed(int messageId, long key) =>
        _consumedKeyDownKey = messageId == 0x100 ? key : -1;

    private static string CommandOf(Document document) => document.CommandInProgress.TrimStart('_', '.');

    /// <summary>
    /// CMDNAMES 是 AutoCAD 自己的"当前命令名"系统变量，嵌套命令用 `'` 分隔（例如 `-LAYER'OFF`）。
    /// 改成宏或透明命令时它比 CommandInProgress 更准，所以优先用它，读不到再退回文档属性。
    /// </summary>
    private static string[] ActiveCommands(Document document)
    {
        string raw = null;
        try
        {
            var value = AcApp.GetSystemVariable("CMDNAMES");
            raw = value as string;
        }
        catch
        {
            raw = null;
        }

        if (string.IsNullOrWhiteSpace(raw)) raw = document.CommandInProgress;
        if (string.IsNullOrWhiteSpace(raw)) return Array.Empty<string>();

        var parts = raw.Split(new[] { '\'' });
        var commands = new List<string>(parts.Length);
        foreach (var part in parts)
        {
            var name = part.Trim().TrimStart('_', '.');
            if (name.Length > 0) commands.Add(name);
        }

        return commands.ToArray();
    }

    /// <summary>0.5.0 起命令态来自 CMDNAMES；只有在读不到任何命令名时才退回白名单。</summary>
    private static bool IsInterceptableCommand(string[] commands)
    {
        if (commands.Length == 0) return false;
        foreach (var command in commands)
        {
            if (!command.StartsWith("-", StringComparison.Ordinal)) return true;
        }

        return false;
    }

    /// <summary>兜底判据：只用于 CMDNAMES 与传统取值都拿不到的极端情况。</summary>
    private static bool IsFallbackAllowed(string name) =>
        !string.IsNullOrEmpty(name) && FallbackAllowedCommands.Contains(name);

    /// <summary>提示开始。这里绝不写日志或做 I/O：jig 提示每秒可触发数百次。</summary>
    private void Begin(Document document, PromptKind kind)
    {
        if (!_host.Enabled || !ReferenceEquals(document, AcApp.DocumentManager.MdiActiveDocument))
        {
            ClearContext();
            return;
        }

        var name = CommandOf(document);
        var commands = ActiveCommands(document);
        if (!IsInterceptableCommand(commands))
        {
            // 命令态取不到（极早期/极少数宿主）：退回 0.3.3 的白名单。
            if (commands.Length == 0 && IsFallbackAllowed(name))
            {
                _contextDocument = document;
                _contextKind = kind;
                _contextCommand = name;
                return;
            }

            ClearContext();
            return;
        }

        _contextDocument = document;
        _contextKind = kind;
        _contextCommand = name;
    }

    private void End(Document document)
    {
        if (ReferenceEquals(_contextDocument, document)) ClearContext();
    }

    private void OnPreTranslateMessage(object sender, PreTranslateMessageEventArgs e)
    {
        if (_inHandler || !_host.Enabled || e.Handled) return;

        var message = e.Message;
        var key = message.wParam.ToInt64();
        // KeyDown 是主路径；WM_CHAR 兜底覆盖跳过了 KeyDown 的消息路由。
        if ((message.message != 0x100 && message.message != 0x102) || (key != 13 && key != 32)) return;

        // 新的按键开始：上一笔的"已消费"标记作废，避免误吞这一笔的 WM_CHAR。
        if (message.message == 0x100) _consumedKeyDownKey = -1;

        if (message.message == 0x102 && key == _consumedKeyDownKey)
        {
            _consumedKeyDownKey = -1;
            return;
        }

        // 0.5.2：动态输入（十字光标旁的输入框）没有可用的托管入口，已移除拦截分支，
        // 只剩底部命令行这一条通路。详见 DynamicInputSupported。
        var document = AcApp.DocumentManager.MdiActiveDocument;
        if (document is null || _contextDocument != document ||
            CommandOf(document) != _contextCommand ||
            !IsInterceptableCommand(ActiveCommands(document)))
        {
            return;
        }

        if ((Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt)) != 0) return;

        // 0.5.0：底部命令行因图层/命令导致状态变化后可能取不到 WPF 输入框；
        // 取不到就退回"窗口类名判定 + WM_CHAR 事件回读"。判定成功说明焦点确实在命令行上。
        if (!AllowedCommandLineFocus(document))
        {
            if (!IsCommandLineWindowFocused(document)) return;
            return;
        }

        try
        {
            // 注意：AutoCAD 没有公开的“当前命令行文本 / 写回”API（Editor 上也没有 CommandLineText），
            // 这条路径只能用反射类型链读 InputBuffer（与 0.3.3 相同）。
            var buffer = AcApp.UIBindings.CommandEditorManager.ActiveEditor?.PromptAndInput?.InputBuffer;
            if (buffer is null) return;
            if (buffer.IsPromptingForCommandName()) return;
            ApplyConversion(message.message, key, _contextKind, buffer);
        }
        catch (Exception ex)
        {
            e.Handled = true;
            ClearContext();
            _host.OnFailure(ex);
        }
    }

    /// <summary>
    /// 动态输入拦截：<b>已停用</b>。
    /// 0.5.0 曾尝试反射 <c>Autodesk.AutoCAD.EditorInput.DynamicInput</c> 并读窗口文本，
    /// 但在 AutoCAD 2026 上实测：acmgd 里根本没有这个类型，窗口层只有 6 个始终存在的
    /// 隐藏 <c>CAcDynInputWndControl</c>（内部 Edit 子窗口 visible=False），焦点始终落在
    /// 文档视图的原生窗口上。动态输入是自绘控件，托管侧没有读写入口，所以这条路径
    /// 永远不可能生效，留着只会吞键、误导日志。0.5.2 起彻底移除。
    /// 参见 <see cref="DynamicInputSupported"/>。
    /// </summary>
    internal const bool DynamicInputSupported = false;

    /// <summary>把一次改写/拒绝落到当前输入缓冲上。</summary>
    private void ApplyConversion(int messageId, long key, PromptKind kind, object buffer)
    {
        // 输入缓冲的类型是 AutoCAD 未文档化的内部类型，用反射调用它的成员。
        var bufferType = buffer.GetType();
        var textProperty = bufferType.GetProperty("Text");
        var replaceQueue = bufferType.GetMethod("ReplaceInputQueue", new[] { typeof(string) });
        var setSelection = bufferType.GetMethod("OnSetSelectedTextQueue", new[] { typeof(int), typeof(int) });

        _contextKind = kind;
        var before = textProperty?.GetValue(buffer) as string ?? string.Empty;
        var conversion = _host.Evaluate(new SubmitRequest(_contextKind, _contextCommand, before));

        if (conversion.Decision == Decision.Pass)
        {
            Safe(() => _host.NoteSuccess());
            return;
        }

        if (conversion.Decision == Decision.Reject)
        {
            // 只记日志、不吞按键：吞掉 Enter 会让命令行彻底提交不了（0.4.4 的 bug）。
            // 仍标记"这一笔已处理"，避免紧随其后的 WM_CHAR 重复记一遍日志。
            NoteKeystrokeConsumed(messageId, key);
            _host.Report(LogLevel.Warn, "rejected: " + conversion.Code + " " + conversion.Message + " input=" + before);
            TryFeedback(() => _host.Feedback.OnRejected(before, conversion.Code ?? string.Empty, conversion.Message ?? string.Empty));
            Safe(() => _host.NoteSuccess());
            System.Media.SystemSounds.Beep.Play();
            return;
        }

        if (replaceQueue is null || setSelection is null)
        {
            _host.Report(LogLevel.Warn, "replacement unavailable: input queue has no ReplaceInputQueue");
            return;
        }

        // 与 AutoCAD 自己的命令行文本输入走同一条路：改写输入队列，而不是赋值 TextBox.Text。
        _inHandler = true;
        try
        {
            replaceQueue.Invoke(buffer, new object[] { conversion.Value });
            setSelection.Invoke(buffer, new object[] { conversion.Value.Length, conversion.Value.Length });
            NoteKeystrokeConsumed(messageId, key);
            _host.Report(LogLevel.Info,
                "replacement_requested " + before + " => " + conversion.Value + " command=" + _contextCommand +
                " msg=0x" + messageId.ToString("X"));
            TryFeedback(() => _host.Feedback.OnReplaced(before, conversion.Value));
            Safe(() => _host.NoteSuccess());
        }
        finally
        {
            _inHandler = false;
        }

        // 原始 Enter/Space 继续按 AutoCAD 原生流程走，不合成按键。
    }

    /// <summary>
    /// 回显是"锦上添花"：宿主没实现、或者实现里抛了（例如编辑器刚好不可用），都绝不能影响
    /// 已经完成的输入改写，所以这里把异常吞掉并只记一条日志。
    /// </summary>
    /// <summary>热点路径上的可选回调：任何异常都只记一条日志，绝不向上抛。</summary>
    private void Safe(Action action)
    {
        try { action(); }
        catch (Exception ex) { SafeReport(ex); }
    }

    private void SafeReport(Exception ex)
    {
        try { _host.Report(LogLevel.Warn, "host callback failed: " + ex.GetType().Name + ": " + ex.Message); }
        catch { }
    }

    private void TryFeedback(Action action)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            try
            {
                _host.Report(LogLevel.Warn, "feedback failed: " + ex.GetType().Name + ": " + ex.Message);
            }
            catch
            {
                // 连日志都失败时彻底放弃，热点路径不抛出。
            }
        }
    }

    /// <summary>
    /// 绝不要往属性面板/对话框的 TextBox 里写，即使当时正在画图。
    /// 先看 WPF 焦点是不是文本框，再交给窗口层（命令行窗口本身、它的子窗口、
    /// 已知窗口类）判定；这里刻意不去比较 CAD 内部命名空间里的类型名。
    /// </summary>
    private static bool AllowedFocus(Document document)
    {
        var focused = Keyboard.FocusedElement;
        if (focused is System.Windows.Controls.TextBox) return false;
        return AllowedFocusByWindow(document);
    }

    /// <summary>0.5.0：WPF 输入框是否能直接拿到（拿到就不必走事件回读的兜底路径）。</summary>
    private static bool AllowedCommandLineFocus(Document document) => AllowedFocus(document);

    /// <summary>
    /// 0.5.0 兜底：焦点落在命令行窗口上——不管 WPF 输入框取不取得。判定逻辑与老版本窗口类名一致。
    /// </summary>
    private static bool IsCommandLineWindowFocused(Document document) => AllowedFocusByWindow(document);

    /// <summary>
    /// 老版本（2015–2020）上 WPF 焦点类型可能拿不到，退回窗口类/子窗口判定。
    /// 类名白名单与 CADAutoIME 的 `_englishOnlyClasses` 同源：命令行、自动完成弹窗、动态输入框、工具提示。
    /// </summary>
    private static bool AllowedFocusByWindow(Document document)
    {
        var focus = GetFocus();
        if (focus == IntPtr.Zero) return false;

        var window = document.Window.Handle;
        if (focus == window || IsChild(window, focus)) return true;

        var className = GetClassName(focus);
        if (className is null) return false;
        return className is "acautocomp" or "accmdlineui" or "acdyninput" or "dyninput" or "#32768" or "tooltip_class32";
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetFocus();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsChild(IntPtr parent, IntPtr child);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int maxCount);

    private static string? GetClassName(IntPtr handle)
    {
        var buffer = new System.Text.StringBuilder(256);
        var length = GetClassName(handle, buffer, buffer.Capacity);
        if (length <= 0) return null;
        var text = buffer.ToString(0, length);
        return text.Length == 0 ? null : text;
    }

    /// <summary>单个文档的提示事件订阅。</summary>
    private sealed class PromptHooks : IDisposable
    {
        private readonly Document _document;
        private readonly Editor _editor;
        private readonly KeystrokeAdapter _owner;

        public PromptHooks(Document document, KeystrokeAdapter owner)
        {
            _document = document;
            _editor = document.Editor;
            _owner = owner;

            _editor.PromptingForPoint += OnPoint;
            _editor.PromptingForCorner += OnPoint;
            _editor.PromptingForDistance += OnDistance;
            _editor.PromptingForDouble += OnDouble;
            _editor.PromptingForAngle += OnAngle;
            _editor.PromptingForInteger += OnInteger;
            _editor.PromptingForString += OnOther;
            _editor.PromptingForKeyword += OnOther;
            _editor.PromptingForSelection += OnOther;
            _editor.PromptingForEntity += OnOther;
            _editor.PromptingForNestedEntity += OnOther;
            _editor.EnteringQuiescentState += OnIdle;

            _document.CommandEnded += OnCommandEnded;
            _document.CommandCancelled += OnCommandEnded;
            _document.CommandFailed += OnCommandEnded;
        }

        private void OnPoint(object sender, PromptPointOptionsEventArgs e) => _owner.Begin(_document, PromptKind.Point);

        private void OnDistance(object sender, PromptDistanceOptionsEventArgs e) => _owner.Begin(_document, PromptKind.Other);

        private void OnDouble(object sender, PromptDoubleOptionsEventArgs e) => _owner.Begin(_document, PromptKind.Other);

        private void OnAngle(object sender, PromptAngleOptionsEventArgs e) => _owner.Begin(_document, PromptKind.Other);

        private void OnInteger(object sender, PromptIntegerOptionsEventArgs e) => _owner.Begin(_document, PromptKind.Integer);

        private void OnOther(object sender, EventArgs e) => _owner.End(_document);

        private void OnOther(object sender, PromptStringOptionsEventArgs e) => _owner.End(_document);

        private void OnOther(object sender, PromptKeywordOptionsEventArgs e) => _owner.End(_document);

        private void OnOther(object sender, PromptSelectionOptionsEventArgs e) => _owner.End(_document);

        private void OnOther(object sender, PromptEntityOptionsEventArgs e) => _owner.End(_document);

        private void OnOther(object sender, PromptNestedEntityOptionsEventArgs e) => _owner.End(_document);

        private void OnIdle(object? sender, EventArgs e) => _owner.End(_document);

        private void OnCommandEnded(object sender, CommandEventArgs e) => _owner.End(_document);

        public void Dispose()
        {
            _editor.PromptingForPoint -= OnPoint;
            _editor.PromptingForCorner -= OnPoint;
            _editor.PromptingForDistance -= OnDistance;
            _editor.PromptingForDouble -= OnDouble;
            _editor.PromptingForAngle -= OnAngle;
            _editor.PromptingForInteger -= OnInteger;
            _editor.PromptingForString -= OnOther;
            _editor.PromptingForKeyword -= OnOther;
            _editor.PromptingForSelection -= OnOther;
            _editor.PromptingForEntity -= OnOther;
            _editor.PromptingForNestedEntity -= OnOther;
            _editor.EnteringQuiescentState -= OnIdle;

            _document.CommandEnded -= OnCommandEnded;
            _document.CommandCancelled -= OnCommandEnded;
            _document.CommandFailed -= OnCommandEnded;
        }
    }
}
