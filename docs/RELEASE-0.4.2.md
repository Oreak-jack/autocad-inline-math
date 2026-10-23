# CadMath03 0.4.2 · 一个包，两代 CLR 宿主

这一版把 AutoCAD 2024 拉进了同一个发行包。

2024 是 .NET Framework 4.8，2025/2026 是 .NET 8，一个 DLL 不可能同时被两个运行时加载。做法不是再发一个安装器，
而是在同一个包里放两套宿主，让安装器按实例的 CAD 系列选入口：

```
CadMath03.bundle/Contents/Win64/        .NET 8            → 2025 / 2026
CadMath03.bundle/Contents/Win64-2024/   .NET Framework 4.8 → 2024
CadMath03-2024.bundle/                  2024 专用（全局安装用）
```

## 安装

关掉 AutoCAD，解压，双击 `CadMath-Setup.cmd`：

```
1. 安装 / 修复
2. 检查更新并安装
3. 卸载
4. 退出
```

选 `1` 就会扫描本机的 CAD 实例，按系列匹配适配器，再按系列选宿主入口：2026 写 `Contents\Win64\CadMath03.dll`，
2024 写 `Contents\Win64-2024\CadMath03.dll`。**找不到对应宿主会直接失败并说明原因**，不会把 .NET 8 的程序集塞给 2024。

手动安装（不用工具）也可以：把 `CadMath03.bundle` 整个复制到 `%APPDATA%\Autodesk\ApplicationPlugins\`，
这样只会自动加载 .NET 8 那份，2024 不受影响。

## 2024 是实验状态

`adapters/adapters.json` 里 `legacy-r24` 的 `status` 是 `planned`，所以**正式包不会给 2024 的实例装任何东西**
（安装器会以 `status-planned` 拒绝，并告诉你是哪个实例、为什么）。

原因很直白：2024 的 API 兼容性是编译期结论。用 Autodesk 官方的 `AutoCAD.NET 24.3.0` 编译共享的拦截逻辑一次通过，
`UIBindings.CommandEditorManager.ActiveEditor.PromptAndInput.InputBuffer`、`ReplaceInputQueue`、
`OnSetSelectedTextQueue`、`ViewModel.CommandLine.CommandLineTextBox` 在 24.3 上都在；
但运行期行为（焦点判定、输入队列刷新时机）还没在真实 2024 上跑过。

要给 2024 试用，用同一个 Release 里的实验包：

```
CadMath-InlineMath-0.4.2-experimental-2024.zip
```

它和正式包只差一处：`legacy-r24` 的 `status` 被提升为 `built`。装完在 2024 命令行里跑 `CM3PROBE`，
它会打印 `host=` `clr=` `adapter=` `binding=` 和焦点类型；连同 `%TEMP%\CadMath03.log` 发回来就能判定。
验证通过后把状态改成 `host-tested`，正式包随之开放。

## 本版变化

- `CadMath.Core` / `CadMath.Abstractions` 下调为 **netstandard2.0**，两代 CLR 共用；补 `IsExternalInit` 与自带的 `Json.cs`
  （`System.Text.Json` 在 netstandard2.0 上不可用）
- 拦截逻辑抽到 `src/CadMath.Adapter.Shared/KeystrokeAdapter.cs`，两个适配器各自只剩一个 `Id`
- 新增 `CadMath.Adapter.Legacy2024`（net48），引用官方 NuGet `AutoCAD.NET 24.3.0`
- `CadMath.Shell` 多目标 `net8.0-windows;net48`；net48 用 `Assembly.LoadFrom` + `AssemblyResolve` 共享契约程序集，
  避免同一份 `Conversion` 出现两个类型身份
- 引用全部改走**官方 NuGet**（25.1.0 / 24.3.0），不再需要 `-p:AcadDir`，也不再依赖本机装过 AutoCAD
- `setup.json` 新增 `hosts[]`（系列 → 入口 DLL + 运行时），`files[]` 覆盖两个 bundle
- 安装器：按实例系列选 `LOADER`、找不到宿主直接失败、`-AllowExperimental`、全局模式部署两份 bundle
- 构建 `-Experimental` 把 `legacy-r24` 从 `planned` 提升为 `built`，产出实验包
- 新增 `CM3PROBE` 诊断命令

## 交付物校验

```
ef91b74949e801be65c59bc7d43cac78d09429808fe415348c35ce93bb12a37d  CadMath-InlineMath-0.4.2.zip
9bc6ea276a3a9f631f22a58353c1a6b521caaf4323089bc849643a47e27f0293  CadMath-InlineMath-0.4.2-experimental-2024.zip
```

PowerShell：

```powershell
Get-FileHash .\CadMath-InlineMath-0.4.2.zip -Algorithm SHA256
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `CM3ON` | 重新开启（适配器故障关闭后用它恢复） |
| `CM3OFF` | 关闭 |
| `CM3STATUS` | 开关状态、活动适配器、替换次数、最后错误、日志路径 |
| `CM3CHECK` | 读上一次选中 LINE 的长度 |
| `CM3PROBE` | 宿主与适配器诊断（release、acmgd 版本、绑定解析、焦点类型） |

## 支持的写法

在底部命令行需要输入数值的地方，`100-30` 会变成 `70`。坐标、距离、角度、整数都能用：

```
100-30
(1200+800)/3
10+5,20*2          → 15,40
100-30<45          → 70<45
@100-30,0          → @70,0
#10*2,5            → #20,5
```

长度上限 512 字符、括号嵌套 32 层、结果需在 `1e-15` 到 `1e15` 之间。

## 已知限制

- 2025/2026 已真机验证；**2024 只有实验包**，见上
- 命令名（`LINE`、`CIRCLE` 等 15 个）目前是适配器里的白名单
- 只支持底部命令行，不支持浮动命令行与国际化
- 一次按键只处理一次（`msg=0x100` 单条日志）；如果看到成对的两条，说明同时加载了两份插件

## 完整变更

https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.1...v0.4.2
