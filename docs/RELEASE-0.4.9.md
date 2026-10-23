# CadMath03 0.4.9 · 修掉"从浏览器下载的包装到 2024 上加载失败"

0.4.9 只改一件事：**安装器现在会在把文件放进负载目录时，抹掉 Windows 给下载文件加的"来自网络"标记**。

## 这次修的是什么

有人在 2024 上遇到：安装器一路报成功、注册表也对，但 CAD 里 `CM3ON`、`CM3STATUS`、`CM3CHECK` 全都没有。

手动 `NETLOAD` 会得到真正的报错：

```text
System.IO.FileLoadException: 未能加载文件或程序集
  "...\payload\0.4.8\Contents\Win64-2024\CadMath03.dll" 或它的某一个依赖项。不支持操作。
  (异常来自 HRESULT: 0x80131515)
  内层: System.NotSupportedException: 尝试从一个网络位置加载程序集...
        请启用 loadFromRemoteSources 开关
```

原因不在代码、不在版本、也不在注册项：浏览器下载的 zip 解压出来的文件带有 `Zone.Identifier`
数据流（"来自网络"标记），.NET Framework 因此拒绝 `Assembly.LoadFrom` 加载它。
本机用命令行下载安装时没有这个标记，所以 2026 那台一直正常 —— 这条路径直到 2024 那台才暴露。

## 安装方式

1. 关闭 AutoCAD（安装器检测到进程会拒绝执行）。
2. 完整解压 `CadMath-InlineMath-0.4.9.zip`。
3. 双击解压后的 `CadMath-Setup.cmd`，选 `1` 安装。

已装 0.4.8 的机器可以直接在工具里选 `2` 检查更新升级（会走同样的负载落位流程，因此同样带上这次修复）。

## 本版变化

- **修复**：`Expand-CadBundleArchive` 解压后、`Copy-BundleToPayload` 复制后、`Install-CadMathGlobalBundle`
  复制后，都会调用新增的 `Clear-NetworkMark`。日志里会出现
  `[UNBLOCK] 已解除 N 个文件的"来自网络"标记（否则 .NET Framework 会拒绝加载）`。
- **测试**：新增回归用例 —— 给三个 bundle 的全部 dll 人为写上 `Zone.Identifier`，
  再走安装流程，断言负载目录里没有任何文件还留着该标记。安装器测试 37 项全过。
- 其余行为与 0.4.8 一致。

## 已经装坏的那台怎么救

不用重装，先关 CAD，然后在 PowerShell 里执行：

```powershell
Get-ChildItem "$env:LOCALAPPDATA\CadMathInlineMath\payload" -Recurse -File | Unblock-File
```

再启动 CAD 即可加载。之后升级到 0.4.9 就不会再复发。

也可以用更彻底的办法：重新下载 zip 后，在解压**之前**右键 zip → 属性 → 勾选"解除锁定" → 确定，再解压安装。

## 校验值

```text
fe99fbd61a7dc1bcd57ed2ac4778dc915c8b324c2939553cfdeae6fe667f3d0a  CadMath-InlineMath-0.4.9.zip
333de0d343b4d2fe62680939eb847f3ff22e239dd7293491d9adc519a410136f  CadMath-InlineMath-0.4.9-experimental.zip
435d14628f8c7113adccc2d80bbb84360db00dbf4548c0472caac1c6297a082b  setup.json
```

## 包内结构

```text
CadMath-InlineMath-0.4.9.zip
  CadMath-Setup.cmd                 启动器（命令行安装器）
  setup.json                        发行清单（版本、适配器、逐文件 SHA-256）
  tools/setup/...                   PowerShell 安装器实现
  CadMath03.bundle/                 主包：Contents/Win64（.NET 8）、Win64-2024、Win64-2020
  CadMath03-2024.bundle/            ApplicationPlugins 全局模式用的 2024 包
  CadMath03-2020.bundle/            全局模式用的 2020 包（实验）
  SHA256SUMS.txt
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `CM3ON` / `CM3OFF` | 打开 / 关闭底部命令栏计算 |
| `CM3STATUS` | 版本、宿主、当前适配器、替换次数、最后的错误与日志路径 |
| `CM3CHECK` | 选中一条直线，写一行长度到日志（回归测试用） |
| `CM3PROBE` | 打印宿主 release、acmgd 版本、焦点类型、命令行编辑器绑定状态 |

## 支持的写法

```text
100-30                  → 70
(1200+800)/3            → 666.666666666667
2*3.5e2                 → 700
10+5,20*2               → 15,40
100-30<45               → 70<45
@100-30,0               → @70,0
#10*2,5                 → #20,5
<-30  @<45  #<45        → 原样放行（0.4.5 起）
```

只在底部命令行、且处在 15 个允许命令（LINE / PLINE / CIRCLE / ARC / RECTANG / OFFSET / MOVE / COPY /
ROTATE / SCALE / STRETCH / FILLET / CHAMFER / POLYGON / ELLIPSE / LENGTHEN）的数值输入阶段生效。

## 已知限制

- 2020（R23.1）仍是**实验性支持**（编译与安装流程已验证，待真机确认）。
- 2021–2023 用的是与 2024 同一份 24.3 宿主，按官方兼容表应当可用，但未逐一实跑。
- 只在底部命令行生效；动态输入提示框、特性面板等位置不拦截。
- 适配器内部异常会关闭拦截并把原因写进日志，只能 `CM3ON` 恢复。

## 完整变更

- 对比上一版：<https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.8...v0.4.9>
- 提交记录：<https://github.com/Oreak-jack/autocad-inline-math/commits/main>
