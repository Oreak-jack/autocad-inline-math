# 版本适配矩阵（Version Matrix）

> 目的：把"每个 CAD 版本都要真机测一遍"压缩成"每个编译 band 测一次"。
> 依据：Autodesk 官方兼容表 + `CADAutoIME` 的分带编译实践（跑通 2007–2027）+ 我们自己的编译探测结果。

## 三条规则

**规则 1：一个 band 只编一份二进制，编译锚取 band 内最旧的 SDK。**

插件编译时引用的 `AcMgd/AcDbMgd/AcCoreMgd` 版本号不影响运行时绑定——AutoCAD 用自己的加载器解析这些程序集，会返回进程里已经加载的那一份（更新的）。所以：

- 用 **旧 SDK 编** → 只依赖旧 API → 新宿主上一定有这些 API → 能跑。
- 用 **新 SDK 编** → 可能引用新 API → 旧宿主没有 → `MissingMethodException`。

这条是我们目前最大的隐性风险：现在的 `legacy-r24` 是用 **24.3（2024）** 编的，却声称覆盖 2021–2024。2021 跑它属于"用新 API 赌旧宿主"。改成 **24.0（2021）** 编，风险消失，且仍然只需测 2024 一台。

**规则 2：CLR 代不同，必须分开编。**

`net48` 的 DLL 在 .NET 8/10 进程里根本加载不了（反之亦然）。所以 band 的分界线首先是 CLR 代，其次才是 SDK 版本。

**规则 3：band 内只测最新那个版本。**

编译锚是最旧 SDK，所以"最旧版本缺 API"不可能发生；剩下唯一的变量是"最新版本改了行为"，而最新版本的宿主最严格。因此 band 内测最新版本即可，更旧的版本用同一份二进制，属于低风险。

> 例外：band 的**边界版本**如果有已知重大改动（如 2026.1.2 换 .NET 10），要单独成 band 并单独测。

## 矩阵

`编译锚` = 该 band 构建时引用的 `AutoCAD.NET` NuGet 版本（已核对包内 TFM）。

| band | 覆盖 AutoCAD | 内部版本 | CLR | 编译锚 | 宿主 TFM | adapter id | 宿主目录 | 状态 | 需测 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| R20 | 2015、2016 | R20.0 / R20.1 | .NET 4.x | 20.1.0 (net45) | net48 | `legacy-r20` | `Contents/Win64-2015` | ✅ 0.4.11 已编、锚已核对（`built`） | 2016 |
| R21 | 2017 | R21.0 | .NET 4.x | 21.0.2 (net45) | net48 | `legacy-r21` | `Contents/Win64-2017` | ✅ 0.4.11 已编、锚已核对（`built`） | 2017 |
| R22 | 2018 | R22.0 | .NET 4.x | 22.0.0 (net46) | net48 | `legacy-r22` | `Contents/Win64-2018` | ✅ 0.4.11 已编、锚已核对（`built`） | 2018 |
| R23 | 2019、2020 | R23.0 / R23.1 | .NET 4.x | 23.0.0 (net47) | net48 | `legacy-r23` | `Contents/Win64-2020` | 已编译（暂用锚 23.1，只覆盖 R23.1） | 2020 |
| R24 | 2021–2024 | R24.0–R24.3 | .NET 4.8 | **24.0.0** (net47) | net48 | `legacy-r24` | `Contents/Win64-2024` | ✅ 0.4.10 已改锚，2024 真机验证 | 2024 |
| R25a | 2025 | R25.0 | .NET 8 | **25.0.1** (net8.0) | net8.0-windows | `modern-r25` | `Contents/Win64-2025` | ✅ 0.4.10 已拆出，待一次真机回执 | 2025 |
| R25b | 2025 ≥ Update 1.4 | R25.0 | .NET 10 | 25.0.2 (net10.0) | net10.0-windows | `modern-r25-10` | `Win64-2025-net10` | 规划 | — |
| R26 | 2026、2026.0.x | R25.1 | .NET 8 | **25.1.0** (net8.0) | net8.0-windows | `modern-r26` | `Contents/Win64` | ✅ 真机验证 | 2026 |
| R26b | 2026 ≥ 1.2 | R25.1 | .NET 10 | 25.1.1 (net10.0) | net10.0-windows | `modern-r26-10` | `Win64-2026-net10` | 规划 | — |
| R27 | 2027 | R26.0 | .NET 10 | 26.0.0 (net10.0) | net10.0-windows | `modern-r27` | `Win64-2027` | 规划 | — |

> 0.4.10 已按规则 1 完成拆分：2025 用 `25.0.1` 编（`modern-r25`，`Contents/Win64-2025`），2026 用 `25.1.0` 编（`modern-r26`，`Contents/Win64`），2021–2024 统一用 `24.0.0` 编。
>
> 0.4.11 把 R20 / R21 / R22 三个 band 也补齐（`legacy-r20` / `legacy-r21` / `legacy-r22`，分别用 `20.1.0` / `21.0.2` / `22.0.0` 编，`Contents/Win64-2015` / `-2017` / `-2018`），状态 `built`，`build/verify-anchors.ps1` 已核对 14 项引用版本全部吻合。地板是 R20：`CadMath.Core`/`CadMath.Abstractions` 为 `netstandard2.0`，运行下限 .NET Framework 4.6.1，2007–2014（R17–R19）做不了。

