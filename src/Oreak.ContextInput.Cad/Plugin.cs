using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Input;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Runtime;
using Autodesk.AutoCAD.Windows;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

[assembly: ExtensionApplication(typeof(Oreak.ContextInput.Plugin))]
[assembly: CommandClass(typeof(Oreak.ContextInput.Plugin))]
namespace Oreak.ContextInput;

public sealed class Plugin : IExtensionApplication
{
    static Plugin? instance;
    readonly Controller controller = new Controller();
    readonly SymbolCodePolicy symbols = new SymbolCodePolicy();
    bool symbolsEnabled = true, symbolShiftOnly;
    IntPtr symbolFocus;
    readonly HashSet<string> symbolTrace = new HashSet<string>();
    void TraceSymbol(string reason)
    {
        if (symbolTrace.Count < 24 && symbolTrace.Add(reason)) Record("symbol-trace " + reason);
    }
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly HashSet<Document> documents = new HashSet<Document>();
    readonly Queue<string> log = new Queue<string>();
    System.Windows.Forms.Timer? timer;
    Document? active;
    long session, boundary, doubleClickUntil;
    IntPtr clickFocus;
    // 默认启用：装完即生效，不必每次启动都敲 OCION（OCIOFF / OCIOBSERVE 可退回）。
    bool selectedText, editCommand, createCommand, observe = false, busy, editorExists;
    string last = "", command = "";
    int errors, editorFlag = -1;
    static readonly string LogPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OreakCADTools", "logs", "contextinput.log");
    static string Version => typeof(Plugin).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    public void Initialize()
    {
        if (instance != null) return;
        instance = this;
        try
        {
            foreach (Document d in AcApp.DocumentManager) Attach(d);
            AcApp.DocumentManager.DocumentCreated += Created;
            AcApp.DocumentManager.DocumentToBeDestroyed += Destroyed;
            AcApp.DocumentManager.DocumentActivated += Activated;
            AcApp.PreTranslateMessage += Message;
            AcApp.Idle += Idle;
            timer = new System.Windows.Forms.Timer { Interval = 80 };
            timer.Tick += Tick; timer.Start(); controller.Start();
            Record("plugin-version=" + Version + " symbols=" + symbolsEnabled);
            Say("语境切换 " + Version + " 已启用：编辑文字时切中文，退出回英文。OCIOFF 停用，OCISTATUS 状态。");
        }
        catch (System.Exception ex)
        {
            // 独立插件：自己起不来就把自己收干净并报出来，绝不把异常抛给 AutoCAD 牵连别的插件。
            Record("initialize-failed " + ex.GetType().Name + ": " + ex.Message);
            try { Terminate(); } catch { }
            try { Say("语境切换未能启动：" + ex.GetType().Name + "+" + ex.Message + "（详见 " + LogPath + "）"); } catch { }
        }
    }
    public void Terminate()
    {
        symbols.Reset();
        controller.Stop();
        if (timer != null) { timer.Stop(); timer.Tick -= Tick; timer.Dispose(); timer = null; }
        AcApp.PreTranslateMessage -= Message; AcApp.Idle -= Idle;
        AcApp.DocumentManager.DocumentCreated -= Created;
        AcApp.DocumentManager.DocumentToBeDestroyed -= Destroyed;
        AcApp.DocumentManager.DocumentActivated -= Activated;
        foreach (var d in documents) Detach(d);
        documents.Clear(); Flush(); if (instance == this) instance = null;
    }
    void Attach(Document d)
    { if (!documents.Add(d)) return; d.CommandWillStart += Begin; d.CommandEnded += End; d.CommandCancelled += End; d.CommandFailed += End; }
    void Detach(Document d)
    { d.CommandWillStart -= Begin; d.CommandEnded -= End; d.CommandCancelled -= End; d.CommandFailed -= End; }
    void Created(object sender, DocumentCollectionEventArgs e) => Attach(e.Document);
    void Destroyed(object sender, DocumentCollectionEventArgs e)
    { Detach(e.Document); documents.Remove(e.Document); if (e.Document == active) Reset(); }
    void Activated(object sender, DocumentCollectionEventArgs e) { Reset(); active = e.Document; }
    void Reset() { symbols.Reset(); symbolShiftOnly = false; session++; boundary++; doubleClickUntil = 0; editCommand = createCommand = selectedText = false; clickFocus = IntPtr.Zero; command = ""; }

