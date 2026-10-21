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

每次启动自动加载：把整个 `CadMath03.bundle` 复制到 `%APPDATA%\Autodesk\ApplicationPlugins\`，保存自己的图纸后重启 CAD。

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