## 与参考项目的对照

`CADAutoIME`（跑通 2007–2027）的分带与编译锚：

| 它的工程 | TFM | 引用的 SDK 目录 | 对应 CAD |
| --- | --- | --- | --- |
| Sys17 | v3.5 | Net2.0_2007-2009 | 2007–2009 |
| Sys18 | v3.5 | Net3.5_2010-2012 | 2010–2012 |
| Sys19 | v4.7.2 | Net4.0_2013-2014 | 2013–2014 |
| Sys20 | v4.7.2 | Net4.5_2015-2016 | 2015–2016 |
| Sys21 | v4.7.2 | Net4.6_2017 | 2017 |
| Sys22 | v4.7.2 | Net4.6_2018 | 2018 |
| Sys23 | v4.7.2 | Net4.7_2019-2020 | 2019–2020 |
| Sys24 | v4.8 | Net4.8_2021-2024 | 2021–2024 |
| Sys25 / Sys26 | net8.0-windows | Net8.0_2025-2026 | 2025 / 2026 |
| Sys27 | net10.0-windows | Net10.0_2027 | 2027 |

观察：

- 它的 band 划分与官方兼容表一致（2013–2014 一档、2015–2016 一档……2021–2024 一档）。
- 它把 2025 和 2026 都放在 `Net8.0_2025-2026` 同一份 SDK 目录里——这正是我们目前的做法，**但这意味着它的 2025 用户也在跑 2026 编出来的二进制**。规则 1 更严格的做法是分开。
- 它把 2013–2020 的目标框架都设成 `v4.7.2`（比 SDK 新），说明"TFM 只要不低于运行环境"即可；对我们是同样的道理——我们统一用 `net48` 就行。

## 测试策略

| 层级 | 手段 | 成本 | 覆盖 |
| --- | --- | --- | --- |
| 静态证明 | CI 对每个 band 编译一次（`dotnet build` + 反射核对引用版本） | 0 人力 | 证明 API 存在、TFM 正确 |
| 单点真机 | 每 band 取**最新**版本，跑 `CLMPROBE`→`100-30`→`CLMCHECK` | 每 band 约 5 分钟 | 证明拦截链路在真实宿主成立 |
| 回执模板 | 用户/朋友回贴 4 行：`CLMPROBE` 输出、`replacement_requested` 日志、`CLMSTATUS`、异常截图 | 1 分钟 | 远程验收 |

按矩阵，**需要真机测的点**：2016、2017、2018、2020、2024、2025、2026（各 1 次）。2025/2026 已覆盖；2024 已有回执；2020 已有实验包；还缺 2016/2017/2018 与 2025 —— 其中 2025 与 2026 如果拆 band 才需要单独跑。

## 落地步骤（每加一个 band）

1. `src/CadMath.Adapter.<Band>/`：csproj 链接 `CadMath.Adapter.Shared\**\*.cs`，引用该 band 的 NuGet 三件（`ExcludeAssets="runtime"`），adapter 子类只写 `AdapterId`。
2. `build/build.ps1` 的 `$hostsPlan` 加一项（band / runtime / 编译锚 / 宿主目录），`$adaptersPlan` 加一项。
3. `bundle/PackageContents-<band>.xml`（全局模式用）。
4. `adapters/adapters.json` 加一条，`cadSeries` 写该 band 的 R 版本，`status` 先 `planned`。
5. 真机回执通过后把 `status` 提到 `host-tested`，发一个小版本。

## 边界与未知

- **最低版本**：我们的 `CadMath.Core`/`CadMath.Abstractions` 是 `netstandard2.0`，运行时要求 **.NET Framework 4.6.1+**。所以 2015/2016（CLR 4.5/4.6）只有在系统装了 4.6.1+ 时才能跑。Windows 10 及以上默认满足；真要支持 2013/2014 需要把 Core 降到 `net40`，得去掉 `record`/`init`/`Task` 等语法，属于重写级改动，暂不做。
- **2026.1.2+ / 2025 Update 1.4** 把运行时换到 .NET 10：官方说"现有插件应继续可用"，但 2027 明确要求重编。稳妥做法是 `net10` band 单独编、单独测，不靠"应该可用"。
- 我们尚未在 2019–2020 真机验证过拦截行为（只验证过编译与安装流程）。

---

## 怎么确认锚没跑偏

规则 1 只有"编出来的二进制确实引用了最旧那版 SDK"时才成立，而 csproj 里写的版本号并不足以证明这一点（增量构建、传递依赖、版本提升都可能换掉实际引用）。所以每个 DLL 都直接读 AssemblyRef：

```powershell
powershell -ExecutionPolicy Bypass -File build\verify-anchors.ps1
```

它读 `dist\setup.json`，对每个适配器比对 `acMgdVersion`（清单里声明）与 DLL 里的 `acmgd` 引用版本，同时对每个宿主（`CadMath03.dll`）打印实际引用。不符就退出码 1，CI 的 `hosts` 作业拿它当门禁。