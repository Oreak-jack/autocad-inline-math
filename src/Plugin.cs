using System.IO;
using System.Runtime.InteropServices;
using System.Reflection;
using System.Windows.Input;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.EditorInput;
using Autodesk.AutoCAD.Runtime;
using AcApp=Autodesk.AutoCAD.ApplicationServices.Application;
[assembly: ExtensionApplication(typeof(CadMath03.Plugin))]
[assembly: CommandClass(typeof(CadMath03.Plugin))]
namespace CadMath03;

public sealed class Plugin : IExtensionApplication
{
    static bool enabled=true, inHandler;
    static Document? contextDoc;
    static string contextKind="", contextCommand="", lastError="";
    static int conversions;
    static readonly Dictionary<Document,Hooks> documents=new();
    static readonly string log=Path.Combine(Path.GetTempPath(),"CadMath03.log");
    static readonly HashSet<string> allowed=new(StringComparer.OrdinalIgnoreCase) {"LINE","PLINE","CIRCLE","ARC","RECTANG","OFFSET","MOVE","COPY","ROTATE","SCALE","STRETCH","FILLET","CHAMFER","POLYGON","ELLIPSE","LENGTHEN"};
    public void Initialize()
    {
        // Disable only our own previously shipped plugins. No CAD settings are changed.
        foreach(var a in AppDomain.CurrentDomain.GetAssemblies()) {
            var n=a.GetName().Name;
            if(n is "CadMath" or "CadMathNative") {
                var t=a.GetType(n=="CadMath"?"CadMath.Plugin":"CadMathNative.NativePlugin");
                try { t?.GetMethod("Off",BindingFlags.Public|BindingFlags.Static)?.Invoke(null,null); } catch { }
            }
        }
        foreach(Document d in AcApp.DocumentManager) Attach(d);
        AcApp.DocumentManager.DocumentCreated+=Created;
        AcApp.DocumentManager.DocumentToBeDestroyed+=Destroying;
        AcApp.DocumentManager.DocumentActivated+=Activated;
        AcApp.EnterModal+=Modal;
        AcApp.PreTranslateMessage+=Message;
        WriteLog("loaded 0.3.2; actual InputBuffer API; old versions disabled");
        AcApp.DocumentManager.MdiActiveDocument?.Editor.WriteMessage("\nCadMath 0.3.2 底部命令栏计算已启用。关闭：CM3OFF；状态：CM3STATUS。\n");
    }
    public void Terminate()
    {
        AcApp.PreTranslateMessage-=Message; AcApp.EnterModal-=Modal;
        AcApp.DocumentManager.DocumentCreated-=Created;
        AcApp.DocumentManager.DocumentToBeDestroyed-=Destroying;
        AcApp.DocumentManager.DocumentActivated-=Activated;
        foreach(var h in documents.Values)h.Dispose(); documents.Clear(); Clear();
    }
    static void Attach(Document d){if(!documents.ContainsKey(d))documents[d]=new Hooks(d);}
    static void Created(object s,DocumentCollectionEventArgs e)=>Attach(e.Document);
    static void Destroying(object s,DocumentCollectionEventArgs e){Clear();if(documents.Remove(e.Document,out var h))h.Dispose();}
    static void Activated(object s,DocumentCollectionEventArgs e)=>Clear();
    static void Modal(object? s,EventArgs e)=>Clear();
    static void Clear(){contextDoc=null;contextKind="";contextCommand="";}
    static string Command(Document d)=>d.CommandInProgress.TrimStart('_','.');
    static void Begin(Document d,string kind)
    {
        // No logging or I/O here: native jig prompts can fire hundreds of times per second.
        if(!enabled || d!=AcApp.DocumentManager.MdiActiveDocument || !allowed.Contains(Command(d))){Clear();return;}
        contextDoc=d;contextKind=kind;contextCommand=Command(d);
    }
    [CommandMethod("CM3ON")]public static void On(){Clear();enabled=true;WriteLog("enabled");}
    [CommandMethod("CM3OFF")]public static void Off(){enabled=false;Clear();WriteLog("disabled");}
    [CommandMethod("CM3STATUS")]public static void Status()=>AcApp.DocumentManager.MdiActiveDocument.Editor.WriteMessage($"\nCadMath 0.3.2 开启={enabled} 替换请求={conversions} 最后错误={lastError}\n日志：{log}\n");
    [CommandMethod("CM3CHECK")]
    public static void Check()
    {
        var d=AcApp.DocumentManager.MdiActiveDocument; var sel=d.Editor.SelectLast();
        if(sel.Status!=PromptStatus.OK)return;
        using var tr=d.Database.TransactionManager.StartOpenCloseTransaction();
        foreach(var id in sel.Value.GetObjectIds())if(tr.GetObject(id,Autodesk.AutoCAD.DatabaseServices.OpenMode.ForRead) is Autodesk.AutoCAD.DatabaseServices.Line line){
            string result="last LINE length="+line.Length.ToString("G17",System.Globalization.CultureInfo.InvariantCulture);
            d.Editor.WriteMessage("\n"+result+"\n");WriteLog(result);
        }
    }
    static bool AllowedFocus(Document d)
    {
        // Never write to a random Properties/dialog TextBox, even during a drawing command.
        var wpf=Keyboard.FocusedElement;
        if(wpf?.GetType().FullName=="Autodesk.AutoCAD.ViewModel.CommandLine.CommandLineTextBox")return true;
        if(wpf is System.Windows.Controls.TextBox)return false;
        var focus=GetFocus();var docWindow=d.Window.Handle;
        return focus!=IntPtr.Zero && (focus==docWindow || IsChild(docWindow,focus));
    }
    static void Message(object sender,PreTranslateMessageEventArgs e)
    {
        if(inHandler || !enabled || e.Handled)return;
        var msg=e.Message;long key=msg.wParam.ToInt64();
        // KeyDown is the early path; WM_CHAR is a fallback for message routes that skip it.
        if((msg.message!=0x100 && msg.message!=0x102) || (key!=13 && key!=32))return;
        var d=AcApp.DocumentManager.MdiActiveDocument;
        if(d==null || contextDoc!=d || Command(d)!=contextCommand || !allowed.Contains(contextCommand))return;
        if((Keyboard.Modifiers & (ModifierKeys.Control|ModifierKeys.Alt))!=0)return;
        try {
            if(!AllowedFocus(d))return;
            var buffer=AcApp.UIBindings.CommandEditorManager.ActiveEditor?.PromptAndInput?.InputBuffer;
            if(buffer==null || buffer.IsPromptingForCommandName())return;
            var before=buffer.Text;
            var conversion=InputPolicy.Convert(before,contextKind=="point",contextKind=="integer");
            if(conversion.Decision==Decision.Pass)return;
            if(conversion.Decision==Decision.Reject){
                e.Handled=true;lastError=conversion.Error;WriteLog("rejected: "+lastError);System.Media.SystemSounds.Beep.Play();return;
            }
            // This is the same input-buffer route used by AutoCAD command-line text entry.
            // Do not assign TextBox.Text: its displayed value is not the native input queue.
            inHandler=true;
            try {
                buffer.ReplaceInputQueue(conversion.Value);
                buffer.OnSetSelectedTextQueue(conversion.Value.Length,conversion.Value.Length);
                conversions++;lastError="";
                WriteLog("replacement_requested "+before+" => "+conversion.Value+" command="+contextCommand);
            } finally {inHandler=false;}
            // The original Enter/Space continues through AutoCAD normally. No synthetic keys.
        }catch(System.Exception ex){
            // Fail closed instead of letting a partially updated expression create geometry.
            e.Handled=true;enabled=false;lastError=ex.GetType().Name+": "+ex.Message;
            WriteLog("disabled_on_error "+lastError);Clear();
        }
    }
    static void WriteLog(string value)
    {
        try {if(File.Exists(log) && new FileInfo(log).Length>1_048_576)return;File.AppendAllText(log,DateTime.Now.ToString("O")+" "+value+Environment.NewLine);}catch{}
    }
    [DllImport("user32.dll")]static extern IntPtr GetFocus();
    [DllImport("user32.dll")][return:MarshalAs(UnmanagedType.Bool)]static extern bool IsChild(IntPtr parent,IntPtr child);
    sealed class Hooks:IDisposable
    {
        readonly Document d;readonly Editor ed;
        public Hooks(Document doc){d=doc;ed=doc.Editor;
            ed.PromptingForPoint+=Point;ed.PromptingForCorner+=Point;ed.PromptingForDistance+=Distance;ed.PromptingForDouble+=Double;ed.PromptingForAngle+=Angle;ed.PromptingForInteger+=Integer;
            ed.PromptingForString+=String;ed.PromptingForKeyword+=Keyword;ed.PromptingForSelection+=Selection;ed.PromptingForEntity+=Entity;ed.PromptingForNestedEntity+=Nested;
            ed.EnteringQuiescentState+=Idle;
            d.CommandEnded+=EndCommand;d.CommandCancelled+=EndCommand;d.CommandFailed+=EndCommand;
        }
        void Point(object s,PromptPointOptionsEventArgs e)=>Begin(d,"point");
        void Distance(object s,PromptDistanceOptionsEventArgs e)=>Begin(d,"distance");
        void Double(object s,PromptDoubleOptionsEventArgs e)=>Begin(d,"double");
        void Angle(object s,PromptAngleOptionsEventArgs e)=>Begin(d,"angle");
        void Integer(object s,PromptIntegerOptionsEventArgs e)=>Begin(d,"integer");
        void String(object s,PromptStringOptionsEventArgs e)=>End();
        void Keyword(object s,PromptKeywordOptionsEventArgs e)=>End();
        void Selection(object s,PromptSelectionOptionsEventArgs e)=>End();
        void Entity(object s,PromptEntityOptionsEventArgs e)=>End();
        void Nested(object s,PromptNestedEntityOptionsEventArgs e)=>End();
        void Idle(object? s,EventArgs e)=>End();
        void EndCommand(object s,CommandEventArgs e)=>End();
        void End(){if(contextDoc==d)Clear();}
        public void Dispose(){
            ed.PromptingForPoint-=Point;ed.PromptingForCorner-=Point;ed.PromptingForDistance-=Distance;ed.PromptingForDouble-=Double;ed.PromptingForAngle-=Angle;ed.PromptingForInteger-=Integer;
            ed.PromptingForString-=String;ed.PromptingForKeyword-=Keyword;ed.PromptingForSelection-=Selection;ed.PromptingForEntity-=Entity;ed.PromptingForNestedEntity-=Nested;
            ed.EnteringQuiescentState-=Idle;
            d.CommandEnded-=EndCommand;d.CommandCancelled-=EndCommand;d.CommandFailed-=EndCommand;
        }
    }
}
