using Autodesk.AutoCAD.Runtime;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

[assembly: ExtensionApplication(typeof(CadMath.Shell.ShellApplication))]
[assembly: CommandClass(typeof(CadMath.Shell.ShellCommands))]

namespace CadMath.Shell;

/// <summary>程序集入口：只有生命周期，不含业务判断。</summary>
public sealed class ShellApplication : IExtensionApplication
{
    internal static AdapterManager? Manager { get; private set; }

    public void Initialize()
    {
        var log = new LogFile.Sink();
        try
        {
            Manager = new AdapterManager(log);
            Manager.Start();

            var editor = AcApp.DocumentManager.MdiActiveDocument?.Editor;
            if (Manager.HasAdapter)
            {
                editor?.WriteMessage(
                    $"\n{ProductInfo.Name} {ProductInfo.Version} 底部命令栏计算已启用。关闭：CLMOFF；状态：CLMSTATUS。\n");
            }
            else
            {
                editor?.WriteMessage(
                    $"\n{ProductInfo.Name} {ProductInfo.Version} 未启用：{Manager.LastError ?? "没有可用适配器"}（CLMSTATUS 查看详情）\n");
            }
        }
        catch (System.Exception ex)
        {
            LogFile.Write(CadMath.Abstractions.LogLevel.Error, "Initialize failed: " + ex);
            AcApp.DocumentManager.MdiActiveDocument?.Editor.WriteMessage(
                $"\n{ProductInfo.Name} 初始化失败：{ex.Message}（详见 {LogFile.Path}）\n");
        }
    }

    public void Terminate()
    {
        try
        {
            Manager?.Dispose();
        }
        catch
        {
            // 退出路径上不再抛异常。
        }

        Manager = null;
    }
}
