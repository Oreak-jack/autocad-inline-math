# 实施记录：0.3.3 → 0.4.1

这份文档回答四个问题：原来那些代码去了哪、新架构怎么跑起来、哪些对外行为绝对不能变、以及怎么证明它没变。
设计意图见 [ARCHITECTURE.md](ARCHITECTURE.md)（计划版，部分命名在实施时做了调整，以本文为准）。

---

## 1. 职责映射

### 1.1 `src/Plugin.cs`（155 行，一个类干全部事）

| 0.3.3 里的职责 | 0.4.0 位置 |
| --- | --- |
| `[assembly: ExtensionApplication]` / `[assembly: CommandClass]` | `src/CadMath.Shell/ShellApplication.cs` |
| `Initialize` / `Terminate` | `ShellApplication.Initialize` / `Terminate`（只剩装配与转发） |
| `CM3ON` / `CM3OFF` / `CM3STATUS` / `CM3CHECK` 四个 `[CommandMethod]` | `src/CadMath.Shell/ShellCommands.cs` |
| `Dictionary<Document, Hooks>` 多文档状态 | `src/CadMath.Adapter.Modern/ModernAdapter.cs` 内嵌 `PromptHooks`（每文档一对事件订阅） |
| `AcApp.PreTranslateMessage` 拦截 + 按键过滤 | `ModernAdapter` 的消息处理器 |
| `Begin` / `End` 提示态状态机 | `PromptHooks` 对 `PromptingForPoint/Corner/Distance/Double/Angle/Integer` 与 `PromptingForString/Keyword/Selection/Entity/Nested/EnteringQuiescentState/CommandEnded/Cancelled/Failed` 的订阅 |
| `AllowedFocus` / `IsPromptingForCommandName` | `ModernAdapter` 私有方法，逻辑逐行保留 |
| `InputPolicy.Convert` 调用 | `AdapterManager.Evaluate` → `InputTranslator.Translate` |
| 日志写入与 1 MB 上限 | `src/CadMath.Shell/LogFile.cs` |
| `enabled` 布尔 + 异常时 `enabled=false` | `AdapterManager.Enabled` + `HandleAdapterFailure` |

### 1.2 `src/Expression.cs`（命名空间 `CadMath`）

| 原成员 | 新位置 |
| --- | --- |
| `Evaluate(string)`（递归下降） | `src/CadMath.Core/ExpressionParser.cs` |
| `Format(double)`（`"0.################"`，InvariantCulture） | `src/CadMath.Core/NumberFormat.cs` |
| `ConvertInput(string, bool point, bool integer)` | `src/CadMath.Core/CoordinateInput.cs`（`Convert(string, PromptKind)`） |
| 长度 / 深度 / 量级限制常量 | `InputLimits`（512 / 32 / 1e15 / 1e-12） |
| 抛出 `FormatException` | `ExpressionException : FormatException`，带稳定错误码（`ErrorCodes`） |

### 1.3 `src/InputPolicy.cs`（命名空间 `CadMath03`）

| 原成员 | 新位置 |
| --- | --- |
| `Decision { Pass, Replace, Reject }` | `src/CadMath.Abstractions/Conversion.cs` |
| `Conversion(Decision, Value, Error)` | `Conversion(Decision, Value, Code, Message)` —— 拆成机器可读码 + 人读信息 |
| `Convert` 里的前置过滤（空、无运算符、LISP 表单、非法字符、纯数字、超长） | `src/CadMath.Core/InputTranslator.cs` `Translate` |

关键差异只有一个：0.3.3 把错误文本塞进 `Error`，0.4.0 拆成 `Code`（诊断/测试用）与 `Message`（日志用），仍然不直接拼进 CAD 命令行。

### 1.4 其他