    void Message(object sender, PreTranslateMessageEventArgs e)
    {
        HandleSymbolMessage(e);
        if (e.Message.message != 0x203) return; // WM_LBUTTONDBLCLK, never consume user input.
        doubleClickUntil = clock.ElapsedMilliseconds + 1800;
        clickFocus = NativeInput.Focus(); session++;
        selectedText = SelectedIsText();
        Record("double-click");
    }
    void HandleSymbolMessage(PreTranslateMessageEventArgs e)
    {
        var message = e.Message.message;
        if (message != 0x100 && message != 0x101 && message != 0x102 && message != 0x201) return;
        if (!editCommand && !createCommand) return;
        TraceSymbol("message-kind=" + message.ToString("X")); // message type only, never key/character values
        if (!controller.Enabled || observe || !symbolsEnabled || busy)
        { TraceSymbol("gate enabled=" + controller.Enabled + " observe=" + observe + " symbols=" + symbolsEnabled + " busy=" + busy); return; }
        busy = true;
        try
        {
            IntPtr focus; var scene = Snapshot(out focus);
            if (!scene.Editing || !scene.EditorFocus || !scene.Foreground ||
                (symbols.Active && focus != symbolFocus))
            { TraceSymbol("scene-rejected editing=" + scene.Editing + " focus=" + scene.EditorFocus + " foreground=" + scene.Foreground); symbols.Reset(); return; }
            int key = (int)e.Message.wParam;
            if (message == 0x100 && key == 0xE5)
            {
                key = NativeInput.OriginalKey(focus, key);
                TraceSymbol("ime-process-key recovered=" + (key != 0 && key != 0xE5));
            }
            if (message == 0x101)
            {
                if (key == 0x10 && symbolShiftOnly && symbols.Active)
                { symbols.Reset(); controller.RespectManualSwitch(); Record("symbol-manual-switch"); }
                symbolShiftOnly = false;
                return;
            }
            if (message == 0x102)
            {
                if (key == 'c' || key == 'C' || key == 'd' || key == 'D' || key == 'p' || key == 'P')
                    symbols.CharacterDelivered(clock.ElapsedMilliseconds);
                return;
            }
            if (symbols.Active && scene.Mode != InputMode.English)
            { symbols.Reset(); controller.RespectManualSwitch(); Record("symbol-external-mode-change"); return; }
            if (!NativeInput.CompositionIdle(focus))
            { TraceSymbol("composition-not-idle-or-unavailable"); symbols.Reset(); return; }
            if (message == 0x201) { ApplySymbolMode(symbols.Restore(), focus); return; }
            bool shift = key == 0x10;
            if (shift) symbolShiftOnly = symbols.Active;
            else symbolShiftOnly = false;
            bool shortcut = NativeInput.KeyDown(0x11) || NativeInput.KeyDown(0x12);
            bool percent = key == 0x35 && NativeInput.KeyDown(0x10) && !shortcut;
            if (key == 0x35) TraceSymbol("percent-key shift=" + NativeInput.KeyDown(0x10) + " shortcut=" + shortcut);
            bool letter = !shortcut && (key == 0x43 || key == 0x44 || key == 0x50);
            bool repeat = ((long)e.Message.lParam & (1L << 30)) != 0;
            var target = symbols.BeforeKey(percent, letter, shift, repeat,
                scene.Mode == InputMode.Chinese && !controller.ManualOverride, clock.ElapsedMilliseconds);
            if (percent) TraceSymbol("percent-decision mode=" + scene.Mode + " manual=" + controller.ManualOverride + " repeat=" + repeat + " target=" + target);
            if (target == InputMode.English) symbolFocus = focus;
            ApplySymbolMode(target, focus);
        }
        catch (System.Exception ex) { symbols.Reset(); Record("symbol-error-type=" + ex.GetType().Name); }
        finally { busy = false; }
    }
    void ApplySymbolMode(InputMode target, IntPtr focus)
    {
        if (target == InputMode.Unknown) return;
        IntPtr check; var fresh = Snapshot(out check);
        if (check != focus || !fresh.Editing || !fresh.EditorFocus || !NativeInput.CompositionIdle(check))
        { TraceSymbol("write-revalidation-rejected"); symbols.Reset(); return; }
        bool accepted = NativeInput.Set(check, target);
        var actual = NativeInput.Read(check);
        Record("symbol-mode-request=" + target + " api-accepted=" + accepted + " readback=" + actual);
        if (actual != target) symbols.Reset(); // No repeated mode changes during user typing.
    }
    bool SelectedIsText()
    {
        var d = AcApp.DocumentManager.MdiActiveDocument;
        if (d == null) return false;
        try
        {
            var selection = d.Editor.SelectImplied();
            if (selection.Status != PromptStatus.OK || selection.Value.Count != 1) return false;
            var id = selection.Value.GetObjectIds()[0];
            var type = id.ObjectClass;
            return type.IsDerivedFrom(RXObject.GetClass(typeof(DBText))) || type.IsDerivedFrom(RXObject.GetClass(typeof(MText)));
        }
        catch { return false; }
    }
    void Begin(object sender, CommandEventArgs e)
    {
        if (!ReferenceEquals(sender, AcApp.DocumentManager.MdiActiveDocument)) return;
        symbols.Reset(); symbolShiftOnly = false;
        symbolTrace.Clear();
        command = e.GlobalCommandName.TrimStart('_','.').ToUpperInvariant(); boundary++;
        createCommand = EditorFocusPolicy.IsCreationCommand(command);
        if (createCommand) { session++; doubleClickUntil = 0; clickFocus = IntPtr.Zero; }
        if (command == "DDEDIT" || command == "TEXTEDIT" || command == "MTEDIT")
            editCommand = clock.ElapsedMilliseconds <= doubleClickUntil && (selectedText || SelectedIsText());
        else editCommand = false;
        Record("command-boundary scene=" + (createCommand ? command : editCommand ? "existing-text" : "other"));
    }
    void End(object sender, CommandEventArgs e)
    {
        if (!ReferenceEquals(sender, AcApp.DocumentManager.MdiActiveDocument)) return;
        if (editCommand || createCommand) Record("symbol-trace-summary distinct=" + symbolTrace.Count);
        symbols.Reset(); symbolShiftOnly = false;
        editCommand = createCommand = false; selectedText = false; doubleClickUntil = 0; boundary++; command = "";
        Record("command-finished");
    }
    Scene Snapshot(out IntPtr focus)
    {
        focus = NativeInput.Focus(); var cls = NativeInput.Class(focus);
        var managed = Keyboard.FocusedElement?.GetType().Name ?? "";
        // Native text editors only; never infer focus solely from a command name.
        bool textControl = cls.Equals("Edit", StringComparison.OrdinalIgnoreCase) || cls.IndexOf("RichEdit", StringComparison.OrdinalIgnoreCase) >= 0;
        bool commandControl = managed.IndexOf("CommandLine", StringComparison.OrdinalIgnoreCase) >= 0;
        // Creation has no double-click HWND. Accept only the active document's
        // native drawing window, then still require an actual active editor.
        bool creationViewport = createCommand && !commandControl &&
            cls.StartsWith("Afx:", StringComparison.OrdinalIgnoreCase) &&
            NativeInput.BelongsTo(focus, active?.Window.Handle ?? IntPtr.Zero);
        if (creationViewport) clickFocus = focus;
        // Retain the drawing HWND so the first post-command snapshot can restore English.
        bool viewport = focus != IntPtr.Zero && focus == clickFocus &&
            NativeInput.BelongsTo(focus, active?.Window.Handle ?? IntPtr.Zero);
        editorFlag = Convert.ToInt32(AcApp.GetSystemVariable("TEXTEDITOR"));
        editorExists = EditorFocusPolicy.IsActiveEditor(editorFlag);
        bool eligible = editCommand || createCommand;
        bool editorFocus = EditorFocusPolicy.Confirm(eligible, editorExists,
            focus != IntPtr.Zero, viewport, textControl, commandControl);
        return new Scene { Session = session, Boundary = boundary, Foreground = focus != IntPtr.Zero,
            Candidate = !editorExists && clock.ElapsedMilliseconds < doubleClickUntil,
            Editing = eligible && editorExists, EditorFocus = editorFocus,
            EnglishTarget = commandControl || viewport, Mode = NativeInput.Read(focus) };
    }
    void Tick(object? sender, EventArgs e)
    {
        if (busy || !controller.Enabled) return;
        busy = true;
        try
        {
            if (active != AcApp.DocumentManager.MdiActiveDocument) { Reset(); active = AcApp.DocumentManager.MdiActiveDocument; }
            if (active == null) return;
            if (command.Length == 0 && clock.ElapsedMilliseconds > doubleClickUntil) selectedText = SelectedIsText();
            IntPtr focus; var s = Snapshot(out focus);
            if (symbols.Active)
            {
                if (!s.Editing || !s.EditorFocus || !s.Foreground || focus != symbolFocus) symbols.Reset();
                else if (s.Mode != InputMode.English)
                { symbols.Reset(); controller.RespectManualSwitch(); Record("symbol-external-mode-change"); }
                else
                {
                    var target = symbols.Poll(clock.ElapsedMilliseconds);
                    if (target == InputMode.Unknown) return;
                    ApplySymbolMode(target, focus);
                    s = Snapshot(out focus);
                }
            }
            var r = controller.Observe(s, clock.ElapsedMilliseconds);
            var cls = NativeInput.Class(focus); var managed = Keyboard.FocusedElement?.GetType().Name ?? "";
            var diagnostic = $"{controller.State}|{controller.Reason}|mode={s.Mode}|class={cls}|managed={managed}|edit={editCommand}|create={createCommand}|editorExists={editorExists}|editorFlag={editorFlag}|selected={selectedText}|observe={observe}";
            if (diagnostic != last) { Record(diagnostic); last = diagnostic; }
            if (r != null && !observe)
            {
                IntPtr check; var fresh = Snapshot(out check);
                if (focus == check && controller.IsCurrent(r, fresh))
                {
                    var before = NativeInput.Describe(check);
                    bool accepted = NativeInput.Set(check, r.Mode);
                    Record("mode-request=" + r.Mode + " api-accepted=" + accepted +
                        " readback=" + NativeInput.Read(check) + " before=[" + before +
                        "] after=[" + NativeInput.Describe(check) + "]");
                }
            }
            errors = 0;
        }
        catch (System.Exception ex)
        {
            Record("error-type=" + ex.GetType().Name);
            if (++errors >= 3) { controller.Stop(); Say("语境切换已暂停：连续探测失败。OCISTATUS 查看状态。"); }
        }
        finally { busy = false; }
    }
    void Record(string message)
    { if (log.Count < 500) log.Enqueue(DateTime.UtcNow.ToString("O") + " session=" + session + " " + message); }
    void Idle(object? sender, EventArgs e) => Flush();
    void Flush()
    {
        if (log.Count == 0) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 2_000_000) File.WriteAllText(LogPath, "log rotated\n");
            File.AppendAllLines(LogPath, log.ToArray(), new UTF8Encoding(false)); log.Clear();
        }
        catch { log.Clear(); } // Diagnostics must never block normal CAD operation.
    }
    static void Say(string text) => AcApp.DocumentManager.MdiActiveDocument?.Editor.WriteMessage("\n" + text + "\n");
    [CommandMethod("OCION")]
    public void On() { if (instance == null) return; instance.observe = false; instance.Reset(); instance.controller.Start(); Say("语境切换已启用。请保持 KBL 关闭。"); }
    [CommandMethod("OCIOBSERVE")]
    public void Observe() { if (instance == null) return; instance.observe = true; instance.Reset(); instance.controller.Start(); Say("语境切换：仅观察，只写日志不切输入法。"); }
    [CommandMethod("OCIOFF")]
    public void Off()
    {
        if (instance == null) return;
        var focus = NativeInput.Focus();
        if (!instance.observe && focus != IntPtr.Zero) NativeInput.Set(focus, InputMode.English);
        instance.controller.Stop(); instance.Reset(); Say("语境切换已停用；不会启动 KBL。");
    }
    [CommandMethod("OCISTATUS")]
    public void Status() { Say(instance == null ? "未加载" : "ContextInput " + Version + " enabled=" + instance.controller.Enabled + " observe=" + instance.observe + " symbols=" + instance.symbolsEnabled + " " + instance.last + "\n输入法：" + NativeInput.Describe(NativeInput.Focus()) + "\n日志：" + LogPath); }

    [CommandMethod("OCISYMBOLSOFF")]
    public void SymbolsOff() { if (instance == null) return; instance.symbolsEnabled = false; instance.symbols.Reset(); Say("符号代码优化已关闭；语境切换保持原设置。"); }
    [CommandMethod("OCISYMBOLSON")]
    public void SymbolsOn() { if (instance == null) return; instance.symbolsEnabled = true; Say("符号代码优化已开启：%%c / %%d / %%p。"); }

    [CommandMethod("OCITESTDRAWING", CommandFlags.Session)]
    public void TestDrawing()
    {
        // Explicit test command creates a new document, never changes the previous drawing.
        var doc = AcApp.DocumentManager.Add("acadiso.dwt");
        AcApp.DocumentManager.MdiActiveDocument = doc;
        using (doc.LockDocument())
        using (var tr = doc.Database.TransactionManager.StartTransaction())
        {
            var table = (BlockTable)tr.GetObject(doc.Database.BlockTableId, OpenMode.ForRead);
            var space = (BlockTableRecord)tr.GetObject(table[BlockTableRecord.ModelSpace], OpenMode.ForWrite);
            var text = new DBText { Position = new Autodesk.AutoCAD.Geometry.Point3d(0,30,0), Height = 4, TextString = "TEXT test" };
            space.AppendEntity(text); tr.AddNewlyCreatedDBObject(text, true);
            var mtext = new MText { Location = new Autodesk.AutoCAD.Geometry.Point3d(0,10,0), TextHeight = 4, Width = 60, Contents = "MTEXT test" };
            space.AppendEntity(mtext); tr.AddNewlyCreatedDBObject(mtext, true); tr.Commit();
        }
        doc.SendStringToExecute("_.ZOOM _E ", true, false, false);
    }
}



