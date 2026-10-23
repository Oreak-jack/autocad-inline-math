# AutoCAD Inline Math

在 AutoCAD 命令行里直接写算式：`100-30` 回车就是 `70`，`@100-30,0` 就是相对坐标 `@70,0`。
支持长度、角度、坐标等所有"提示输入"的场景，不需要记命令、不需要开计算器、不跳出 CAD。

当前版本 **0.4.0**，支持 AutoCAD 2025 / 2026（R25.0 / R25.1）。

---

## 0.4.0 与 0.3.3 的关系

0.3.3 是一个 155 行的 `Plugin.cs` 同时兼任程序集入口、命令、键盘拦截、状态机、日志和焦点探测，外加手工打包脚本和一个 470 行的 PowerShell 安装器。能用，但改一处要读全部。

0.4.0 把同样的功能按职责拆开，并且**先去掉安装器**（下一阶段再加回来）：

| | 0.3.3 | 0.4.0 |
| --- | --- | --- |
| 计算与判定 | `Expression.cs` + `InputPolicy.cs` 被测试工程直接编译 | 独立的 `CadMath.Core` / `CadMath.Abstractions` 程序集 |
| 键盘拦截 | `Plugin.cs` 里所有东西混在一起 | `CadMath.Adapter.Modern`（唯一接触 AutoCAD 输入管线的模块） |
| 生命周期 / 命令 | 同一个 `Plugin.cs` | `CadMath.Shell`（只有装配与转发） |
| 多版本 | 无 | `adapters.json` + 适配器注册/选择/装载 |
| 分发 | 安装器 | 复制 `CadMath03.bundle` 到一个目录 |

行为上两者逐条对齐：`tests/CadMath.Tests` 里 617 条断言（数学 541 + 路由 45 + 宿主序列/清单/选择 31）与 0.3.3 完全一致。

---

## 目录结构

```
CadMath.sln
Directory.Build.props          版本号的唯一来源（0.4.0）
adapters/adapters.json         适配器清单（随包分发）
bundle/PackageContents.xml     包描述模板，打包时注入版本
build/build.ps1                一条命令产出 bundle + zip
docs/ARCHITECTURE.md           分层设计（计划版）
docs/IMPLEMENTATION.md         实施记录：职责映射、时序、不变式、验证
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

## 安装（免安装器）

AutoCAD 会在启动时扫描 `%APPDATA%\Autodesk\ApplicationPlugins` 下的 `*.bundle` 目录，所以"安装"就是复制目录：

1. 关闭所有 AutoCAD（bundle 只在启动时被扫描）。
2. 把 `dist\CadMath03.bundle` 整个目录复制到
   `C:\Users\<你>\AppData\Roaming\Autodesk\ApplicationPlugins\CadMath03.bundle`。
3. 启动 AutoCAD，命令行出现
   `CadMath 0.4.0 底部命令栏计算已启用。关闭：CM3OFF；状态：CM3STATUS。`

卸载 = 关闭 CAD 后删除该目录。旧版 0.3.3 也装在这里时，直接覆盖同名目录即可（ProductCode / UpgradeCode 未变，升级路径连续）。

---

## 命令

| 命令 | 作用 |
| --- | --- |
| `CM3ON` | 重新开启拦截（适配器异常后需要它恢复） |
| `CM3OFF` | 暂停拦截，输入原样交给 CAD |
| `CM3STATUS` | 当前开关、活动适配器、宿主版本、已替换次数、最后一次错误、日志路径 |
| `CM3CHECK` | 读上一次选中 LINE 的长度（核对算式结果是否真的落到几何上） |

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

**不参与转换**的情况：空输入、纯数字、AutoLISP 表单（如 `(+ 1 2)`）、含非法字符的文本——原样放行。

**限制**：表达式 ≤ 512 字符、括号/符号嵌套 ≤ 32 层、结果绝对值在 `1e-12 ~ 1e15` 之间或为 0；除零、缺右括号、整数提示下非整数结果都会拦下并提示，不会产生错误几何。

**生效范围**：只对**底部命令行**的提示输入生效（浮动面板、对话框不拦截），且只在下列 15 个命令的提示中出现：

`LINE PLINE CIRCLE ARC RECTANG OFFSET MOVE COPY ROTATE SCALE STRETCH FILLET CHAMFER POLYGON ELLIPSE LENGTHEN`

---

## 构建

前置：.NET SDK 8，以及 AutoCAD 2025/2026 的托管程序集。

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1 -AcadDir "D:\AutoCAD 2026"
```

