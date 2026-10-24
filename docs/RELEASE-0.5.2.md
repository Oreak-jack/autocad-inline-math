# CadMath03 0.5.2

0.5.2 是一次"实话实说"的修正：把 0.5.0 里那条**从来就不可能生效**的动态输入拦截分支彻底删掉，
并在状态里明确写出生效范围。除此之外没有行为变化。

## 安装

1. 下载 `CadMath-InlineMath-0.5.2.zip`，**完整解压**（不要只解出 `CadMath-Setup.cmd`）。
2. 关闭 AutoCAD。
3. 双击解压出来的 `CadMath-Setup.cmd` → 菜单 `1` 安装。

从 0.5.x 升级同样只需解压新包、跑菜单 `1`（或 CAD 关着时用菜单 `2`）。

## 本版变化

### 为什么去掉动态输入拦截

0.5.0 想连"十字光标旁那个输入框"一起拦。实测（AutoCAD 2026 / acmgd 25.1.60）：

| 尝试的入口 | 实测结果 |
| --- | --- |
| 反射 `Autodesk.AutoCAD.EditorInput.DynamicInput` | 类型不存在（acmgd 2632 个类型里没有），`Editor` 也没有相关成员 |
| 窗口类名 `CAcDynInputWndControl` | 有 6 个，但都是 `visible=False` 的原生 Afx 窗口，焦点在绘图区时也一直存在，无法作为"正在输入"的判据 |
| `GetFocus()` 落在输入框上 | 从未发生，焦点始终在文档视图的原生窗口 |

动态输入是 AutoCAD 自绘的控件，托管侧没有任何读写入口。那条分支留着**只会吞键、在日志里写误导性的
`dyninput` 行**，所以 0.5.2 直接删除，并保留一句说明。

### 现在明确写出来的范围

- `CLMSTATUS` 末尾新增一行：`生效范围：仅底部命令行（动态输入无托管入口，不支持）`。
- README 的"生效范围"与"已知限制"同步改写。

> 如果你需要动态输入框里也能算，只能改用**透明命令**方案（`'CAL`）或用 AutoCAD 自带的
> `CAL`/`QUICKCALC`——那不是本插件能碰的区域。

## 交付物校验

```
a0ec590c417d208b3c630941c2d138b4f8fcea50443e789fcc38b39b26a9ee44  CadMath-InlineMath-0.5.2.zip
```

## 包内结构

```
CadMath-Setup.cmd              启动器（纯 ASCII + CRLF）
setup.json                     发行清单：版本、适配器、hosts、逐文件 SHA-256
SHA256SUMS.txt                 包校验值
tools/setup/                   命令行安装器（安装 / 更新 / 卸载 / 回滚）
CadMath03.bundle/              主包：Contents/Win64（2026）等七套宿主
CadMath03-2025.bundle/         2025
CadMath03-2024.bundle/         2021–2024
CadMath03-2020.bundle/         2020
CadMath03-2018.bundle/         2018
CadMath03-2017.bundle/         2017
CadMath03-2015.bundle/         2015–2016
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `CLMON` / `CLMOFF` | 开启 / 关闭拦截 |
| `CLMSTATUS` | 状态、活动适配器、替换次数、生效范围、日志路径 |
| `CLMECHO` | 改写结果回显开关（`= 70`） |
| `CLMSTYLE` | 提示风格：`AUTO` / `STANDARD` |
| `CLMCHECK` | 跑一遍自检（`CLMPROBE` 在旧包里是同一个诊断） |

## 已知限制

- 只支持底部命令行输入；浮动命令行面板、对话框、**动态输入**均不拦截。
- 覆盖 AutoCAD 2015–2026 七个版本带；2024 / 2026 已真机验证，其余只做编译 + 锚核对 + 安装流程验证。
- 适配器连败 3 次会保护性关闭拦截，需 `CLMON` 恢复。

## 完整变更

https://github.com/Oreak-jack/autocad-inline-math/compare/v0.5.1...v0.5.2
