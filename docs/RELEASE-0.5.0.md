# CadMath 0.5.0

0.5.0 是本项目的第一个 **能力版本**：0.4.x 一直在扩覆盖（2015–2026 七个版本带）和修安装器，插件本身从 0.3.3 起没变过。这一版把用户天天用的那几件事补齐。

## 安装

1. 下载 `CadMath-InlineMath-0.5.0.zip`，**完整解压**（不要在压缩包里双击）。
2. 关掉 AutoCAD。
3. 双击 `CadMath-Setup.cmd`，选 `1. 安装插件`。

从 0.4.x 升级同样的三步；装完之后，以后的升级就可以直接在菜单 2 里做了。

## 本版变化

### 插件

- **计算结果回显**：输入 `100-30` 回车后，命令行会多写一行 `= 70`，不用再靠几何图形反推有没有算对。
  不想要就 `CM3ECHO` 关掉（ON / OFF，直接回车＝切换），`CM3STATUS` 里能看到当前状态。
- **动态输入也拦**：以前只拦底部的命令行输入；现在十字光标旁的动态输入框同样会被识别与改写。
- **命令态改用 `CMDNAMES`**：原来只认 LINE / PLINE / CIRCLE 等 16 个命令，DIM 线性标注、HATCH、带透明命令的写法全部漏掉。现在以 AutoCAD 自己报告的当前命令为准，任何需要距离或角度的提示都能用。
- **失败不再一次就关**：适配器抛异常改为连续 3 次才保护性关闭（`CM3STATUS` 里有 `连败=`），瞬时抖动不会把功能关到底。
- **`CM3STYLE`**：提示风格开关（AUTO 跟随原生 / STANDARD 统一提示），默认 AUTO。这一版先把开关与链路铺好。

### 安装器

- **升级时自动清理旧负载**：`payload` 下不再累积 0.4.1 / 0.4.5 / 0.4.7 一堆目录，升级后会删掉不再被引用的旧版本，并打印释放了多少空间；同时把旧版本的 `TRUSTEDPATHS` 条目一起清掉。
- **`-Rollback` / 菜单 4**：从 `backups` 里最新的备份恢复上一个版本，`LOADER` 与 `TRUSTEDPATHS` 一并改回。备份本身不删除，回滚之后还能再回滚。
- 菜单从四项变成五项：

```
  1. 安装插件
  2. 检查是否有最新版本，有就安装
  3. 卸载该插件
  4. 回滚到上一个版本（用备份恢复）
  5. 退出
```

### 工程

- CI 的 Windows 作业增加"反射冒烟"：先构建、再用 `build/verify-anchors.ps1` 核对每个 DLL 实际引用的 `acmgd` 版本（14 项），编译锚失配在每次 push 就会失败。

## 交付物校验

| 文件 | 大小 | SHA-256 |
| --- | --- | --- |
| `CadMath-InlineMath-0.5.0.zip` | 562,539 | `b39352502e539075dcfb671ee4577ca34465eafaf279266ef8ee894b14210652` |
| `CadMath-InlineMath-0.5.0-experimental.zip` | 562,530 | `4b614313d1c6b4272b61230e53a5fcae834f14a43dcab34cc54401ef892ce8a5` |
| `setup.json` | 30,318 | 见 `SHA256SUMS.txt` |

`experimental` 包把 2020（`legacy-r23`）的适配器状态临时提升为 `built`，供实机验证；正式包里它仍是 `planned`。

## 包内结构

```
CadMath-Setup.cmd                 启动器（双击运行）
setup.json                        发行清单：适配器、宿主、逐文件校验值
tools/setup/                      命令行安装器
CadMath03.bundle/                 2026（Contents/Win64，.NET 8）
CadMath03-2025.bundle/            2025（Contents/Win64-2025，.NET 8）
CadMath03-2024.bundle/            2021–2024（Contents/Win64-2024，.NET Framework 4.8）
CadMath03-2020.bundle/            2020（Contents/Win64-2020）
CadMath03-2018.bundle/            2018（Contents/Win64-2018）
CadMath03-2017.bundle/            2017（Contents/Win64-2017）
CadMath03-2015.bundle/            2015–2016（Contents/Win64-2015）
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `CM3ON` / `CM3OFF` | 开启 / 暂停拦截 |
| `CM3STATUS` | 开关、适配器、宿主、替换次数、回显、连败、风格、最后错误、日志路径 |
| `CM3CHECK` | 读上一次选中 LINE 的长度 |
| `CM3ECHO` | 改写回显开关（0.5.0） |
| `CM3STYLE` | 提示风格（0.5.0） |
| `CM3PROBE` | 宿主与适配器诊断 |

## 支持的写法

```
100-30               → 70
(1200+800)/3         → 666.666666666667
2*3.5e2              → 700
10+5,20*2            → 15,40
100-30<45            → 70<45
@100-30,0            → @70,0
<-30  @<45  #<45     → 原样放行（AutoCAD 原生的"只给角度"）
```

## 已知限制

- 只拦底部命令行与动态输入，不拦第三方自己的对话框。
- 2025、2015–2023 只做了编译与锚核对，**没有真机验证**；2024 与 2026 是真机验证过的，2020 仍是实验性。
- 2007–2014 无法支持：计算层是 netstandard2.0，运行时下限是 .NET Framework 4.6.1。
- 升级后旧负载与旧 `TRUSTEDPATHS` 会自动清理，但 `backups` 永不自动删除（回滚要用）。

## 完整变更

https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.11...v0.5.0