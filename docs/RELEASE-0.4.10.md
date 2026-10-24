# CadMath03 0.4.10 · 按 band 拆分宿主：2025 单独编译，2021–2024 编译锚下调

0.4.10 只改一件事：**每个 band 用 band 内最旧的 SDK 编一份二进制，band 内只测最新那个版本**。
代码逻辑、命令、日志格式都没动。

## 为什么要改

0.4.9 之前有两处隐性风险，平时看不出来：

- `modern-r25` 用 **25.1（2026）** 的 SDK 编译，却声明覆盖 R25.0 与 R25.1。AutoCAD 官方兼容表里，2025 只保证 2025 SDK 编的插件能跑。
- `legacy-r24` 用 **24.3（2024）** 编译，却声明覆盖 2021–2024。2021 只保证 2021 SDK 编的插件能跑，24.3 编的东西在 2021 上没有任何担保。

现在按官方兼容表切成四个 band：

| band | 覆盖版本 | 运行时 | 编译锚 | 适配器 | 宿主目录 |
|---|---|---|---|---|---|
| R25.1 | 2026 | .NET 8 | 25.1.0 | `modern-r26` | `Contents/Win64` |
| R25.0 | 2025 | .NET 8 | 25.0.1 | `modern-r25` | `Contents/Win64-2025` |
| R24.x | 2021–2024 | .NET Framework 4.8 | 24.0.0 | `legacy-r24` | `Contents/Win64-2024` |
| R23.1 | 2020 | .NET Framework 4.8 | 23.1.0 | `legacy-r23`（实验） | `Contents/Win64-2020` |

规则来自 `docs/VERSION-MATRIX.md`：编译锚取 band 内最旧的 SDK，旧版本不会缺 API，
所以一个 band 只需要在**最新**那个版本上实跑一次。

## 本版变化

- 新增 `CadMath.Adapter.Modern2025`（`modern-r25`），用 AutoCAD.NET 25.0.1 编译，只覆盖 R25.0。
- 2026 的适配器改名 `modern-r26`（25.1.0），只覆盖 R25.1；两者不再共用同一份二进制。
- `legacy-r24` 的编译锚从 24.3.0 换成 24.0.0（AutoCAD 2021）。
- `build/build.ps1` 产出四份宿主、四个 bundle；2025 有独立的 `CadMath03-2025.bundle`，
  主包的 `PackageContents.xml` 的 Series 收窄为 R25.1。
- `adapters/adapters.json` 新增 `acMgdVersion`，`setup.json` 带 `hosts[]`，安装器按实例版本选入口 DLL。
- 新增 `build/verify-anchors.ps1`：直接读每个 DLL 的 AssemblyRef 表，核对实际引用的 acmgd 版本，
  与清单声明不符就退出码 1。CI 增加 `windows-latest` 作业跑它（构建四份宿主 + 核对 + 安装器测试）。

## 安装

```text
1. 关闭正在运行的 AutoCAD（安装器会检查，CAD 开着会直接停下）
2. 解压本页下方的 CadMath-InlineMath-0.4.10.zip（要整个解压，不要在压缩包里直接双击）
3. 双击解压目录里的 CadMath-Setup.cmd
4. 选 1 进行安装；装完打开 AutoCAD，命令行输入 CM3STATUS 应看到 0.4.10
```

从 0.4.9 升级：直接跑上面第 2–4 步（或在**已装 0.4.9** 的机器上用菜单 2 检查更新）。
旧负载会移到 `%LOCALAPPDATA%\CadMathInlineMath\backups\`，失败会自动回滚。

## 校验值

```text
SHA-256(CadMath-InlineMath-0.4.10.zip) = 5b3c96c8a584ea93931af0d54d751c5ca823d40d15ebcb328bc87a2668e39f78
```

`SHA256SUMS.txt` 与 `setup.json` 同时附在本页；`setup.json` 里每个文件都有自己的 SHA-256，
安装器会逐文件校验后再替换。

## 包内结构

```text
CadMath03.bundle\          R25.1（2026）
CadMath03-2025.bundle\     R25.0（2025）
CadMath03-2024.bundle\     R24.0–R24.3（2021–2024）
CadMath03-2020.bundle\     R23.1（2020，实验）
```

每份 bundle 的 `Contents\Win64*\` 下是 `CadMath03.dll`（Shell）、`CadMath.Core.dll`、
`CadMath.Abstractions.dll`、`adapters.json` 与 `Adapters\` 里那一代专属的适配器。

## 命令

| 命令 | 作用 |
|---|---|
| `CM3ON` / `CM3OFF` | 开启 / 关闭拦截（回车、空格） |
| `CM3STATUS` | 版本、宿主、适配器、替换次数、最后错误 |
| `CM3CHECK` | 把转换走一遍，打印结果 |
| `CM3PROBE` | 诊断：CLR、宿主版本、适配器、焦点类型、输入缓冲是否可读 |

## 已知限制

- **2025、2021–2023 还没有真机验证过**。它们的宿主与 2026 / 2024 是同一套代码，
  只是编译 SDK 不同；请在对应版本上跑 `CM3PROBE` 与 `100-30` → `70`，把输出发回来。
- 2020 仍是实验状态（`legacy-r23` 的 status 是 `planned`），需要 `build\build.ps1 -Experimental`
  出的实验包才能装。
- 只拦截底部命令行（`CommandLineTextBox`），不支持动态输入框（`acdyninput`）。
- 适配器异常 → 失败即关闭（`Enabled=false`），需 `CM3ON` 恢复。
- 安装器升级不会删除旧版本负载目录与旧的 TRUSTEDPATHS 条目，卸载时才精确清理。

## 完整变更

<https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.9...v0.4.10>
