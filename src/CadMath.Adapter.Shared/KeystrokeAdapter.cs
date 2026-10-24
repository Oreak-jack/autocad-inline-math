using System;
using System.Collections.Generic;
using System.Reflection;
using System.Threading;
using System.Runtime.InteropServices;
using System.Windows.Input;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.EditorInput;
using CadMath.Abstractions;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

namespace CadMath.Adapters;

/// <summary>
/// 键盘拦截适配器的公共实现：2025/2026（net8）与 2024 及更早（net48）共用同一份源码，
/// 只有编译引用不同。逻辑是 v0.3.3 里 Plugin 的拦截部分逐行搬过来的：
/// 宿主版本差异、策略、格式化全部在本程序集之外，这里只负责"什么时候拦、拦到什么都交出去、怎么把结果写回输入队列"。
/// </summary>
public abstract class KeystrokeAdapter : ICadAdapter
{
    /// <summary>允许改写的命令。其余命令——包括自定义命令与非 ASCII 输入——一律不碰。</summary>
    private static readonly HashSet<string> AllowedCommands = new(StringComparer.OrdinalIgnoreCase)
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

    /// <summary>提示开始。这里绝不写日志或做 I/O：jig 提示每秒可触发数百次。</summary>
    private void Begin(Document document, PromptKind kind)
    {
        if (!_host.Enabled ||
            !ReferenceEquals(document, AcApp.DocumentManager.MdiActiveDocument) ||
            !AllowedCommands.Contains(CommandOf(document)))
        {
            ClearContext();
            return;
        }

        _contextDocument = document;
        _contextKind = kind;
        _contextCommand = CommandOf(document);
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

        var document = AcApp.DocumentManager.MdiActiveDocument;
        if (document is null || _contextDocument != document ||
            CommandOf(document) != _contextCommand ||
            !AllowedCommands.Contains(_contextCommand))
        {
            return;
        }

        if ((Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt)) != 0) return;

        try
        {
            if (!AllowedFocus(document)) return;

            var buffer = AcApp.UIBindings.CommandEditorManager.ActiveEditor?.PromptAndInput?.InputBuffer;
            if (buffer is null || buffer.IsPromptingForCommandName()) return;

            var before = buffer.Text;
            var conversion = _host.Evaluate(new SubmitRequest(_contextKind, _contextCommand, before));

            if (conversion.Decision == Decision.Pass) return;

            if (conversion.Decision == Decision.Reject)
            {
                // 只记日志、不吞按键：吞掉 Enter 会让命令行彻底提交不了（0.4.4 的 bug）。
                // 仍标记"这一笔已处理"，避免紧随其后的 WM_CHAR 重复记一遍日志。
                NoteKeystrokeConsumed(message.message, key);
                _host.Report(LogLevel.Warn, "rejected: " + conversion.Code + " " + conversion.Message + " input=" + before);
                System.Media.SystemSounds.Beep.Play();
                return;
            }

            // 与 AutoCAD 自己的命令行文本输入走同一条路：改写输入队列，而不是赋值 TextBox.Text。
            _inHandler = true;
            try
            {
                buffer.ReplaceInputQueue(conversion.Value);
                buffer.OnSetSelectedTextQueue(conversion.Value.Length, conversion.Value.Length);
                NoteKeystrokeConsumed(message.message, key);
                _host.Report(LogLevel.Info,
                    "replacement_requested " + before + " => " + conversion.Value + " command=" + _contextCommand +
                    " msg=0x" + message.message.ToString("X"));
            }
            finally
            {
                _inHandler = false;
            }

            // 原始 Enter/Space 继续按 AutoCAD 原生流程走，不合成按键。
        }
        catch (Exception ex)
        {
            // 失败即关闭：宁可本条命令用原始输入，也不能让半改写的表达式画出错误几何。
            e.Handled = true;
            ClearContext();
            _host.OnFailure(ex);
        }
    }

    /// <summary>绝不要往属性面板/对话框的 TextBox 里写，即使当时正在画图。</summary>
    private static bool AllowedFocus(Document document)
    {
        var focused = Keyboard.FocusedElement;
        if (focused?.GetType().FullName == "Autodesk.AutoCAD.ViewModel.CommandLine.CommandLineTextBox") return true;
        if (focused is System.Windows.Controls.TextBox) return false;
        return AllowedFocusByWindow(document);
    }

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