| 0.3.3 | 0.4.0 |
| --- | --- |
| `tests/Tests.csproj` 用 `<Compile Include="../src/*.cs">` 把源码编进测试 | `tests/CadMath.Tests` 用 `ProjectReference`，物理边界成立 |
| 手工 `Compress-Archive` + 手写 `SHA256SUMS.txt` | `build/build.ps1` 一条命令出 bundle 与 zip |
| `installer/`（`Install.ps1` 210 行 WinForms + `Install-Core.ps1` 259 行） | 0.4.0 拿掉；0.4.1 以 `tools/setup/` 命令行安装器接回（见第 7 节） |
| 版本号写在 4 处（csproj、PackageContents 两处、README） | `Directory.Build.props` 唯一来源，打包时注入 XML |
| `startup/CadMath03-Startup.lsp`（`.NETLOAD`） | 不需要：bundle 的 `LoadOnAutoCADStartup=True` 已负责加载 |

---

## 2. 运行时

### 2.1 启动

```
AutoCAD 扫描 ApplicationPlugins → 加载 Contents/Win64/CadMath03.dll
  └─ ShellApplication.Initialize
       ├─ new AdapterManager(LogFile.Sink)
       ├─ AdapterManager.Start()
       │    ├─ HostProbe.Detect()          → acmgd.dll 的 FileVersion → HostSeries(25,1)
       │    │                                 （环境变量 CADMATH_HOST_SERIES 优先，便于无 CAD 调试）
       │    ├─ 读 Shell 目录下 adapters.json → AdapterManifestReader.Parse
       │    ├─ AdapterSelector.Select(清单, 宿主, AssemblyExists)
       │    │     · series 不匹配 → series-mismatch
       │    │     · 程序集不存在或越出 bundle 目录 → missing-assembly / path-escapes
       │    │     · 按 priority 降序、同优先级按 id 序
       │    ├─ 逐个 TryActivate：新建 AdapterLoadContext → 加载程序集 → 按 type 找类型
       │    │     · 不是 ICadAdapter / Id 与清单不符 → load-failed / missing-type / id-mismatch
       │    │     · TryStart 返回 false → start-failed，继续下一个候选
       │    └─ 成功 → Active、Enabled=true
       └─ 命令行输出 "CadMath 0.4.1 底部命令栏计算已启用…" 或 "未启用：<原因>"
```

装载上下文（`AdapterManager.AdapterLoadContext`）的关键点：

- 每个适配器一个可卸载 `AssemblyLoadContext`，`Unload` 在 `Dispose` 时调用——为将来"热替换适配器"留路。
- `Load` 覆写把 `CadMath.Abstractions` 与 `CadMath.Core` 解析到**默认上下文已加载的那一份**，其余交回默认上下文。不这样做，适配器会各自加载一份契约程序集，`ICadAdapter` 的类型身份不一致，`is ICadAdapter` 恒为 false。
- `CadMath.Core` 之所以也要共享：Shell 已经引用它并调用了 `InputTranslator`，两份会引发同样的类型身份问题。

### 2.2 一次按键

```
PreTranslateMessage(msg)
  ├─ msg 必须是 WM_KEYDOWN(0x100) 或 WM_CHAR(0x102)，wParam 必须是 13(Enter) 或 32(Space)
  ├─ 若是 0x100：先清空 _consumedKeyDownKey（标记绝不跨按键残留）
  ├─ 若是 0x102 且 key == _consumedKeyDownKey：直接放行（本按键已处理过）
  ├─ 上下文文档 == MdiActiveDocument，且上下文命令 == 当前 Command()
  ├─ AllowedFocus()：焦点必须是底部命令行的 CommandLineTextBox
  │     其它 WPF TextBox 一律 false；取不到时退回 GetFocus/IsChild
  ├─ 正在提示命令名时跳过
  ├─ 读 PromptAndInput.InputBuffer
  ├─ host.Evaluate(new SubmitRequest(kind, command, text))
  │     └─ InputTranslator.Translate（纯函数，无 CAD 依赖）
  ├─ Pass    → 什么都不做，原按键继续
  ├─ Replace → ReplaceInputQueue(值) + OnSetSelectedTextQueue(长度,长度) + 标记已消费 + 记日志
  └─ Reject  → e.Handled = true + 系统提示音 + 标记已消费 + 记日志
       任何异常 → host.OnFailure → AdapterManager 关闭拦截（fail closed）
```

