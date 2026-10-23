# 命令行安装器（`CadMath-Setup`）

0.4.1 起，安装、更新、卸载由一个纯命令行工具完成：`tools/setup/CadMath-Setup.ps1`，入口是 `CadMath-Setup.cmd`。
它不写图形界面、启动时**不联网**（只有菜单 2 会请求 GitHub），只改当前用户的 `HKCU` 与 `%LOCALAPPDATA%`，不需要管理员权限。

---

## 怎么用

双击 `CadMath-Setup.cmd`，或者：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\CadMath-Setup.ps1
```

启动后先做一次本地扫描，再显示四项菜单：

```
请选择操作：
  1. 安装插件
  2. 检查是否有最新版本，有就安装
  3. 卸载该插件
  4. 退出
```

安装时需要同目录（或 `-SetupJson` / `-FromBundle` 指定）有 `setup.json` 与 `CadMath03.bundle`，正式发布的 zip 解压后就是这个布局。

---

## 安装到哪里

工具有两种安装方式，菜单里会问，命令行用 `-Mode` 指定：

| 方式 | 值 | 装到哪 | 特点 |
| --- | --- | --- | --- |
| 按 CAD 版本注册（默认） | `registration` | `%LOCALAPPDATA%\CadMathInlineMath\payload\<版本>` + 注册表 | 每个 CAD 实例独立安装、独立卸载，不动 `ApplicationPlugins` |
| 全局自动加载 | `appplugins` | `%APPDATA%\Autodesk\ApplicationPlugins\CadMath03.bundle` | 所有 CAD 版本共享一份，Autodesk 启动时自动扫描加载 |

两种方式**不要同时用**（同一份插件被加载两次会让一次按键被处理两遍）。当前用的是哪种写在
`%LOCALAPPDATA%\CadMathInlineMath\state.json` 的 `mode` 字段里，菜单 3（卸载）与 `Show-Detection` 都按它分派。

### 方式一：按 CAD 版本注册（默认）

每个实例独立安装、独立卸载：

```
%LOCALAPPDATA%\CadMathInlineMath\
  payload\0.4.1\Contents\Win64\...     受管负载（程序集 + adapters.json + Adapters\）
  state.json                           已安装版本、负载路径、已注册实例
  logs\setup-yyyyMMdd.log              全量运行日志
  backups\<时间戳>-<事务号>\            更新前的旧负载（回滚用；不会自动删除）
  pending.json                         只在事务中途失败时出现
