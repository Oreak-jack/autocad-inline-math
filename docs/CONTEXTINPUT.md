# 语境切换（Oreak Context Input）

一个**独立**的小插件：双击进入文字编辑时，自动把输入法切成中文；退出编辑回到命令提示时，切回英文。它和 CadMath03 共用安装器与发行包，但两者在运行期互不相干。

- 程序集：`Oreak.ContextInput.dll`（宿主）+ `Oreak.ContextInput.Core.dll`（纯策略）
- 版本线：`0.1.8`，与 CadMath03 的版本号各自独立
- 注册项：`HKCU\...\<release>\<product>\Applications\OreakContextInput`
- 默认：**装完即启用**（不需要再输入命令）
- 日志：`%LOCALAPPDATA%\OreakCADTools\logs\contextinput.log`（超过 2 MB 自动轮转）

## 它到底做什么

| 场景 | 行为 |
| --- | --- |
| 双击一段 TEXT / MTEXT / 标注文字进入编辑 | 把输入法切到**中文** |
| 新建 `MTEXT` / `TEXT` / `DTEXT` 正在打字 | 同样切到中文 |
| 退出编辑、回到命令提示或选择对象 | 切回**英文**，避免把命令打成汉字 |
| 双击后编辑器还没出来（候选态） | 等它出现再切，不抢跑 |
| 用户自己按了 Shift 或从托盘切了输入法 | 认定为"人工接管"，这一轮不再对抗 |
| 输入法正在组字 | 不动它，避免打断正在输入的词 |
| 打字要输入 `%%c` `%%d` `%%p`（Ø、°、±） | 临时切英文，打完字立刻切回中文 |

它**不改剪贴板**、**不改 AutoCAD 的安全设置**、**不消费任何按键**——所有判断都发生在 `PreTranslateMessage` 的旁路观察里。

## 怎么用

装好、启动 CAD 就会有提示：`语境切换 0.1.8 已启用：编辑文字时切中文，退出回英文。OCIOFF 停用，OCISTATUS 状态。`

| 命令 | 作用 |
| --- | --- |
| `OCION` | 启用（观察模式关闭，真正动手） |
| `OCIOFF` | 停用；如果此刻正在编辑文字，会先把输入法还原成英文再停 |
| `OCIOBSERVE` | 只记录不干预：按实际行为写日志，方便排查 |
| `OCISTATUS` | 打印启用状态、是否观察模式、符号策略、IME 现场与日志路径 |
| `OCISYMBOLSON` / `OCISYMBOLSOFF` | 打开/关闭 `%%c` 一类符号打字的临时英文模式 |
| `OCITESTDRAWING` | 新建一张测试图并画一个 TEXT、一个 MTEXT，便于验证（不会动你的图） |

排查时先看 `OCISTATUS`，再看日志里最近几行诊断：

```
Editing|editing-mode|mode=Chinese|class=Afx:...|managed=CommandLineTextBox|edit=False|create=False|editorExists=True|selected=True|observe=False
```

- `State|Reason`：状态机当时在哪一步（`DefaultEnglish`、`Candidate`、`Editing`、`Restoring`、`Suspended`）
- `mode`：读取到的输入法状态（English / Chinese / Unknown）
- `class` / `managed`：焦点落在哪个窗口、哪个托管控件上
- `edit` / `create`：当前命令是不是"编辑文字" / "新建文字"
- `editorExists`：`TEXTEDITOR` 系统变量是否打开了在位编辑
- `selected`：开始命令时是否已有选中的文字对象

## 它为什么只认"编辑文字"

AutoCAD 的输入位置有三类：底部命令行、动态输入框、以及在位文字编辑器。前两类是命令输入，必须保持英文（否则 `_LINE` 会变成汉字）；只有第三类是"写内容"，才需要中文。判据因此收得很紧：

1. 必须是 `DDEDIT` / `TEXTEDIT` / `MTEDIT`，或是 `MTEXT` / `TEXT` / `DTEXT` 的创建流程；
2. `TEXTEDITOR` 必须打开（否则双击文字只在命令行里改，不是在位编辑）；
3. 焦点必须在文档窗口或原生 `Edit`/`RichEdit` 控件上，**不在**命令行上。

三条同时成立才切中文；任何一条不成立就当作命令输入，保持英文。

## 边界与已知限制

- 只处理**文字类**对象。属性块、表格单元格、标注文字的在位编辑各版本实现不同，没有逐个验证。
- 依赖 Windows IMM32（`ImmGetContext` / `ImmSetConversionStatus`）。对微软拼音、搜狗、小鹤等标准 IME 有效；某些用 ascii_mode 开关实现的输入法（如 Weasel 0.17）可能表现为"API 成功但输入法没变"，此时 `OCISTATUS` 的 `readback` 会显示不一致，插件不会反复重试（同一轮最多 3 次、间隔 250 ms，之后标记 `Suspended` 不再纠缠）。
- 装在 2015–2026 的七个宿主上，**只有 2026 真机验证过**；旧版本走同一份源码、用对应年份的 SDK 编译，未逐一实测。
- 与 CadMath03 完全解耦：`Oreak.ContextInput.Cad` 不引用 `CadMath.*` 任何工程；安装包里"同一目录放两个 dll"只是为了少一份目录，加载与失败互不影响。

## 卸载

用同一个安装器（菜单 3）卸载即可：`Applications\OreakContextInput` 与 `Applications\CadMathInlineMath` 会被一起清掉。只想停用而不卸载，输入 `OCIOFF`。
