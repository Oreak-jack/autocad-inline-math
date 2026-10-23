# CadMath03 0.4.5 · 修掉方向输入被拒、拒绝时吞回车

0.4.5 是一个小的修复版。功能范围与 0.4.4 完全一致（2024 / 2025 / 2026 正式支持，2020 实验性支持），
只修了两处会让人以为"插件坏了"的输入问题。

---

## 安装

1. 关闭所有 AutoCAD。
2. 解压 `CadMath-InlineMath-0.4.5.zip`，双击根目录的 `CadMath-Setup.cmd`。
3. 菜单选 `1` 安装，用方向键/空格勾选要装的 AutoCAD 实例，回车确认。

升级与安装是同一条路径：菜单 `1` 会先把旧负载移到
`%LOCALAPPDATA%\CadMathInlineMath\backups\` 再换新，`TRUSTEDPATHS` 只增不改。

## 从 0.4.4 升级

直接覆盖安装即可；卸载时才会清理旧版本留下的 `TRUSTEDPATHS` 条目。

## 0.4.5 的变化

### 方向输入不再被当成坏表达式

AutoCAD 允许在"指定下一点"这类提示里只给角度：`<45` 表示"距离照旧、方向 45 度"，距离由橡皮筋补。
0.4.4 之前，`<` 开头的输入会被当成表达式送去求值，空左侧报 `需要数字或括号表达式`，然后被拒绝。

现在：

| 输入 | 0.4.4 的表现 | 0.4.5 的表现 |
| --- | --- | --- |
| `<45` | 拒绝、提示"需要数字或括号表达式" | 原样放行 |
| `@<45` | 拒绝 | 原样放行 |
| `#<45` | 拒绝 | 原样放行 |
| `100<30` | 求值成 `100<30` | 求值成 `100<30`（不变） |
| `100-30<45` | 求值成 `70<45` | 求值成 `70<45`（不变） |

`Test-InputPolicy` 里补了 5 条对应用例，断言数从 617 涨到 623。

### 拒绝时不再吞掉回车

0.4.4 之前，任何被拒绝的输入都会把随后那次回车一并吃掉——命令提示停在原地，
用户看起来就是"打完字按回车没反应"。根因是拒绝分支设了 `e.Handled = true`。

0.4.5 只记录这次拒绝（写日志、蜂鸣、提示），不再拦截按键：回车照常提交，
AutoCAD 自己会报"需要有效的点"之类的原生提示。

## 交付物校验

```text
da2f657248a380affbdee0b8d67db537b244b7a143e72ffd5b691fed6a1c45c0  CadMath-InlineMath-0.4.5.zip
cac8e035103c9bacbfecd067013694a41de54cddd194ee3790a5c46e5c8a322c  CadMath-InlineMath-0.4.5-experimental.zip
877572806f60327988c8c245ce12873028e9cad8b30053fbb1ce7afd97d48ffc  setup.json
```

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
- 方向输入的"距离"部分仍走 AutoCAD 原生逻辑，插件不参与计算。

## 完整变更

- `v0.4.5` 与 `v0.4.4` 之间：<https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.4...v0.4.5>
- 全部提交：<https://github.com/Oreak-jack/autocad-inline-math/commits/main>
- 架构说明：[docs/ARCHITECTURE.md](ARCHITECTURE.md)
- 安装器细节：[docs/INSTALLER.md](INSTALLER.md)
