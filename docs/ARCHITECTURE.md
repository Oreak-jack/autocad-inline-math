# CadMath 架构（重写版）

目标：把 v0.3.3 的单文件插件拆成"计算引擎 / 适配器契约 / 宿主外壳 / 版本适配器"四层，
让数学逻辑和 AutoCAD API 互不越界，把"能不能改"的问题先解决掉。安装器不在本次范围内。

对应你给的分层图：

```
        ┌──────────────────────────────────────────────┐
        │  CadMath.Abstractions  契约层                │  纯 .NET，零依赖
        │  PromptKind / Conversion / ICadAdapter        │  选择算法可单测
        │  清单模型 / HostSeries                        │
        └───────────────────▲──────────────────────────┘
                            │ 只有它被两边引用
        ┌───────────────────┴──────────────────────────┐
        │  CadMath.Core     统一计算引擎               │  纯 .NET
        │  表达式解析 / 坐标输入 / 判定策略 / 错误码    │  100% 可单测
        └──────────────────────────────────────────────┘

   ┌─────────────────────────────────────────────────────┐
   │ Adapter Manager（CadMath.Shell 内）                 │  引用 Core + Abstractions
   │ 读清单 → 识别 CAD → 匹配适配器 → 检查兼容性 → 装载   │  + acmgd（仅为入口/命令）
   └───────┬─────────────────────────────┬───────────────┘
           │                             │
   ┌───────▼──────────────┐      ┌───────▼──────────────┐
   │ 现代适配器 2025/2026 │      │ 旧版适配器 2024-     │
   │ PreTranslateMessage  │      │ （预留，先不实现）    │
   │ UIBindings 输入缓冲  │      │ 不同 API，独立装载    │
   └──────────────────────┘      └──────────────────────┘
```

> 实施时的一处修正：契约类型（`Conversion`、`PromptKind`）原本放在 Core 里，
> 但那样适配器会通过传递引用间接依赖引擎，"适配器不碰数学"就只是口头约定。
> 现在它们住在 Abstractions 里，Core 反过来依赖 Abstractions，规则由编译期保证。

## 1. 依赖方向（硬规则）

```
CadMath.Adapter.*  ─┐
                    ├─▶  CadMath.Abstractions  ◀─  CadMath.Core
CadMath.Shell  ─────┘        (零依赖)               (只依赖 Abstractions)

CadMath.Shell 另引用 acmgd/accoremgd/acdbmgd，只用于 IExtensionApplication 与 CM3* 命令
CadMath.Adapter.Modern 另引用 acmgd（需要拦消息与读输入缓冲区）
```

- `CadMath.Core` 里出现 `Autodesk.*` 或 `System.Windows.*` 就是设计错误。
- 适配器**不引用** `CadMath.Core`，只引用契约：它把"用户按了回车"这件事报给宿主，
  自己不做数学判断。这样适配器只剩"读缓冲区 / 写缓冲区 / 认提示类型"三件事。
- 只有适配器允许出现 `Autodesk.AutoCAD.*`、`user32.dll`、WPF 焦点类型。

## 2. 各层职责

| 层 | 做 | 绝不做 |
|---|---|---|
| Core | 解析、求值、格式化、判定、错误码 | 任何 I/O、日志、AutoCAD 类型 |
| Abstractions | 适配器接口、清单模型、版本区间、选择算法 | 装载程序集、读注册表、读写文件 |
| Shell | 启动/卸载、读清单、探测宿主、装载适配器、命令、日志 | 解析表达式、直接摸命令行缓冲区 |
| Adapter | 提示事件 → PromptKind、按键拦截、缓冲区读写、焦点判定 | 数学、策略、日志格式、配置 |

## 3. 适配器契约

```csharp
public enum PromptKind { Point, Distance, Double, Angle, Integer, Other }

public sealed record SubmitRequest(PromptKind Kind, string Command, string Text);
public readonly record struct Conversion(Decision Decision, string Value, string? Code, string? Message);

public interface IAdapterHost
{
    Conversion Evaluate(SubmitRequest request);   // Shell 转手给 Core
    bool Enabled { get; }
    void Report(LogLevel level, string message);  // Shell 决定落盘
    void OnFailure(Exception ex);                 // 适配器自毁时上报，Shell 负责保护性关闭
}

public interface ICadAdapter
{
    string Id { get; }
    bool TryStart(IAdapterHost host, CancellationToken ct, out string? error);
    void Stop();
}
```