**为什么要有 `_consumedKeyDownKey`**：同一次回车会先来 `WM_KEYDOWN`、再来 `WM_CHAR`；`ReplaceInputQueue` 要到消息循环才改 `buffer.Text`，于是第二条消息读到的还是旧文本，会再改写一次（0.3.3 的日志里成对的 `replacement_requested` 就是这个）。现在的规则是"一个 KeyDown 只处理一次，同键的后续 WM_CHAR 直接放行"，既不依赖时间窗，也不会误吞下一次回车。

---

## 3. 不变式（改动时必须保持）

对外契约：

- 程序集名 `CadMath03.dll`；bundle 目录名 `CadMath03.bundle`。
- 命令 `CM3ON` / `CM3OFF` / `CM3STATUS` / `CM3CHECK`。
- 日志路径 `%TEMP%\CadMath03.log`，超过 1 MB 停止写入。
- `PackageContents.xml`：`ProductCode {04913737-F911-4978-9F6B-2DB24F3DCC03}`、`UpgradeCode {0937D725-1309-48F0-A258-BC54916D174A}`、`SeriesMin/Max` = `R25.0`/`R25.1`、`LoadOnAutoCADStartup=True`、ModuleName `./Contents/Win64/CadMath03.dll`。这些一变，老用户升级就会并存两套或直接失效。

行为：

- 只在**底部命令行**、只在 15 个命令的提示里生效：`LINE PLINE CIRCLE ARC RECTANG OFFSET MOVE COPY ROTATE SCALE STRETCH FILLET CHAMFER POLYGON ELLIPSE LENGTHEN`。
- 只对 `Enter` / `Space` 触发；空输入、纯数字、LISP 表单、含非法字符的文本一律 `Pass`（原样放行），不是拒绝。
- 成功结果按 `"0.################"` + InvariantCulture 格式化；结果是替换输入缓冲区，不是执行命令。
- 适配器异常 = 关闭拦截，需 `CM3ON` 恢复（宁可不算，也不能画错）。
- 版本号只有一个来源：`Directory.Build.props`。

---

## 4. 决策与理由

**先去掉安装器。** 0.3.3 的仓库里安装器（470 行 PowerShell + WinForms 自绘 UI + 50 项测试）体量和插件本身相当，而它解决的只是"把 bundle 复制到一个固定目录"。AutoCAD 原生就会扫描 `%APPDATA%\Autodesk\ApplicationPlugins`，所以这一版直接用目录分发：可维护性先上去，安装器等接口稳定后作为独立产品回来（`PackageContents.xml` 与目录结构已经为它留好了形状）。

**契约独立成程序集，且不被 Core 依赖方向垄断。** 一开始 `Conversion`/`PromptKind` 放在 Core 里，结果适配器虽然只写了 `ProjectReference` 到 Abstractions，却因为传递引用照样能 `using CadMath.Core`——"适配器不碰引擎"这条规则没有任何东西在保证。把这两个类型移进 Abstractions、让 Core 反过来依赖 Abstractions 之后，依赖方向变成 `Core → Abstractions ← Adapter`，编译期就能挡住越界。代价是 Abstractions 里多了两个值类型，收益是规则可执行。

**数学与判定代码照搬，不重写。** 0.3.3 的递归下降求值器和输入策略已经在真实图纸上用了很久，重写只会带来"看起来一样、边界不一样"的风险。做法是原样迁移，再把 541 条数学断言 + 45 条路由断言逐条对拍，用测试证明等价，而不是用肉眼。