产物：

```
dist/CadMath03.bundle/                可直接复制的包
  Contents/Win64/
    CadMath03.dll                     Shell（程序集名沿用旧名）
    CadMath.Core.dll
    CadMath.Abstractions.dll
    adapters.json
    Adapters/CadMath.Adapter.Modern.dll
    Adapters/CadMath.Adapter.Legacy.dll
    PackageContents.xml
    BUILD-INFO.txt
  PackageContents.xml
dist/CadMath-InlineMath-0.4.0.zip     压缩包（-NoZip 可跳过）
```

版本号只写在 `Directory.Build.props`（`<Version>0.4.0</Version>`），程序和 `PackageContents.xml` 都从那里取。

两个本机会踩的坑，脚本事先规避了：

- PowerShell 5.1 只按 ANSI 读 `.ps1`，中文注释会让脚本直接语法报错 → 脚本必须以 **UTF-8 带 BOM** 保存。
- 机器上可能同时存在"只有运行时、没有 SDK"的 dotnet（`Get-Command dotnet` 会命中它，报 `No .NET SDKs were found`）→ 脚本优先使用 `%USERPROFILE%\.dotnet\dotnet.exe`，并校验 `--list-sdks`。

编译时的 `MSB3277`（acmgd 依赖 AcCustomize / AWindows / AcTcMgd 等私有程序集无法解析）是良性的，不影响加载。

---

## 测试

```powershell
dotnet run --project tests\CadMath.Tests -c Release
# checks=617  failures=0
# PASS  数学/策略/清单/选择 全部通过。
```

- 数学 541 条：含 500 条 `seed=42` 随机表达式，与 0.3.3 逐条对拍（数值按 `0.################` 格式化后比较）。
- 路由 45 条：哪些输入该 Pass / Replace / Reject，以及拒绝时的错误码。
- 适配器 31 条：HostSeries 解析、清单校验（各错误码各一条）、选择排序与排除原因。

测试工程零 NuGet 依赖，直接跑在 `net8.0` 上，CI 不需要 Windows 或 AutoCAD。
真实 CAD 里的行为（拦截、改写、几何落地）不在自动化范围内，靠人工冒烟和 `%TEMP%\CadMath03.log` 核对。

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

1. 建 `src/CadMath.Adapter.<名字>`，**只引用 `CadMath.Abstractions`** 和该版本的 `acmgd/acdbmgd/accoremgd`；
2. 实现 `ICadAdapter`（`Id`、`TryStart(host, token, out error)`、`Stop()`），把宿主事件翻译成 `SubmitRequest(PromptKind, command, text)` 交给 `host.Evaluate`；
3. 在 `adapters.json` 加一项，`series` 填目标版本；
4. 跑 `build.ps1`，`Adapters/` 下会自动收进新 DLL。

`legacy-r24` 是占位实现：接口、清单、装载都已打通，`TryStart` 直接返回"尚未实现"，所以在 2024 上会显示"未启用：…"而不会崩。

---

## 日志与诊断

- 路径：`%TEMP%\CadMath03.log`（超过 1 MB 停止写入）。
- 关键行：`shell 0.4.0 start; host=R25.1`、`adapter modern-r25 active`、`replacement_requested 100-30 => 70 command=LINE msg=0x100`、`adapter failure, interception disabled`。
- `CM3STATUS` 会输出开关状态、活动适配器、替换次数、最后一次错误、日志路径，以及被排除的适配器及原因。
- 想在没有 CAD 的环境里验证探测逻辑，可设 `CADMATH_HOST_SERIES=R25.1`。

---

## 已知限制

- 只支持底部命令行输入，不支持浮动命令行面板与对话框。
- 适配器抛异常时会**保护性关闭**拦截（fail closed），需手动 `CM3ON`；这样绝不会把错误输入塞进图形。
- 真实适配器目前只有 R25.x；2024 及更早只有占位。
- 安装器（安装/升级/卸载/回滚、注册表与受信任路径处理）不属于 0.4.0，下一阶段接回来。

## 许可

MIT，见 [LICENSE](LICENSE)。