```

注册表只写两处，都在 `HKCU`：

1. `HKCU\Software\Autodesk\AutoCAD\<R25.1>\<ACAD-9101:804>\Applications\CadMathInlineMath`

   ```
   DESCRIPTION = 'AutoCAD Inline Math'
   LOADER      = <上表的 payload 路径>\Contents\Win64\CadMath03.dll
   LOADCTRLS   = 2   (DWord)
   MANAGED     = 1   (DWord)
   ```

2. 该产品每个配置的 `Variables\TRUSTEDPATHS` 追加两项（已存在则保留原值）：
   `...\Contents\Win64` 与 `...\Contents\Win64\Adapters`。

这两个值都按「自己写入的自己摘掉」处理：卸载时只精确删除这两条路径，不整段清空 `TRUSTEDPATHS`。

### 方式二：全局自动加载（ `-Mode appplugins` ）

把整份 bundle 放到 `%APPDATA%\Autodesk\ApplicationPlugins\CadMath03.bundle`，由 Autodesk 启动时自动扫描加载——这就是 0.3.x 与 0.4.0 手工安装的做法：

- 不需要写注册表，也不需要按实例选择；
- 所有 CAD 版本共享同一份，卸载即全部失效；
- 装之前如果该目录已有旧版本，会先移到 `%LOCALAPPDATA%\CadMathInlineMath\backups\appplugins-<时间戳>\`（只移动不删除）；
- 卸载同样走菜单 3，工具读 `state.json` 的 `mode` 自动分派，把目录移到 `backups\appplugins-<时间戳>\` 并复位状态。

---

## 适配器匹配

安装前会用发行清单 `setup.json` 逐条判断每个 CAD 实例能不能装：

- `cadSeries` 不含该实例的版本系列（如清单只写 `R25.0/R25.1`，实例是 `R24.3`）→ `series-mismatch`
- 适配器状态是 `planned` 或 `disabled` → `status-planned` / `status-disabled`
- 架构不符 → `architecture-mismatch`
- 清单声明了构建区间、但读不到本机 CAD 构建号 → `build-unknown`
- 构建号落在区间外 → `build-out-of-range`
- 两个适配器同等匹配 → `ambiguous`（不猜，要求人工确认）

没有可用适配器的实例会被跳过并打印原因，安装不会"装上去再发现跑不起来"。
`legacy-r24` 目前是 `planned`，所以 2024 会显示 `legacy-r24:status-planned` 而不是硬装一个占位适配器。

---

## 更新与回滚

菜单 2 的执行顺序：请求 GitHub `releases/latest` → 校验 `setup.json` → 下载 zip → 逐文件 SHA-256 校验 → 复用安装流程。

安装/更新是一个事务：

1. 校验源包（目录形式逐文件哈希；zip 形式可选整体哈希），再核对 `PackageContents.xml` 的版本与程序集版本一致；
2. 为每个目标实例做适配器匹配，任何一个匹配失败就整体不落地；
3. 记录注册表快照 → 写 `pending.json` → 把新负载解到 `<payload>.stage-<事务号>` 并校验；
4. 旧负载移进 `backups\<时间戳>-<事务号>\`，新负载 `Move` 落位；
5. 逐实例写注册项，并回读确认 `LOADER` 指向的文件存在；
6. 写 `state.json`，清理 `pending.json`。

第 3～6 步任何一步抛错，都会：恢复注册表快照 → 删除暂存 → 删除新负载 → 从备份还原旧负载 → 写回旧 `state.json`，并把「回滚成功/失败」明确写进终端与日志。回滚失败时 `pending.json` 会保留，下次启动交互模式会提示是否再试一次恢复。

`backups\` 不自动清理，确认新版本可用后可手动删。

---

## 旧式安装

如果你之前把 `CadMath03.bundle` 手工复制（或用 0.3.x 安装器装）到
`%APPDATA%\Autodesk\ApplicationPlugins`，它会被**所有** AutoCAD 版本同时加载，与按版本注册的新安装叠加后，同一次按键会被处理两次。

所以安装开始前会检测它：

- 有旧式安装 + 带 `-RemoveLegacyBundle`：直接移到 `backups\legacy-<时间戳>\`（**移动，不删除**）；
- 交互模式会先问一句；
- 都没有就停下，打印「已停止，未修改任何文件」，不继续安装。

卸载流程同样会提示处理它。

---

## 常用参数

```powershell
# 只看环境与适配器匹配，不做任何修改
CadMath-Setup.ps1 -Check

# 机器可读的环境报告（JSON）
CadMath-Setup.ps1 -Json

# 环境自检（OS、架构、CAD 实例、旧式安装、适配器清单）
CadMath-Setup.ps1 -Doctor

# 非交互安装 / 卸载（实例 Id 来自 -Json 的 cadInstances[].id）
CadMath-Setup.ps1 -Install "R25.1\ACAD-9101:804" -Yes
CadMath-Setup.ps1 -Remove "R25.1\ACAD-9101:804" -Yes

# 换成全局自动加载方式（ApplicationPlugins，不需要实例 Id）
CadMath-Setup.ps1 -Install dummy -Mode appplugins -Yes

# 离线包（zip 或解压后的 bundle 目录）
CadMath-Setup.ps1 -Install <实例> -FromZip D:\pkg\CadMath-InlineMath-0.4.1.zip -Yes
CadMath-Setup.ps1 -Install <实例> -FromBundle D:\pkg\CadMath03.bundle -Yes
```

其他开关：`-Mode registration|appplugins`（默认 `registration`）、`-StateRoot`（换状态目录，测试用）、`-RemoveLegacyBundle`（自动把旧式 ApplicationPlugins 安装移到备份）、`-SetupJson`、`-NoNetwork`、`-Quiet`、`-RegistryRoot` / `-MachineRegistryRoot` / `-AppsRoot`（测试用的假根）。

交互模式下还有一段「选择目标实例」，支持 `1,3` 多选、`a` 全选、回车全部。

---

## 退出码

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功（或用户正常退出） |
| 1 | 致命错误：清单缺失/非法、磁盘或注册表不可写 |
| 2 | 没有可操作的 CAD 实例 |
| 3 | 校验失败或安装失败（含已回滚） |
| 4 | 卸载有实例没成功 |

---

## 日志

终端与文件同时输出，格式固定：

```
[2026-10-23 12:03:41] [INFO] [SCAN] 环境检查完成：1 个实例
[2026-10-23 12:03:41] [INFO] [VERIFY] 逐文件校验通过：8 个文件
[2026-10-23 12:03:41] [INFO] [REGISTER] 已注册 R25.1\ACAD-9101:804
[2026-10-23 12:03:41] [INFO] [DONE] 安装完成：0.4.1，1 个实例
```

阶段标签：`START / SCAN / VERIFY / MATCH / PLAN / SNAPSHOT / COPY / REGISTER / STATE / DONE / ROLLBACK / RECOVER / INSTALL / UPDATE / UNINSTALL / EXIT / MENU`。
文件在 `%LOCALAPPDATA%\CadMathInlineMath\logs\setup-yyyyMMdd.log`（UTF-8）。

---

## 为什么默认不用 `ApplicationPlugins` 自动加载

`%APPDATA%\Autodesk\ApplicationPlugins\*.bundle` 是"所有 CAD 版本共享"的：删掉它，2025 和 2026 会一起失去插件；想只给 2026 更新也不可能。按版本注册才能做到"每个实例独立安装/更新/卸载"，而且**全程不需要管理员**（Autodesk 从 2022 起支持当前用户下的 `HKCU` 注册）。

如果你更习惯"装一次全局生效"，工具也支持 `-Mode appplugins`（见上文"安装到哪里"）：它就是把同一份 bundle 放到那个共享目录，由 Autodesk 自动扫描加载。两条路的卸载都可用菜单 3，工具按 `state.json` 里的 `mode` 自动分派。

---

## 自动化测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\tests\Test-Setup.ps1
# 通过 33 项，失败 0 项
```