**自己写测试运行器，不引 xunit。** 0.3.3 就是这样：`net8.0` 控制台，退出码即结果，CI 在 ubuntu 上跑，不需要 Windows、AutoCAD 或任何 NuGet 包。对 600 条纯函数用例，框架带来的只有依赖和启动开销。

**自定义 `AssemblyLoadContext`。** 适配器将来会按 CAD 版本各自编译，可能需要并存、卸载、版本隔离；默认上下文做不到卸载。同时必须共享契约程序集，否则类型身份会分裂——这两件事一起构成了适配器装载层。

---

## 5. 验证记录（2026-10-23，AutoCAD 2026 / R25.1）

| 项目 | 命令 / 做法 | 结果 |
| --- | --- | --- |
| 编译 | `dotnet build CadMath.sln -c Release -p:AcadDir="D:\AutoCAD 2026"` | 0 错误（`MSB3277` 为 acmgd 私有依赖告警，良性） |
| 单元/对拍 | `dotnet run --project tests/CadMath.Tests -c Release` | `checks=617 failures=0` |
| 装载 | 复制 bundle 到 ApplicationPlugins 后启动 CAD | 日志 `shell 0.4.0 start; host=R25.1` → `adapter modern-r25 active` |
| 改写 | LINE 提示下输入 `@100-30,0` | 日志单条 `replacement_requested @100-30,0 => @70,0 command=LINE msg=0x100` |
| 几何 | CIRCLE 半径输入 `100-30`，选中后看特性面板 | 半径 **70**、直径 140、周长 439.823 |
| 去重 | 同一次回车 | 只产生一条替换日志（修复前是两条，间隔约 3 ms） |
| 文件安全 | 测试图形 `D:\AutoCAD 2026\A4图框.dwg` | 全程不保存，`LastWriteTime` 保持 `05/10/2026 09:43:55` |

验证用的输入都来自命令行模拟按键（`WScript.Shell.SendKeys`），不涉及脚本文件；含双引号的字符串会被 `SendKeys` 拒绝（`ArgumentException`），所以几何核对改看特性面板而不是回读文件。

上表是 0.4.0 的实测记录。0.4.1 只新增安装器与 `setup.json`，计算层、拦截适配器与命令行为都没有改动，因此 `checks=617` 仍是同一套基准。

---

## 6. 遗留

- **R24 适配器**：`legacy-r24` 在 0.4.2 落地为真实实现（`KeystrokeAdapter` 共享源码 + `AutoCAD.NET 24.3.0`），0.4.3 在真实 AutoCAD 2024 上验证通过，状态为 `host-tested`。它需要 net48 宿主与单独的入口目录（`Contents/Win64-2024`），不能靠改版本号复用。
- **面板输入**：目前只认底部命令行。要支持浮动命令行，需要识别 `Autodesk.AutoCAD.Windows.Palette` 里的编辑框，属于新适配器能力，不是 Shell 的事。
- **去重策略的边界**：依赖 `WM_KEYDOWN` 先于 `WM_CHAR` 到达。若某个版本顺序不同，`_consumedKeyDownKey` 不会命中，表现为重复改写——日志里成对的 `replacement_requested` 就是信号，应优先查这里。
- **构建区间匹配**：`setup.json` 的 `buildRange` 留空，只按版本系列匹配；等有实测可用区间再填，填了就比 `planned` 更严格。
- **CI**：`.github/workflows/tests.yml` 只跑计算层测试（Linux）；Windows 上的编译（需要 Autodesk 程序集）仍是本地脚本。

---

## 7. 0.4.1：安装器

### 7.1 旧安装器的职责去了哪