**线程契约**：`TryStart` 与所有回调都在 AutoCAD 主线程；`Evaluate` 必须同步返回，
`PreTranslateMessage` 频率可达每秒数百次，实现里不得做文件 I/O。

## 4. 适配器注册表（`adapters.json`）

随 bundle 发布，Shell 从**自身所在目录**（`Contents/Win64/`）读取；其中 `assembly`
是相对该目录的路径，越出 bundle 的路径会被拒绝。宿主版本可用
`CADMATH_HOST_SERIES` 环境变量覆盖（无 CAD 调试用）。

```json
{
  "schemaVersion": 1,
  "adapters": [
    {
      "id": "modern-r25",
      "displayName": "现代适配器（AutoCAD 2025 / 2026）",
      "assembly": "Adapters/CadMath.Adapter.Modern.dll",
      "type": "CadMath.Adapter.Modern.ModernAdapter",
      "series": ["R25.0", "R25.1"],
      "priority": 100,
      "verified": true,
      "runtime": "net8.0-windows"
    },
    {
      "id": "legacy-r24",
      "displayName": "旧版适配器（AutoCAD 2024 及更早，待接入）",
      "assembly": "Adapters/CadMath.Adapter.Legacy.dll",
      "type": "CadMath.Adapter.Legacy.LegacyAdapter",
      "series": ["R24.0", "R24.1", "R24.2", "R24.3"],
      "priority": 50,
      "verified": false,
      "runtime": "net8.0"
    }
  ]
}
```

字段语义：

- `series`：`acmgd.dll` 的**主次版本**（25.1 → `R25.1`），不是年份。2025=R25.0，2026=R25.1。
- `priority`：同一次匹配里数字大的先试；全部失败才算"无适配器"。
- `verified`：只在 `CM3STATUS` 里显示"已验证 / 未验证"，不参与选择——避免"未验证"变成不可用。
- `runtime`：记录该适配器编译目标，仅作诊断，装载失败时给出可读原因。

## 5. 选择算法（`AdapterSelector`，纯函数，可单测）

```
输入：manifest[], hostSeries, 程序集是否存在
1. 过滤 series 不含 hostSeries 的项      → 原因 series-mismatch
2. 过滤程序集缺失或路径越出 bundle 的项  → missing-assembly / path-escapes
3. 按 priority 降序、同优先级按 id 序
4. 依次 TryStart，失败记录原因后试下一个  → load-failed / missing-type / id-mismatch / start-failed
5. 全部失败 → 无适配器状态：插件加载成功但拦截关闭，CM3STATUS 给出原因
```

**关键取舍**：没有任何匹配时**不抛异常、不阻止 CAD 启动**。用户看到的是一句
`CM3STATUS` 里的"未找到适配 R25.1 的适配器"，而不是加载失败。

## 6. 宿主探测

不反射 AutoCAD 类型（Shell 只为准入 API 引用 acmgd）：

1. 取当前进程已加载模块里的 `acmgd.dll`，读 `FileVersionInfo` → `25.1.60.0` → `R25.1`；
   枚举不到时退回 `Application` 程序集的 `AssemblyVersion`；
2. 环境变量 `CADMATH_HOST_SERIES`（如 `R25.1`）优先于上面，供 CI 与无 CAD 环境测试。

## 7. 装载与绑定

- 每个适配器装配进独立 `AssemblyLoadContext`，避免同一进程多版本适配器抢同一个 `acmgd`，
  并为将来"卸载/热替换适配器"留路。
- `Load` 覆盖只做一件事：把 `CadMath.Abstractions`、`CadMath.Core` 解析到默认上下文
  已加载的那一份（否则类型身份分裂，`is ICadAdapter` 恒为 false）；其余返回 null，
  交回默认上下文（`acmgd` 等由 CAD 自己解析）。
- `assembly` 相对 Shell 所在目录解析，且必须仍在 bundle 内。

## 8. 输入决策链

```
按键 Enter/Space
  → 适配器：焦点是否命令行？缓冲区文本？提示类型？
  → SubmitRequest → Shell → Core.InputTranslator.Translate
  → Pass：原样放行
     Reject：适配器吞掉按键 + 蜂鸣 + Shell 记日志（保留 v0.3.3 行为）
     Replace：适配器写回缓冲区（ReplaceInputQueue + OnSetSelectedTextQueue），原按键继续
  → 任何异常：Shell 保护性关闭拦截，CM3ON 可恢复
```

