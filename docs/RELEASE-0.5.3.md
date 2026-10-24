# CadMath03 0.5.3 · 修复焦点判定回归与回显叠字

0.5.2 发布后修掉了两个真实问题：**算式在 2026 上不再被拦截**（合规清理误删了唯一生效的焦点判定），以及**回显把 `5+6 = 11` 叠成 `5+6 = 1111`**。另外补上了崩溃恢复后提示钩子的自愈，并新增 `CLMFOCUS` 诊断命令。

## 安装

1. 关闭 AutoCAD。
2. 解压 `CadMath-InlineMath-0.5.3.zip`，双击 `CadMath-Setup.cmd`。
3. 选 `1. 安装`，确认后输入 `1` 选择按版本注册。

装完启动 AutoCAD，命令行会打印 `CadMath 0.5.3 底部命令栏计算已启用。关闭：CLMOFF；状态：CLMSTATUS。`

## 从 0.5.2 升级

已经装过 0.5.2 的机器，**可以直接用菜单 2 更新**（先关 CAD）；也可以解压新版 zip 走菜单 1。升级不会动你的图纸，也不会留下旧版本残留——旧负载会在安装成功后自动清掉。

如果你在 0.5.2 发布当天就下载过包，那份里的焦点判定是坏的：输入 `100-30` 回车后 AutoCAD 会报"需要点或选项关键字"，日志里连一条 `rejected:` 都没有。本版修复。

## 本版修了什么

### 1. 焦点判定被过度清理（0.5.2 引入的回归）

0.5.2 为了"不依赖未公开命名空间"，把 `AllowedFocus` 里唯一在 2025/2026 上能命中的判断删掉了：

```csharp
if (focused?.GetType().FullName == "Autodesk.AutoCAD.ViewModel.CommandLine.CommandLineTextBox") return true;
```

删掉之后只剩两条路：焦点是 `TextBox` 就判定"不是命令行"，以及窗口层判断（是不是文档窗口的子窗口、窗口类名是否在白名单里）。而 2026 的命令行是独立的 WPF 窗口，原生焦点落在 `HwndWrapper[...]` 上——不是文档窗口的子窗口，也不在类名白名单里，于是**每一条按键都被判定为"不在命令行"而直接放行**。

插件看起来一切正常（`CLMSTATUS` 显示已启用、适配器已加载、连败 0），只是什么都不做。这也是为什么当时日志里一条 `rejected:` 都没有：拦截链根本没进去。

现在改为按**类型名子串**判断：

```csharp
var name = focused.GetType().FullName ?? focused.GetType().Name;
if (name.IndexOf("CommandLine", StringComparison.OrdinalIgnoreCase) >= 0) return true;
if (focused is System.Windows.Controls.TextBox) return false;
return AllowedFocusByWindow(document);
```

既不写死内部类型全名（类型改名也还能认），又不把窗口层当唯一依据；两条都不成立时退到窗口层，行为可预测。

### 2. 回显叠字：`5+6 = 1111`

0.5.2 的回显在按键处理那一刻同步写，而 AutoCAD 要等消息循环才把提示行里的 `5+6` 换成 `11`，两段文本就挤在同一行：

```
指定下一点或 [放弃(U)]: 5+6 = 1111
```

现在延后 90 ms 再写，并且不写末尾换行：

```
指定下一点或 [放弃(U)]: 11
  ← 5+6 = 11
```

几何从来是对的（`1111` 只是显示叠字），但看起来像算错了，所以必须修。同一秒内重复的同一个替换只回显一次。

### 3. 崩溃恢复后插件静默失效

AutoCAD 异常退出后再打开，会弹"图形修复"并新建一个文档；这个新文档的提示钩子没有挂上，插件从此不响应，日志里一条也没有。现在每次按键前检查一次钩子是否已挂，没挂就补挂，日志里能看到 `hook-attached`。

### 4. 新增 `CLMFOCUS`

把焦点实况直接打到命令行并写日志：`wpfFocused`、`wpfIsTextBox`、`nativeClass`、`nativeIsDocument`、`nativeIsChildOfDocument`、`inputBuffer`、`inputText=[…]`、`promptingForCommandName`、`activeCommand`。以后遇到"插件不响应"，先跑它，一眼能看出卡在哪个条件。

## 交付物校验

```
bc571f239e7c84a31e94b532d3f368d69d77dca035bbfd8cec60bf53fbedc105  CadMath-InlineMath-0.5.3.zip
e805bd276f2af22a10b4d9c9f12d57fa81efd7d37dfbca0084501214dc8be8d5  CadMath-InlineMath-0.5.3-experimental.zip
20933907a6cad178e4f4e7cabc0b0d493956e1d9bf8b7282fa71c17540bb0bb9  setup.json
```

实验包（把 AutoCAD 2020 适配器临时提升为可装）同名带 `-experimental` 后缀，只给验证者用。

## 包内结构

```
CadMath-Setup.cmd                启动器（双击它）
setup.json                       发行清单：版本、七个宿主、逐文件校验值
tools/setup/                     命令行安装器
CadMath03.bundle/                2026（.NET 8）
CadMath03-2025.bundle/           2025（.NET 8）
CadMath03-2024.bundle/           2021–2024（.NET Framework 4.8）
CadMath03-2020.bundle/           2020（.NET Framework 4.8）
CadMath03-2018.bundle/           2018
CadMath03-2017.bundle/           2017
CadMath03-2015.bundle/           2015–2016
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `CLMON` / `CLMOFF` | 开启 / 关闭拦截 |
| `CLMSTATUS` | 状态汇总（版本、适配器、连败、回显、风格、生效范围） |
| `CLMCHECK` | 自检 |
| `CLMPROBE` | 探测宿主与命令行绑定 |
| `CLMFOCUS` | 焦点实况（排障） |
| `CLMECHO` | 回显开关 |
| `CLMSTYLE` | 提示风格 |

## 写法

| 输入 | 结果 |
| --- | --- |
| `100-30` | `70` |
| `(1200+800)/3` | `666.666666666667` |
| `@100-30,0` | `@70,0` |
| `100-30<45` | `70<45` |
| `<45` | 原样放行（AutoCAD 原生"只给角度"） |

## 已知限制

- 只拦**底部命令行**。动态输入框（十字光标旁）是 AutoCAD 自绘的原生控件，托管侧没有读写入口，从 0.5.2 起明确不支持。
- 拦截链出错时是"失败关闭"：连败 3 次才关闭，`CLMON` 可恢复。
- 2020、2018、2017、2015–2016 已编译、锚已核对、安装流程已演练，但只有 2024 / 2026 是别人真机跑过的。
- 升级不会清理旧版本留下的 `TRUSTEDPATHS` 条目（卸载时才精确剥离），也不清理 `%LOCALAPPDATA%\CadMathInlineMath\backups\`。

## 完整变更

[v0.5.2...v0.5.3](https://github.com/Oreak-jack/autocad-inline-math/compare/v0.5.2...v0.5.3)