| 0.3.3 `installer/Install-Core.ps1` | 0.4.1 位置 |
| --- | --- |
| `Get-CadProducts`（只认 R25.0/R25.1） | `tools/setup/lib/Environment.ps1` `Invoke-EnvironmentScan`（枚举 `HKCU` 全部 `R2x.y` 产品，全部可用） |
| `Assert-CadClosed` | `lib/Common.ps1` `Assert-CadClosed`（测试可用 `CADMATH_SETUP_ALLOW_CAD_RUNNING=1` 绕过） |
| `Get-BundleInfo`（bundle 版本三方一致校验） | `lib/Common.ps1` `Get-BundleInfo`（保留同样的校验） |
| `Expand-CadArchive`（zip 安全解压） | `lib/Common.ps1` `Expand-CadBundleArchive`（条目数/体积上限、拒绝越界与符号链接） |
| `Test-ArchiveHash` | `lib/Common.ps1` `Test-FileSha256` + `lib/Install.ps1` `Test-BundleFiles`（逐文件校验） |
| `Get/Set-CadRegistration`（全局 `ApplicationPlugins` + `TRUSTEDPATHS` + `Appload` 迁移） | `lib/Registry.ps1`（按版本写 `Applications\CadMathInlineMath` + 精确维护 `TRUSTEDPATHS`，不再迁移 `Appload`） |
| `Install-CadBundle`（快照 → 暂存 → 复制 → 出错回滚） | `lib/Install.ps1` `Install-CadMathPackage`（额外：`pending.json` journal、逐实例匹配、回滚后验证） |
| `Install.ps1`（WinForms 界面、Timer 轮询下载） | `tools/setup/CadMath-Setup.ps1`（命令行菜单 + `lib/Release.ps1` 同步下载） |
| 无 | `Uninstall-CadMathInstances` + `Remove-InstanceRegistration`（旧版没有卸载） |

### 7.2 部署位置

- 负载：`%LOCALAPPDATA%\CadMathInlineMath\payload\<版本>\`（整份 bundle 内容）
- 注册：`HKCU\Software\Autodesk\AutoCAD\<release>\<product>\Applications\CadMathInlineMath`
  （`LOADER` 指向 payload 里的 `CadMath03.dll`，`LOADCTRLS=2`，`MANAGED=1`）
- 受信任路径：每个配置的 `Variables\TRUSTEDPATHS` 追加 `...\Contents\Win64` 与 `...\Contents\Win64\Adapters`

选这条路的原因：`%APPDATA%\Autodesk\ApplicationPlugins` 的 bundle 是**所有 CAD 版本共享**的，无法按实例升级或卸载；按版本注册才能做到"每个实例独立"，而且全在 `HKCU`，不需要管理员。

### 7.3 验证记录（2026-10-23）

| 项目 | 做法 | 结果 |
| --- | --- | --- |
| 清单 | `Read-SetupManifest dist\setup.json` | 8 个文件、`modern-r25=host-tested`、`legacy-r24=planned` |
| 匹配 | 假实例 2024 / 2026 | 2024 → `legacy-r24`（`host-tested`）；2026 → `modern-r25`；未开放的版本仍以 `status-planned` 拒绝 |
| 安装 | 隔离状态根 + 假注册表，`-Install <实例> -Yes` | 退出码 0，注册项/负载/`state.json`/`TRUSTEDPATHS` 全部正确 |
| 幂等 | 重复安装同一版本 | 视为修复，退出码 0 |
| 回滚 | `CADMATH_SETUP_INJECT_FAILURE=register` | 退出码 3，日志 `已恢复安装前的注册表与负载状态`，旧安装完好、`pending.json` 不存在 |
| 崩溃恢复 | 手工造 journal + 挪走旧负载 | `Restore-PendingTransaction` 恢复版本与负载，journal 清除 |
| 卸载 | `-Remove <实例>` | 注册项消失、`TRUSTEDPATHS` 回到原值、无实例引用时删 payload |
| 安全 | CAD 运行中 | 拒绝安装并提示关闭 CAD |
| 全部用例 | `tools\setup\tests\Test-Setup.ps1` | **通过 33 项，失败 0 项** |
