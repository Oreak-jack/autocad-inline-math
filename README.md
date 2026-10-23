# AutoCAD Inline Math

[![tests](https://github.com/Oreak-jack/autocad-inline-math/actions/workflows/tests.yml/badge.svg)](https://github.com/Oreak-jack/autocad-inline-math/actions/workflows/tests.yml)

在 AutoCAD 命令行里直接写算式：`100-30` 回车就是 `70`，`@100-30,0` 就是相对坐标 `@70,0`。
支持长度、角度、坐标等所有"提示输入"的场景，不需要记命令、不需要开计算器、不跳出 CAD。

当前版本 **0.4.7**，支持 AutoCAD 2024 / 2025 / 2026（R24.0 ~ R24.3 / R25.0 / R25.1，均已真机验证）；AutoCAD 2020（R23.1）在 0.4.7 里是**实验性支持**（已编译、安装流程已验证，待真机确认）。用命令行安装器 `CadMath-Setup.cmd` 安装、更新、卸载，见 [docs/INSTALLER.md](docs/INSTALLER.md)。

---

## 0.4.x 与 0.3.3 的关系

0.3.3 是一个 155 行的 `Plugin.cs` 同时兼任程序集入口、命令、键盘拦截、状态机、日志和焦点探测，外加手工打包脚本和一个 470 行、只认全局 `ApplicationPlugins` 的 PowerShell 安装器。能用，但改一处要读全部。

0.4.x 把同样的功能按职责拆开。0.4.0 只做拆分、拿掉安装器；0.4.1 把安装器以**命令行工具 + 按版本注册**的形式接回来；0.4.2 让一套发行包同时容纳两代 CLR 宿主（.NET 8 给 2025/2026，.NET Framework 4.8 给 2024）；0.4.3 把 2024 适配器从 `planned` 提升为 `host-tested`，正式包随之开放 2024；0.4.4 又加了一代 4.8 宿主（编译基准 23.1）给 2020，先以实验状态发布；0.4.5 修掉了方向输入（`<-30`、`@<45`）被误判成坏表达式、以及拒绝时连回车一起吞掉的问题；0.4.6 修掉了"检查更新"在 0.4.5 上必然失败的 `zip` 属性错误（旧清单格式兼容问题）；0.4.7 让菜单 2 把每一步都打出来（连接、版本、下载进度、解压校验、替换注册），不再有一段看起来像卡死的静默期：

| | 0.3.3 | 0.4.7 |
| --- | --- | --- |
| 计算与判定 | `Expression.cs` + `InputPolicy.cs` 被测试工程直接编译 | 独立的 `CadMath.Core` / `CadMath.Abstractions` 程序集 |
| 键盘拦截 | `Plugin.cs` 里所有东西混在一起 | `CadMath.Adapter.Modern`（.NET 8）+ `CadMath.Adapter.Legacy2024` + `CadMath.Adapter.Legacy2020`（后两者 .NET Framework 4.8），共用 `KeystrokeAdapter` |
| 生命周期 / 命令 | 同一个 `Plugin.cs` | `CadMath.Shell`（只有装配与转发） |
| 多版本 | 无 | `adapters.json` + 适配器注册/选择/装载 |
| 安装位置 | 全局 `ApplicationPlugins`，所有 CAD 版本共享 | `%LOCALAPPDATA%` 下的受管负载 + 每个 CAD 版本一条 `HKCU` 注册 |
| 安装器 | WinForms 图形界面，无卸载 | 纯命令行，安装/更新/卸载/回滚 + 事务日志 |

行为上两者逐条对齐：`tests/CadMath.Tests` 里 623 条断言（数学 541 + 路由 50 + 宿主序列/清单/选择 32）与 0.3.3 完全一致。

---

## 目录结构

```
CadMath.sln
Directory.Build.props          版本号的唯一来源（0.4.7）
adapters/adapters.json         适配器清单（随包分发，运行时选择用）
bundle/PackageContents.xml     包描述模板，打包时注入版本
build/build.ps1                一条命令产出 bundle + zip + setup.json + SHA256SUMS.txt
docs/ARCHITECTURE.md           分层设计
docs/IMPLEMENTATION.md         实施记录：职责映射、时序、不变式、验证
docs/INSTALLER.md              命令行安装器：安装位置、匹配规则、事务与回滚
tools/setup/                   命令行安装器（PowerShell 5.1）
  CadMath-Setup.cmd            入口
  CadMath-Setup.ps1            菜单与流程
  lib/                         扫描、清单、注册表、安装/回滚、发行版访问
  tests/Test-Setup.ps1         安装器自动化测试（36 项）
src/
  CadMath.Abstractions/        契约层：PromptKind、Decision/Conversion、ICadAdapter、清单模型、HostSeries、选择算法
  CadMath.Core/                纯计算：表达式求值、坐标转换、输入判定（不引用任何 AutoCAD 程序集）
  CadMath.Shell/               宿主层：程序集入口、CM3* 命令、适配器管理与装载、日志、探测（程序集名仍是 CadMath03.dll）
  CadMath.Adapter.Modern/      R25.x 适配器：拦截命令行、回调 Core、改写输入
  CadMath.Adapter.Legacy/      R24.x 适配器占位（接口已就位，实现待接入）
tests/CadMath.Tests/           控制台测试运行器（不依赖任何测试框架）
```

依赖方向只有一条：

```
Adapter.* ──▶ Abstractions ◀── Core
                   ▲
                Shell ──▶ (acmgd 三件)
```

适配器**不能**引用 `CadMath.Core`：契约（`Conversion`、`PromptKind`）住在 `Abstractions` 里，所以一个适配器只需要引用契约 + 对应版本的 AutoCAD 程序集。这条规则由项目引用结构强制，不靠自觉。

---

## 安装

推荐用安装器（关掉 AutoCAD 后双击 `CadMath-Setup.cmd`，按提示操作）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\CadMath-Setup.ps1
```

它会把负载放到 `%LOCALAPPDATA%\CadMathInlineMath\payload\<版本>`，并给检测到的每个 CAD 版本写一条 `HKCU` 注册，所以每个实例都能独立安装、更新、卸载。细节见 [docs/INSTALLER.md](docs/INSTALLER.md)。

安装时还可以选择另一种方式——装到 `%APPDATA%\Autodesk\ApplicationPlugins\CadMath03.bundle`（所有 CAD 版本共享一份，Autodesk 自动扫描加载）：

```powershell
# 菜单里第 2 个选项；或命令行：
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\CadMath-Setup.ps1 -Install dummy -Mode appplugins -Yes
```

两种方式都存在时**只会同时加载两份插件**（一次按键被处理两遍），所以工具默认用"按版本注册"，并且会把旧的 `ApplicationPlugins` 安装识别为"旧式安装"、建议移到备份再继续。

手动安装仍然可行（等于 0.4.0 的做法）：关闭 AutoCAD → 把 `dist\CadMath03.bundle` 复制到
`%APPDATA%\Autodesk\ApplicationPlugins\CadMath03.bundle` → 启动。

### AutoCAD 2024 / 2020

2024 和 2020 用的都是 **.NET Framework 4.8**，与 2025/2026 的 .NET 8 不兼容，所以包里带了三份宿主：
`Contents/Win64`（.NET 8）、`Contents/Win64-2024`（4.8，编译基准 24.3）与 `Contents/Win64-2020`
（4.8，编译基准 23.1）。安装器按检测到的实例系列选择对应入口，三个版本可以同时装、互不影响。

2024 的适配器（`legacy-r24`）从 0.4.3 起状态是 `host-tested`，正式包直接支持：
在 2024 里装出来的 `LOADER` 指向 `...\payload\0.4.7\Contents\Win64-2024\CadMath03.dll`。

2020 的适配器（`legacy-r23`）在 0.4.7 里状态仍是 `planned`（**实验性**，只做了编译与安装流程验证，
还没有人在真实 AutoCAD 2020 上跑过）。给 2020 机器测试请用实验包 `build\build.ps1 -Experimental`
产出的 `CadMath-InlineMath-0.4.7-experimental.zip`：它把这个适配器临时提升为 `built`，装出来的
`LOADER` 指向 `...\payload\0.4.7\Contents\Win64-2020\CadMath03.dll`。验证通过后把
`adapters/adapters.json` 里 `legacy-r23` 的 `status` 改成 `host-tested` 再发正式版。

想确认当前这台机器上装的是哪一代，在对应版本的 AutoCAD 命令行里跑：

```
CM3PROBE
```

它会打印宿主 release、`clr=`、活动适配器、绑定解析结果与焦点类型（也写进日志）。

如果以后接入更老的版本（2023 及以前）或某个新版本先要在小范围试，仍然可以用实验包：
`build\build.ps1 -Experimental` 会把所有 `planned` 的适配器临时提升为 `built`，产出的包后缀带
`-experimental-<年份>`，装完验证无误后把 `adapters/adapters.json` 里对应适配器的 `status` 改成
`host-tested` 再发正式版。

装好后 AutoCAD 命令行会出现：

```
CadMath 0.4.7 底部命令栏计算已启用。关闭：CM3OFF；状态：CM3STATUS。
```

---

## 命令

| 命令 | 作用 |
| --- | --- |
| `CM3ON` | 重新开启拦截（适配器异常后需要它恢复） |
| `CM3OFF` | 暂停拦截，输入原样交给 CAD |
| `CM3STATUS` | 当前开关、活动适配器、宿主版本、已替换次数、最后一次错误、日志路径 |
| `CM3CHECK` | 读上一次选中 LINE 的长度（核对算式结果是否真的落到几何上） |
| `CM3PROBE` | 打印宿主与适配器诊断（release、acmgd 版本、绑定解析、焦点类型），排查新版本适配问题时用 |

---

## 语法

**标量**：`+ - * /`、括号、一元正负号、小数与科学计数法。

```
100-30         → 70
(1200+800)/3   → 666.666666666667
2*3.5e2        → 700
```

**坐标**：`x,y[,z]` 与 `距离<角度`，每个分量都可以是算式。

```
10+5,20*2      → 15,40
100-30<45      → 70<45
```

**前缀**：`@` 相对、`#` 绝对，写在最前面。

```
@100-30,0      → @70,0        （相对上一点 70,0）
#10*2,5        → #20,5        （绝对 20,5）
```

**方向输入**：`<角度` 是 AutoCAD 原生的"只给角度"写法（距离由橡皮筋补）。`<45`、`@<45`、`#<45` 原样放行；`100<30` 这类带表达式的仍会求值。0.4.5 起不会再被当成坏表达式拦下。
**不参与转换**的情况：空输入、纯数字、AutoLISP 表单（如 `(+ 1 2)`）、含非法字符的文本——原样放行。

**限制**：表达式 ≤ 512 字符、括号/符号嵌套 ≤ 32 层、结果绝对值在 `1e-12 ~ 1e15` 之间或为 0；除零、缺右括号、整数提示下非整数结果都会拦下并提示，不会产生错误几何。

**生效范围**：只对**底部命令行**的提示输入生效（浮动面板、对话框不拦截），且只在下列 15 个命令的提示中出现：

`LINE PLINE CIRCLE ARC RECTANG OFFSET MOVE COPY ROTATE SCALE STRETCH FILLET CHAMFER POLYGON ELLIPSE LENGTHEN`

---

## 构建

前置：.NET SDK 8（自带 `net48` 目标包）。AutoCAD 的托管程序集**不需要**本机安装——两代引用都来自官方 NuGet 包（`AutoCAD.NET` 25.1.0 供 .NET 8、24.3.0 供 .NET Framework 4.8）。

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1

# 实验包：把所有 planned 的适配器临时提升为 built（用于验证尚未开放的版本）
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Experimental
```

产物：

```
dist/CadMath03.bundle/                主包（三代宿主放在同一个包里）
  PackageContents.xml                 包描述（版本已注入，Series R25.0 ~ R25.1）
  BUILD-INFO.txt                      构建时间、配置、版本、各代宿主的说明
  Contents/Win64/                     2025 / 2026 · .NET 8
    CadMath03.dll                     Shell（程序集名沿用旧名）
    CadMath.Core.dll
    CadMath.Abstractions.dll
    adapters.json                     运行时清单（只列 net8 适配器）
    Adapters/CadMath.Adapter.Modern.dll
  Contents/Win64-2024/                2021 ~ 2024 · .NET Framework 4.8（编译基准 24.3）
    CadMath03.dll                     （同一个程序集名，另一代宿主）
    CadMath.Core.dll
    CadMath.Abstractions.dll
    adapters.json                     运行时清单（只列本代适配器）
    Adapters/CadMath.Adapter.Legacy2024.dll
  Contents/Win64-2020/                2020 · .NET Framework 4.8（编译基准 23.1）
    CadMath03.dll
    CadMath.Core.dll
    CadMath.Abstractions.dll
    adapters.json                     运行时清单（只列 legacy-r23）
    Adapters/CadMath.Adapter.Legacy2020.dll
dist/CadMath03-2024.bundle/           2024 专用包（ApplicationPlugins 全局安装用，Series R24.0 ~ R24.3）
dist/CadMath03-2020.bundle/           2020 专用包（同上，Series R23.1）
dist/setup.json                       发行清单：版本、hosts（系列→入口 DLL）、逐文件 SHA-256、适配器状态
dist/tools/setup/                     安装器（随 zip 分发）
dist/CadMath-InlineMath-0.4.7.zip     正式包（-NoZip 可跳过）：三个 bundle + 安装器 + setup.json
dist/experimental/CadMath-InlineMath-0.4.7-experimental.zip
                                      实验包：把 planned 适配器临时提为 built（给 2020 等未验证版本试用）
dist/SHA256SUMS.txt                   zip 的 SHA-256（便于人工核对）
```

版本号只写在 `Directory.Build.props`（`<Version>0.4.7</Version>`），程序和 `PackageContents.xml` 都从那里取；zip 名与 `setup.json` 里的版本也来自同一处。

两个本机会踩的坑，脚本事先规避了：

- PowerShell 5.1 只按 ANSI 读 `.ps1`，中文注释会让脚本直接语法报错 → 脚本必须以 **UTF-8 带 BOM** 保存。
- 机器上可能同时存在"只有运行时、没有 SDK"的 dotnet（`Get-Command dotnet` 会命中它，报 `No .NET SDKs were found`）→ 脚本优先使用 `%USERPROFILE%\.dotnet\dotnet.exe`，并校验 `--list-sdks`。

编译时的 `MSB3277`（acmgd 依赖 AcCustomize / AWindows / AcTcMgd 等私有程序集无法解析）是良性的，不影响加载。

---

## 测试

```powershell
dotnet run --project tests\CadMath.Tests -c Release
# checks=623  failures=0
# PASS  数学/策略/清单/选择 全部通过。
```

- 数学 541 条：含 500 条 `seed=42` 随机表达式，与 0.3.3 逐条对拍（数值按 `0.################` 格式化后比较）。
- 路由 45 条：哪些输入该 Pass / Replace / Reject，以及拒绝时的错误码。
- 适配器 31 条：HostSeries 解析、清单校验（各错误码各一条）、选择排序与排除原因。

测试工程零 NuGet 依赖，直接跑在 `net8.0` 上，CI 不需要 Windows 或 AutoCAD。
真实 CAD 里的行为（拦截、改写、几何落地）不在自动化范围内，靠人工冒烟和 `%TEMP%\CadMath03.log` 核对。

安装器另有 36 项自动化测试（不会动真实安装：临时状态目录 + 假注册表根）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\tests\Test-Setup.ps1
# 通过 36 项，失败 0 项
```

---

## 适配器

`adapters.json` 是唯一入口：

```json
{
  "schemaVersion": 1,
  "adapters": [
    {
      "id": "modern-r25",
      "displayName": "现代适配器（AutoCAD 2025 / 2026）",
      "assembly": "Adapters/CadMath.Adapter.Modern.dll",
      "type": "CadMath.Adapter.Modern.ModernAdapter",
      "series": [ "R25.0", "R25.1" ],
      "priority": 100,
      "verified": true,
      "runtime": "net8.0-windows"
    }
  ]
}
```

选择过程：读清单 → 按宿主版本（`acmgd.dll` 的 `FileVersion`，可用环境变量 `CADMATH_HOST_SERIES` 覆盖）过滤 `series` → 丢弃程序集缺失/越界的项 → 按 `priority` 降序、同优先级按 `id` 序 → 逐个 `TryStart`，第一个成功者生效。被排除的项和原因会写进日志，并在 `CM3STATUS` 里输出。

新增一个 CAD 版本适配器：

1. 建 `src/CadMath.Adapter.<名字>`，**只引用 `CadMath.Abstractions`** 和该版本的 `acmgd/acdbmgd/accoremgd`（推荐直接用官方 NuGet 包，见 `CadMath.Adapter.Legacy2024.csproj`）；
2. 实现 `ICadAdapter`（`Id`、`TryStart(host, token, out error)`、`Stop()`）——如果只是换一代 CAD，最省事的是继承 `src/CadMath.Adapter.Shared/KeystrokeAdapter.cs`（两个适配器共用同一份拦截逻辑，只传一个 `Id`）；
3. 在 `adapters.json` 加一项，`series` 填目标版本；
4. 跑 `build.ps1`，`Adapters/` 下会自动收进新 DLL。

`legacy-r24` 与 `legacy-r23` 都是真实实现：它们链接同一份 `KeystrokeAdapter.cs`，分别用
`AutoCAD.NET 24.3.0` 与 `23.1.0`（.NET Framework 4.8）编译，`UIBindings`/`CommandLineTextBox`/
`ReplaceInputQueue` 这些未文档化的 API 在两代 SDK 里都存在。`legacy-r24` 已在真实 AutoCAD 2024 上
验证通过（`status=host-tested`）；`legacy-r23` 目前只有编译与安装流程的验证（`status=planned`）。

---

## 日志与诊断

- 路径：`%TEMP%\CadMath03.log`（超过 1 MB 停止写入）。
- 关键行：`shell 0.4.7 start; host=R25.1`、`adapter modern-r25 active`、`replacement_requested 100-30 => 70 command=LINE msg=0x100`、`adapter failure, interception disabled`。
- `CM3STATUS` 会输出开关状态、活动适配器、替换次数、最后一次错误、日志路径，以及被排除的适配器及原因。
- 想在没有 CAD 的环境里验证探测逻辑，可设 `CADMATH_HOST_SERIES=R25.1`。
- 在 2024 上排查问题先跑 `CM3PROBE`，它会打印宿主 release、acmgd 版本、适配器、绑定解析结果与焦点类型。

---

## 已知限制

- 只支持底部命令行输入，不支持浮动命令行面板与对话框。
- 适配器抛异常时会**保护性关闭**拦截（fail closed），需手动 `CM3ON`；这样绝不会把错误输入塞进图形。
- 2024 / 2025 / 2026 均已真机验证；2020 在 0.4.7 里是实验性支持（已编译、安装流程已验证，待真机确认）；2021–2023 用的是同一份 24.3 编出来的宿主，按官方兼容表应当可用但同样未逐一实跑。
- 安装器只认 `%LOCALAPPDATA%` 下自己的负载与 `HKCU` 注册；手工放进 `ApplicationPlugins` 的旧式安装会被识别为"旧式"，需要迁移一次才能按版本独立管理。
- 更新只走 GitHub Releases，网络不可用时安装与卸载仍然可用。

## 许可

MIT，见 [LICENSE](LICENSE)。