对外行为与 v0.3.3 逐条对齐：普通数字、LISP 表单、含中文的输入一律 Pass；
`1/0`、超 512 字符、坐标格式错误 Reject；整数提示要求 int32。

## 9. 版本与打包（单一来源）

`Directory.Build.props` 里 `<Version>` 是唯一版本号：

- 各程序集 `AssemblyVersion/FileVersion` 由它生成；
- `PackageContents.xml` 由模板 `bundle/PackageContents.xml` 在打包时替换
  `__CADMATH_VERSION__`（出现两处）；
- `ProductInfo.Version` 从程序集读版本，`CM3STATUS` 不再写字面量。

`build/build.ps1 -AcadDir "<AutoCAD 安装目录>"` 产出 `dist/CadMath03.bundle/`、
`dist/CadMath-InlineMath-<版本>.zip`、`dist/setup.json`（发行清单）与 `dist/SHA256SUMS.txt`。

0.4.1 起分发由命令行安装器接管（`tools/setup/`，见 [INSTALLER.md](INSTALLER.md)）：
负载放 `%LOCALAPPDATA%\CadMathInlineMath\payload\<版本>`，每个 CAD 版本写一条
`HKCU\...\<release>\<product>\Applications\CadMathInlineMath` 注册项，所以各版本可以独立
安装/更新/卸载；`adapters.json` 仍是运行时选择用的清单，`setup.json` 是发行侧清单
（含逐文件 SHA-256 与适配器状态），两者 schema 各自独立。`setup.json` 由构建脚本生成，
`ToolVersion` 与产品版本都来自 `Directory.Build.props`。

仍可只复制 `CadMath03.bundle` 到 `%APPDATA%\Autodesk\ApplicationPlugins\`（0.4.0 的做法），
但那是"全局一份"，安装器会把它识别为旧式安装并要求迁移。

## 10. 测试策略

| 层 | 载体 | 是否依赖 CAD |
|---|---|---|
| Core 数学/判定 | `tests/CadMath.Tests` 控制台断言（无 NuGet 依赖） | 否 |
| 清单解析 / 选择算法 / 宿主序列 | 同上 | 否 |
| Shell 装配与适配器装载 | 真机冒烟：日志 + `CM3STATUS` | 是 |
| 适配器行为（拦截、缓冲区、焦点） | 人工 UI 验收 + 日志核对 | 是 |
| 安装器（扫描/匹配/安装/回滚/恢复） | `tools/setup/tests/Test-Setup.ps1`，假注册表根 + 临时状态目录 | 否 |

v0.3.3 的 541 条解析断言与 45 条路由断言**原样搬过来**当作回归基准，
新实现必须逐条通过；这是"逻辑可以借用"的硬证明（当前 617 条全绿）。

## 11. 迁移阶段（实际进度）

| 阶段 | 内容 | 状态 |
|---|---|---|
| M1 | Core + Abstractions + 测试工程，旧用例全绿 | ✅ `checks=617 failures=0` |
| M2 | Shell（入口/命令/日志/清单/选择/装载） | ✅ 选择与清单有单测；装配由真机日志验证 |
| M3 | 现代适配器移植（焦点、缓冲区、提示事件） | ✅ 2026 真机拦截/改写/几何全部验证 |
| M4 | 打包脚本 + 无安装器分发 + 文档 | ✅ `build/build.ps1` → `dist/`，`README` + 本文 + `IMPLEMENTATION.md` |
| M5 | 安装器（安装/升级/卸载/回滚/恢复） | ✅ 0.4.1：`tools/setup/` 命令行安装器，24 项自动化测试 |

## 12. 待定 / 已知风险

- **ALC 卸载**：真机上从未触发过卸载路径（CAD 关闭即进程结束），"热替换适配器"仍属未验证能力。
- **2024 适配器**：旧版 API 差异未调研，`legacy-r24` 只有接口与失败提示，`TryStart` 恒 false，清单里标 `planned`（安装器会跳过，不会装一个跑不起来的适配器）。
- **构建区间匹配未启用**：`setup.json` 的 `buildRange` 目前留空，匹配只按版本系列；等拿到实测可用区间再填。
- **改名代价**：`CadMath03` 程序集名、`ProductCode`/`UpgradeCode` 保留不动，否则老用户升级会并存两套。
  （`CadMath03.bundle` 目录名只有在手动安装时才会出现；按版本注册用的是 `LOADER` 指向的 dll 路径。）
- **`ApplicationPlugins` 旧式安装**：不在注册表里、被所有 CAD 版本共享，安装器只能"移到备份"而无法按实例管理。
