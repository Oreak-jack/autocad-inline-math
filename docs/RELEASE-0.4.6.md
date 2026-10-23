# CadMath03 0.4.6 · 修掉"检查更新"必然失败的问题

0.4.6 只修安装器的更新流程。插件本身（三个宿主、拦截行为、数学能力）与 0.4.5 完全一致。

---

## 这个 bug 是什么

在 0.4.5 上点菜单 `2`（检查更新并安装），下载完 zip 后会立刻报：

```text
[ERROR] [INSTALL] 在此对象上找不到属性"zip"。请确认该属性存在。
更新失败：在此对象上找不到属性"zip"。请确认该属性存在。
回滚：未完成。失败发生在写入系统之前
```

0.4.2 的机器更早就踩到了同样的错（它的清单格式里同样没有 `zip` 段）。

原因：0.4.4 起我为了让清单只保留逐文件哈希，把 `setup.json` 里的 `zip` 段去掉了；
而安装器是在 `Set-StrictMode` 下运行的，`$Setup.zip` 这种对不存在属性的访问会直接抛异常，
不会安静地返回 `$null`。逐文件校验早就覆盖了这个位置，但读取 zip 校验值那一行先炸了。

## 修了什么

- 读清单的可选字段一律走 `Get-SetupField`（属性不存在就返回 `$null`），不再直接点属性。
- `build/build.ps1` 重新输出 `zip { name, sha256 }`，`sha256` 留空——0.4.2 ~ 0.4.4 那些**旧版安装器**也就能继续读新清单了（它们同样在 StrictMode 下访问 `$Setup.zip`）。
- `-FromZip` 参数之前没接上（传了也会报"找不到本地安装包"），现在离线安装可用了。
- 新增回归用例"从 zip 安装：清单里没有 zip 字段也不崩"，安装器测试从 35 项涨到 36 项。

## 从 0.4.5 升级

**如果你的机器上装的是 0.4.5 或更早，别用它的菜单 2 升级到 0.4.6**——它就是坏的，会报上面那个错。改成手动覆盖：

1. 关闭所有 AutoCAD。
2. 解压 `CadMath-InlineMath-0.4.6.zip`，双击根目录的 `CadMath-Setup.cmd`。
3. 菜单选 `1` 安装（等价于覆盖升级）。旧负载会先移到 `%LOCALAPPDATA%\CadMathInlineMath\backups\`。

**用 0.4.2 装着 2024 的机器，尤其要走手动这一步**：0.4.2 的安装器不认识多代宿主，
菜单 2 升上来的话会把 .NET 8 的宿主塞给 2024（加载不上）。0.4.6 自己的菜单 2 才按实例版本选宿主。

装完 0.4.6 之后，菜单 2 就恢复正常了——以后可以直接在工具里检查更新。

## 验证

- `tests/CadMath.Tests`：`checks=623 failures=0`
- `tools/setup/tests/Test-Setup.ps1`：`通过 36 项，失败 0 项`
- 其中新增的那条，正是照 2024 机器上的报错复现出来的（清单去掉 `zip` 段 + 从 zip 安装）。

## 交付物校验

```text
f524004c7e99da0c3a206204aa4582c3563a5ddbbc3386733ec9ee11e2bc5abb  CadMath-InlineMath-0.4.6.zip
87c9a5b6f538f83747b94ebdc9063084404773b0a01a586d06773287e853b438  CadMath-InlineMath-0.4.6-experimental.zip
```

`setup.json` 的校验值见同目录的 `SHA256SUMS.txt`。

## 包内结构

```text
CadMath-Setup.cmd                     启动器（双击）
setup.json                            发行清单（版本、文件与 SHA-256、宿主表）
CadMath03.bundle/                     R25（2025/2026，.NET 8）
CadMath03-2024.bundle/                R24（2021–2024，.NET Framework 4.8）
CadMath03-2020.bundle/                R23.1（2020，实验，仅实验包含激活）
tools/setup/                          安装器本体（PowerShell 5.1）
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `CM3ON` / `CM3OFF` | 开启 / 关闭拦截 |
| `CM3STATUS` | 查看状态、宿主版本、适配器、替换次数 |
| `CM3CHECK` | 检查选中直线长度（验证加载） |
| `CM3PROBE` | 打印宿主与命令编辑器的反射信息（诊断用） |

## 已知限制

- 2020 仍是实验性支持：代码与安装流程已就绪，还没有真机反馈。
- 2021–2023 用同一份 24.3 编出的宿主，按官方兼容表覆盖 2021–2024，但没有逐一实跑。
- 只拦截底部命令行；浮动命令面板、对话框、快捷键宏不生效。

## 完整变更

- `v0.4.6` 与 `v0.4.5` 之间：<https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.5...v0.4.6>
- 全部提交：<https://github.com/Oreak-jack/autocad-inline-math/commits/main>
- 架构说明：[docs/ARCHITECTURE.md](ARCHITECTURE.md)
- 安装器细节：[docs/INSTALLER.md](INSTALLER.md)