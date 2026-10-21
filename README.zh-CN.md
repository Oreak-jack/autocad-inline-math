# AutoCAD Inline Math — 底部命令栏直接输入四则运算

[下载 v0.3.0 安装包](https://github.com/Oreak-jack/autocad-inline-math/releases/tag/v0.3.0) · [反馈问题](https://github.com/Oreak-jack/autocad-inline-math/issues) · [English](README.md)

在 CAD 原来的底部命令栏直接输入 `100-5`、`(50-10)/2`，回车自动使用结果，不弹计算器。

```text
L 空格 → 鼠标指定起点 → 光标指向画线方向 → 100-5 回车
预期：画出长度 95 的直线
```

**本版面向底部命令栏，光标旁动态输入框关闭的操作方式。** 使用者已确认 v0.3 在其 AutoCAD 2026 环境可用；这不等于所有命令和版本均已完整实测。

## 安装

1. 下载并解压 Release 中的 ZIP。
2. CAD 中按 Esc 结束当前命令，输入 `NETLOAD`，选择 `CadMath03.bundle\Contents\Win64\CadMath03.dll`。
3. 加载后默认开启。首次可能显示未签名文件提示，请自行核对来源；无需关闭 `SECURELOAD`。
4. 按上面的画线步骤试用。Esc 结束后输入 `CM3CHECK`，查看实际线长是否为 95。

### 设置自动启动：AP → 启动组 → 内容 → 添加

设置一次，以后启动 CAD 时自动加载并开启，不必每次输入 `NETLOAD`。

1. 把解压出来的整个 `CadMath03.bundle` 放到 `C:\CadMath03\`，确认 DLL 位于 `C:\CadMath03\CadMath03.bundle\Contents\Win64\CadMath03.dll`。
2. [下载 CadMath03-Startup.lsp](https://raw.githubusercontent.com/Oreak-jack/autocad-inline-math/main/startup/CadMath03-Startup.lsp)，另存为 `C:\CadMath03\CadMath03-Startup.lsp`，注意文件名不能变成 `.lsp.txt`。如果插件放在其他位置，用记事本修改 LSP 中的 DLL 路径，路径分隔符用 `/`。
3. CAD 输入 **`AP` → 回车 →「启动组」中的「内容…」→「添加…」**，选中 `CadMath03-Startup.lsp`，点击「打开」，确认它出现在启动组列表中，再关闭两个窗口。如果 `AP` 别名无效，输入完整命令 `APPLOAD`。
4. 若出现可信位置提示，在 `OPTIONS` →「文件」→「可信任的位置」中添加你自己的插件目录。不要全局关闭安全加载。
5. 保存图纸后关闭并重新启动 CAD，打开图纸，输入 `CM3STATUS` 检查是否开启；再按上面的画线流程输入 `100-5`，用 `CM3CHECK` 检查线长。

**启动组里添加的是配套 `.lsp` 引导文件。** 本插件本体是 .NET DLL，通过引导文件中的 `NETLOAD` 加载，不要直接把 DLL 当成 LSP 加入启动组。该启动组引导方式尚未单独在 CAD 中实测，请按第 5 步验证；当前会话仍可使用上面的手动 `NETLOAD`。

另一种自动加载方式：把整个 `CadMath03.bundle` 复制到 `%APPDATA%\Autodesk\ApplicationPlugins\`，保存图纸后重启 CAD。两种自动加载方式选一种即可。

取消启动组自动加载：`AP` →「启动组」→「内容…」→ 选中 `CadMath03-Startup.lsp` →「删除」；当前会话输入 `CM3OFF` 即可停用。

### 开关命令

- `CM3OFF`：立即停用。
- `CM3ON`：重新启用。
- `CM3STATUS`：查看状态、最后错误和日志路径。
- `CM3CHECK`：若最后图元为直线，读取其实际长度。

本版加载时会停用此前私人测试用的 CadMath/CadMathNative 插件；已放入启动目录的旧包仍应移走，避免加载顺序冲突。

## 支持范围

Windows x64，完整版 AutoCAD 2025/2026，目标 .NET 8。2025/2026 接口均已编译通过；2025 实际运行、其他机器及后续运行时更新仍需验证。不支持 LT、macOS、网页版。

支持 `+ - * /`、括号、正负号、小数、科学计数法和坐标分量计算，如 `@100-5,20/2`。英文半角、小数点用句点，表达式内部不要加空格，因为空格也是提交键。

实现的命令白名单：LINE、PLINE、CIRCLE、ARC、RECTANG、OFFSET、MOVE、COPY、ROTATE、SCALE、STRETCH、FILLET、CHAMFER、POLYGON、ELLIPSE。白名单代表代码尝试接管的范围，不代表全部通过原生验收。

不支持特性面板、对话框、文字编辑器、第三方命令或光标旁动态输入。暂不支持单位后缀、英尺英寸字符串、变量、函数及球坐标。图纸单位和坐标语义仍由 CAD 处理。

数值范围：零或绝对值 `1e-12` 至 `1e15`，最长 512 字符，最多 32 层嵌套。整数输入要求结果为 32 位整数。

## 验证与排错

在新图中分别测试 `100-5`（95）、`(50-10)/2`（20）、普通数字、鼠标取点、退格修改、Esc、撤销，再试自己需要的命令。

除零等错误会阻止提交并发出提示音；意外异常时插件自动停用。日志位于 `%TEMP%\CadMath03.log`，上限约 1 MB。日志可能包含输入的数字表达式，公开反馈前请自行检查。

`replacement_requested` 仅表示请求替换输入；`CM3CHECK` 输出的 `last LINE length=95` 才是从 CAD 图元读回的长度。541 项解析测试和 29 项输入分流测试不能替代原生操作验收。[详细验证记录](docs/VALIDATION.md)

## 源码

实现采用 AutoCAD 输入提示事件和实际 InputBuffer，回车前替换输入队列，再保留 CAD 原来的回车流程。没有独立计算窗口、全局模拟按键或异步命令字符串。UIBindings 接口仍依赖宿主实现，版本更新后可能需要调整。

编译方法见 [English README](README.md#build-and-tests)。仓库不包含 Autodesk DLL、SDK、用户图纸或本机日志。许可证：[MIT](LICENSE)。本项目与 Autodesk 无隶属或背书关系。
