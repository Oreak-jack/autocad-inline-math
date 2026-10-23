# CadMath 架构（重写版）

目标：把 v0.3.3 的单文件插件拆成"计算引擎 / 适配器契约 / 宿主外壳 / 版本适配器"四层，
让数学逻辑和 AutoCAD API 互不越界，把"能不能改"的问题先解决掉。安装器不在本次范围内。

对应你给的分层图：

```
        ┌──────────────────────────────────────────────┐
        │  CadMath.Core     统一计算引擎               │  纯 .NET，零依赖
        │  表达式解析 / 坐标输入 / 判定策略 / 错误码    │  100% 可单测
        └───────────────────┬──────────────────────────┘
                            │ 被引用（只依赖 Core）
        ┌───────────────────▼──────────────────────────┐
        │  CadMath.Abstractions 适配器契约             │  纯 .NET，零依赖
        │  ICadAdapter / IAdapterHost / Manifest        │  选择算法可单测
        └───────────────────┬──────────────────────────┘
                            │ 实现契约
   ┌────────────────────────▼───────────────────────────┐
   │ Adapter Manager（CadMath.Shell 内）                │  引用 Core + Abstractions
   │ 读配置 → 识别 CAD → 匹配适配器 → 检查兼容性 → 装载  │  + acmgd（仅为入口/命令）
   └───────┬─────────────────────────────┬──────────────┘
           │                             │
   ┌───────▼──────────────┐      ┌───────▼──────────────┐
   │ 现代适配器 2025/2026 │      │ 旧版适配器 2024-     │
   │ PreTranslateMessage  │      │ （预留，先不实现）    │
   │ UIBindings 输入缓冲  │      │ 不同 API，独立装载    │
   └──────────────────────┘      └──────────────────────┘
```

## 1. 依赖方向（硬规则）

```
CadMath.Adapters.*  →  CadMath.Abstractions  →  CadMath.Core
CadMath.Shell       →  CadMath.Abstractions  →  CadMath.Core
                       (Shell 另引用 acmgd，只用于 IExtensionApplication 与 CM3* 命令)
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

随 bundle 发布，Shell 从 `AppContext.BaseDirectory` 读取，可用
`CADMATH_ADAPTER_CONFIG` 环境变量覆盖（测试/开发用）。

```json
{
  "schemaVersion": 1,
  "adapters": [
    {
      "id": "autocad-modern",
      "displayName": "AutoCAD 2025/2026 现代适配器",
      "assembly": "CadMath.Adapters.AutoCAD2025.dll",
      "type": "CadMath.Adapters.AutoCAD2025.ModernAdapter",
      "series": ["R25.0", "R25.1"],
      "priority": 100,
      "verified": true,
      "runtime": "net8.0-windows"
    },
    {
      "id": "autocad-legacy",
      "displayName": "AutoCAD 2024 及更早版本适配器",
      "assembly": "CadMath.Adapters.AutoCAD2024.dll",
      "type": "CadMath.Adapters.AutoCAD2024.LegacyAdapter",
      "series": ["R24.0", "R24.1", "R24.2", "R24.3"],
      "priority": 50,
      "verified": false,
      "runtime": "net48"
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
输入：manifest[], hostSeries, 已存在文件集合
1. 过滤 series 不含 hostSeries 的项
2. 过滤 assembly 文件不存在的项      → 原因 missing-assembly
3. 按 (priority desc, series 精确命中优先) 排序
4. 依次 TryStart，异常/失败记录原因后试下一个
5. 全部失败 → 无适配器状态：插件加载成功但拦截关闭，CM3STATUS 给出原因
```

**关键取舍**：没有任何匹配时**不抛异常、不阻止 CAD 启动**。用户看到的是一句
`CM3STATUS` 里的"未找到适配 R25.1 的适配器"，而不是加载失败。

## 6. 宿主探测

不反射 AutoCAD 类型（Shell 只为准入 API 引用 acmgd）：

1. 取当前进程已加载模块里的 `acmgd.dll`，读 `FileVersionInfo` → `25.1.60.0` → `R25.1`
   （找不到模块时用 `acdbmgd.dll` 兜底）；
2. 环境变量 `CADMATH_HOST_SERIES`（如 `R25.1`）优先于上面，供 CI 与无 CAD 环境测试。

## 7. 装载与绑定

- 每个适配器装配进独立 `AssemblyLoadContext`，避免同一进程多版本适配器抢同一个 `acmgd`。
- `Load` 覆盖：`Autodesk.*`、`CadMath.Abstractions`、`System.*` 一律回落到
  `AssemblyLoadContext.Default`（即 CAD 已装载的那份），其余走
  `AssemblyDependencyResolver`。
- 适配器目录就是 Shell 所在目录（`Contents/Win64`），不额外加搜索路径。

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
- `PackageContents.xml` 由模板 `bundle/PackageContents.template.xml` 在打包时替换
  `{{VERSION}}`；
- `Plugin` 里的 `CM3STATUS` 从程序集读版本，不再写字面量。

`tools/pack.ps1 -Version x.y.z` 产出：`build/CadMath03.bundle/`、release ZIP、
`SHA256SUMS.txt`。**无安装器版本**＝把 `CadMath03.bundle` 整目录复制到
`%APPDATA%\Autodesk\ApplicationPlugins\`，或 `NETLOAD` 里面那个 `CadMath03.dll`。

## 10. 测试策略

| 层 | 载体 | 是否依赖 CAD |
|---|---|---|
| Core 数学/策略 | `tests/CadMath.Tests` 控制台断言（无 NuGet 依赖） | 否 |
| 选择算法/清单解析 | 同上 | 否 |
| Shell 中转（假适配器） | 同上 | 否 |
| 适配器真机 | `accoreconsole` 冒烟 + 手工 UI 验收 | 是 |

v0.3.3 的 541 条解析用例与 36 条路由用例**原样搬过来**当作回归基准，
新实现必须逐条通过；这是"逻辑可以借用"的硬证明。

## 11. 迁移阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| M1 | Core + Abstractions + 测试工程，旧用例全绿 | `dotnet run --project tests/CadMath.Tests` 全 PASS |
| M2 | Shell（入口/命令/日志/清单/选择）+ 假适配器 | 单元测试覆盖选择与降级路径 |
| M3 | 现代适配器移植（焦点、缓冲区、提示事件） | `accoreconsole` 能 NETLOAD 并接受一次输入 |
| M4 | 打包脚本 + 无安装器分发 + 文档 | 复制 bundle 后 AutoCAD 启动即加载 |
| M5 | 安装器回归（后置，不在本次） | 待定 |

## 12. 待定 / 已知风险

- **ACL 风险**：`AssemblyLoadContext` 卸载与 AutoCAD 关闭顺序的交互需真机验证。
- **2024 适配器**：旧版 API 差异未调研，先留 `series` 与接口，不实现。
- **改名代价**：`CadMath03` 程序集名、`CadMath03.bundle` 目录名保留不动，
  否则老用户升级会被现有 `install.json` 的 `Target` 校验挡住。
