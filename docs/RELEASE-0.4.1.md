# CadMath03 0.4.1 · 把安装器接回来（命令行 + 按版本注册）

0.4.0 把插件拆成了 Core / Abstractions / Shell / 适配器，但拿掉了安装器：那时只能手动把
`CadMath03.bundle` 复制到 `%APPDATA%\Autodesk\ApplicationPlugins`。那份 bundle 是**所有 CAD 版本共享**的，
没法只给 2026 升级、也没法只卸载 2025 的。

0.4.1 补上安装器：一个纯命令行工具，安装 / 更新 / 卸载都按 CAD 版本独立进行，全程不需要管理员权限。

---

## 一、变化

| 项目 | 0.4.0 | 0.4.1 |
| --- | --- | --- |
| 安装方式 | 手动复制 bundle（全局一份） | `CadMath-Setup.cmd` 命令行安装器 |
| 多版本 | 共享同一份，无法独立 | 每个 CAD 版本一条 `HKCU` 注册，独立安装/更新/卸载 |
| 更新 | 手动下载覆盖 | 菜单 2：查 GitHub 最新版 → 下载 → 逐文件校验 → 事务更新 |
| 卸载 | 手动删目录 | 菜单 3：删注册项、摘掉自己写的 `TRUSTEDPATHS`、无引用时删负载 |
| 失败处理 | 无 | 注册表快照 + 新负载暂存 + 旧负载备份 → 自动回滚，并明确报告回滚结果 |
| 崩溃恢复 | 无 | `pending.json` 记录在途事务，下次启动可恢复 |
| 旧式安装 | — | 自动识别 `ApplicationPlugins` 里的旧安装，安装前提示迁移（移动到备份，不删除） |

插件本体（计算、拦截、`CM3*` 命令）行为与 0.4.0 完全一致：`checks=617 failures=0`。

---

## 二、安装

1. 关闭所有 AutoCAD（安装器也会检查，运行中会拒绝）。
2. 解压 `CadMath-InlineMath-0.4.1.zip`。
3. 双击 `CadMath-Setup.cmd`，按提示选「1. 安装插件」。

也可以直接跑命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\CadMath-Setup.ps1 -Check
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\CadMath-Setup.ps1 -Install "R25.1\ACAD-9101:804" -Yes
```

实例 Id 来自 `-Json` 或 `-Check` 的输出。装好后启动 AutoCAD，命令行出现：

```
CadMath 0.4.1 底部命令栏计算已启用。关闭：CM3OFF；状态：CM3STATUS。
```

### 从 0.4.0 升级

安装器会检测到 `%APPDATA%\Autodesk\ApplicationPlugins\CadMath03.bundle`，提示把它移到备份目录。
**必须先移走再装**：否则旧的全局 bundle 与新装的按版本注册会同时加载，同一次按键会被处理两次。

---

## 三、安装到哪里

```
%LOCALAPPDATA%\CadMathInlineMath\
  payload\0.4.1\Contents\Win64\...   负载（CadMath03.dll、Core、Abstractions、adapters.json、Adapters\）
  state.json                         已安装版本与已注册实例
  logs\setup-yyyyMMdd.log            运行日志
  backups\<时间戳>-<事务号>\          更新前的旧负载（回滚用）
  pending.json                       仅在事务中途失败时存在
```

注册表（只写 `HKCU`）：

```
HKCU\Software\Autodesk\AutoCAD\R25.1\ACAD-9101:804\Applications\CadMathInlineMath
  DESCRIPTION = 'AutoCAD Inline Math'
  LOADER      = <负载路径>\Contents\Win64\CadMath03.dll
  LOADCTRLS   = 2 (DWord)
  MANAGED     = 1 (DWord)
```

以及每个配置的 `Variables\TRUSTEDPATHS` 追加两项：`...\Contents\Win64`、`...\Contents\Win64\Adapters`。

---

## 四、适配器匹配

每个实例单独判断，装不上的实例会列出原因，不会"装上去再发现跑不起来"：

| 情况 | 结果 |
| --- | --- |
| 清单 `cadSeries` 不含该版本系列 | `series-mismatch` |
| 适配器 `status` 是 `planned` / `disabled` | `status-planned` / `status-disabled` |
| 架构不符 | `architecture-mismatch` |
| 声明了构建区间但读不到本机构建号 | `build-unknown` |
| 构建号在区间外 | `build-out-of-range` |
| 两个同等匹配 | `ambiguous`（停下让人决定） |

当前 `modern-r25` 是 `host-tested`（2025/2026 可用），`legacy-r24` 是 `planned`（2024 会被跳过）。

---

## 五、校验值

`setup.json` 里带逐文件 SHA-256，安装前逐条校验；zip 整体 SHA-256 写在 `SHA256SUMS.txt`。

```
<zip 的 SHA-256>  CadMath-InlineMath-0.4.1.zip
```

Windows 上核对：

```powershell
Get-FileHash .\CadMath-InlineMath-0.4.1.zip -Algorithm SHA256 | Format-List
```

---

## 六、包内结构

```
CadMath-InlineMath-0.4.1.zip
├─ CadMath-Setup.cmd
├─ setup.json
├─ tools/setup/...
└─ CadMath03.bundle/
   ├─ PackageContents.xml
   ├─ BUILD-INFO.txt
   └─ Contents/Win64/
      ├─ CadMath03.dll
      ├─ CadMath.Core.dll
      ├─ CadMath.Abstractions.dll
      ├─ adapters.json
      └─ Adapters/
         ├─ CadMath.Adapter.Modern.dll
         └─ CadMath.Adapter.Legacy.dll
```

---

## 七、命令与语法（未变）

| 命令 | 作用 |
| --- | --- |
| `CM3ON` | 重新开启拦截 |
| `CM3OFF` | 暂停拦截 |
| `CM3STATUS` | 开关、活动适配器、宿主版本、替换次数、最后错误、日志路径 |
| `CM3CHECK` | 读上次选中 LINE 的长度 |

底命令行的提示输入里可以直接写算式：

```
100-30          → 70
(1200+800)/3    → 666.666666666667
10+5,20*2       → 15,40
100-30<45       → 70<45
@100-30,0       → @70,0
```

生效范围仍是 15 个绘图/修改命令的底部命令行提示；纯数字、AutoLISP 表单、含非法字符的输入原样放行。

---

## 八、已知限制

- 只支持底部命令行，不支持浮动命令行面板与对话框。
- 真实适配器只有 R25.x；2024 仍是 `planned`。
- 只认 `HKCU` 与 `%LOCALAPPDATA%`：手动放进 `ApplicationPlugins` 的旧式安装需要迁移一次。
- 更新只走 GitHub Releases；网络不可用时安装与卸载照常可用。
- `setup.json` 的 `buildRange` 暂未启用，匹配只按版本系列。

---

## 九、验证

```powershell
# 计算层
dotnet run --project tests\CadMath.Tests -c Release
# checks=617  failures=0

# 安装器（隔离状态目录 + 假注册表，不动真实安装）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\setup\tests\Test-Setup.ps1
# 通过 24 项，失败 0 项
```

覆盖：清单校验、每个匹配拒绝原因、zip 越界、安装/修复/卸载、`TRUSTEDPATHS` 合并与还原、
事务中途失败回滚、崩溃后恢复、CAD 运行时拒绝安装。

---

## 完整变更

- 提交对比：<https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.0...v0.4.1>
- 架构设计：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 实施记录（职责映射、时序、不变式、验证）：[docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)
- 安装器说明：[docs/INSTALLER.md](docs/INSTALLER.md)