测试用临时 `-StateRoot` 与假注册表根（`HKCU:\Software\CadMathSetupTest\<guid>`），不会动真实安装；覆盖清单校验、适配器匹配的每个拒绝原因、zip 越界、安装/修复/卸载、`TRUSTEDPATHS` 合并与还原、事务回滚、崩溃后恢复、版本比较、两种安装方式（按版本注册与 ApplicationPlugins 全局）、CAD 运行时拒绝安装，以及启动批处理的行尾检查。

## 构建注意：批处理必须是 CRLF

`CadMath-Setup.cmd` 用 **CRLF 行尾 + 纯 ASCII**。cmd.exe 遇到 LF-only 的批处理会把整份脚本切错行（报一串 `is not recognized`，最后停在 `pause`，双击看起来就是闪退）。`.gitattributes` 已对 `*.cmd` 强制 `eol=crlf`，`build/build.ps1` 直接复制仓库里的文件，测试里也有一条断言防止它被改回去。
---

## 0.4.2：一套包、两代宿主

2024 用 .NET Framework 4.8，2025/2026 用 .NET 8，进程里只能有一个 CLR。做法不是"再发一个安装器"，
而是在同一个包里放两代宿主，让安装器按实例的 CAD 系列选入口：

```
CadMath03.bundle/Contents/Win64/        .NET 8      ← 2025 / 2026
CadMath03.bundle/Contents/Win64-2024/   .NET Framework 4.8 ← 2024
CadMath03-2024.bundle/                  2024 专用（ApplicationPlugins 全局安装用）
```

`setup.json` 里的 `hosts[]` 描述这个映射：

```json
"hosts": [
  { "series": ["R25.0", "R25.1"], "runtime": "net8.0-windows",
    "entry": "Contents/Win64/CadMath03.dll", "bundle": "CadMath03.bundle" },
  { "series": ["R24.0", "R24.1", "R24.2", "R24.3"], "runtime": "net48",
    "entry": "Contents/Win64-2024/CadMath03.dll", "bundle": "CadMath03-2024.bundle" }
]
```

安装时对每个实例做两件事：

1. 按 `adapters[].cadSeries` 选适配器（2024 只有 `legacy-r24` 能匹配）；
2. 按实例的系列从 `hosts[]` 选入口 DLL，注册的 `LOADER` 指向该入口。

**找不到对应宿主就报错停止**（`发行包没有为 R24.3 提供宿主。`），绝不回落到 `Win64` —— 那会把
.NET 8 的程序集塞给 2024，加载时直接 `BadImageFormatException`。

状态文件 `state.json` 的每个实例多记一个 `entry` 字段，卸载和诊断时可以据此知道当时装的是哪一代。

### 实验包（验证尚未开放的版本）

0.4.3 起 `legacy-r24`（AutoCAD 2024）的状态是 `host-tested`，正式包直接支持它。
实验包机制保留下来，供以后接入更老的版本（2023 及以前）或在新版本上先做小范围验证：

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1 -Experimental
# → dist/CadMath-InlineMath-<版本>-experimental-2024.zip（所有 planned 适配器被提升为 built）
```

验证者装好后跑 `CM3PROBE`，输出里 `host=` `clr=` `adapter=` `binding=` 与焦点类型齐全；把那段连同
`%TEMP%\CadMath03.log` 发回来即可判定。验证通过后把 `adapters/adapters.json` 里对应适配器的
`status` 改成 `host-tested`，正式版随之开放。
