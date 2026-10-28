# CadMath 0.5.4 · 一个安装包，两件独立插件

0.5.4 把**语境切换**（编辑文字时自动切中文输入法）正式并进发行包。它和 CadMath03 是**两件互相独立的插件**：各自一个程序集、各自一条注册项、各自一条版本线，只共用安装器和这个压缩包。

## 装了会发生什么

- CadMath03：命令行里 `100-30` 回车 → `70`，行为和 0.5.3 完全一致（0.5.4 没有改动拦截与计算逻辑）。
- 语境切换：双击编辑 TEXT / MTEXT 时把输入法切中文，退出编辑切回英文。**装完即生效**，不用再输入 `OCION`。
- 两个插件各自加载：一个坏掉、缺文件、初始化失败，另一个照常工作，命令行里也能看到各自的提示。

## 安装

1. 关掉所有 AutoCAD。
2. 把 `CadMath-InlineMath-0.5.4.zip` **完整解压**到一个固定目录（不要只解压其中的 `CadMath-Setup.cmd`）。
3. 双击 `CadMath-Setup.cmd` → 选 `1` 安装 → 选择要装的 AutoCAD 实例。
4. 启动 AutoCAD，命令行会出现两条提示：

```
CadMath 0.5.4 底部命令栏计算已启用。关闭：CLMOFF；状态：CLMSTATUS。
语境切换 0.1.8 已启用：编辑文字时切中文，退出回英文。OCIOFF 停用，OCISTATUS 状态。
```

## 本版变化

| 项 | 内容 |
| --- | --- |
| 新增产品 | 语境切换 `Oreak.ContextInput.dll`（0.1.8），独立注册项 `Applications\OreakContextInput` |
| 安装器 | 一次安装部署两件产品，逐件写注册项、逐件回读校验；某件缺失只跳过它并告警 |
| 卸载 | 两件产品一起清掉（`state.json` 里记录了每条实例装的是哪两件） |
| 回滚 | `--Rollback` 同时把两件产品指回备份里的旧版本 |
| 清单 | `setup.json` 新增 `products` 段（`cadmath` 与 `contextinput`，各自版本）；`PackageContents.xml` 两条 `ComponentEntry` |
| 构建 | 七个宿主各带一份语境切换（同一套编译锚：25.1.0 / 25.0.0 / 24.0.0 / 23.1.0 / 22.0.0 / 21.0.2 / 20.1.0） |
| 未变 | CadMath03 的拦截、计算、回显、`CLM*` 命令全部不变 |

## 交付物校验

| 文件 | 大小 | SHA-256 |
| --- | --- | --- |
| `CadMath-InlineMath-0.5.4.zip` | 见 Release 附件 | `24a9819aac3882d0e078ecb31530d13e37754b636de4ff1373f1181327f68e7c` |
| `setup.json` | 见 Release 附件 | 以 `SHA256SUMS.txt` 为准 |

解压后应看到：

```
CadMath-Setup.cmd
setup.json
tools\setup\...
CadMath03.bundle\Contents\Win64\{CadMath03.dll, Oreak.ContextInput.dll, Oreak.ContextInput.Core.dll, adapters.json, Adapters\*}
CadMath03.bundle\Contents\Win64-2025|Win64-2024|Win64-2020|Win64-2018|Win64-2017|Win64-2015\...
CadMath03-2025.bundle\  CadMath03-2024.bundle\  CadMath03-2020.bundle\
CadMath03-2018.bundle\  CadMath03-2017.bundle\  CadMath03-2015.bundle\
```

## 命令

| 插件 | 命令 |
| --- | --- |
| CadMath03 | `CLMON` `CLMOFF` `CLMSTATUS` `CLMCHECK` `CLMPROBE` `CLMECHO` `CLMSTYLE` `CLMFOCUS` |
| 语境切换 | `OCION` `OCIOFF` `OCIOBSERVE` `OCISTATUS` `OCISYMBOLSON` `OCISYMBOLSOFF` `OCITESTDRAWING` |

语境切换的机制、判据与边界见 [CONTEXTINPUT.md](CONTEXTINPUT.md)；安装器细节见 [INSTALLER.md](INSTALLER.md)。

## 已知限制

- 语境切换**只处理文字类对象**（TEXT / MTEXT / `DDEDIT` / `TEXTEDIT` / `MTEDIT`），属性块、表格单元格没有逐版本验证。
- 语境切换的七个宿主版本里，只有 **2026 真机验证过**；其余走同一份源码、按各自年份的 SDK 编译。
- 某些用 ascii_mode 实现的输入法（如 Weasel 0.17）可能表现为"API 成功、输入法没变"；`OCISTATUS` 会显示回读不一致，插件不会反复重试。
- CadMath03：只拦底部命令行（动态输入无托管入口）、识别不了的表达式会吞掉那次回车（连按两次即可提交原样文本）、升级不清理旧负载（0.5.0 起自动清理）。
- 安装器不会违反 AutoCAD 的加载规则：全程只写 `HKCU`，不用 `TRUSTEDPATHS` 之外的手段，也不分发任何 Autodesk 文件。

## 完整变更

[v0.5.3...v0.5.4](https://github.com/Oreak-jack/autocad-inline-math/compare/v0.5.3...v0.5.4)
