# CadMath03 0.4.4 · AutoCAD 2020（实验性）

0.4.3 之后收到最多的一个请求是"再往前能不能用"。这一版先把 2020 做出来：

- 新增第三份宿主 `Contents/Win64-2020`，用 `AutoCAD.NET 23.1.0`（.NET Framework 4.8）编译
- 新增适配器 `legacy-r23`，与 2024/2026 共用同一份 `KeystrokeAdapter` 源码
- 状态仍是 `planned`：正式包**不会**把它装到 2020 上，要用实验包才能装

这么保守是因为它还没在真实 AutoCAD 2020 上跑过。编译、打包、安装器选路都已经验证，缺的只是一次实机回执。

## 安装（2024 / 2025 / 2026）

和以前一样：关掉 AutoCAD，解压，双击 `CadMath-Setup.cmd` → 选 `1`。已装旧版的，菜单 `2`
（检查更新并安装）会原地升级到 0.4.4。

```
[SCAN]  已发现 1 个 CAD 实例（AutoCAD 2026 - 简体中文，R25.1，构建 25.1.60.0）
[MATCH] 计划安装到 1 个实例：AutoCAD 2026 → modern-r25
[REGISTER] 已注册 AutoCAD 2026（Contents\Win64\CadMath03.dll）
[DONE]  安装完成：0.4.4，1 个实例
```

## 安装（2020，需要实验包）

下载 `CadMath-InlineMath-0.4.4-experimental.zip`，解压后同样双击 `CadMath-Setup.cmd`：

```
[SCAN]  已发现 1 个 CAD 实例（AutoCAD 2020 - 简体中文，R23.1）
[MATCH] 计划安装到 1 个实例：AutoCAD 2020 → legacy-r23
[REGISTER] 已注册 AutoCAD 2020（Contents\Win64-2020\CadMath03.dll）
[DONE]  安装完成：0.4.4，1 个实例
```

装好后请回执四件事：

1. 启动 2020 时命令行有没有出现 `CadMath 0.4.4 底部命令栏计算已启用。关闭：CM3OFF；状态：CM3STATUS。`
2. `CM3PROBE` 的完整输出（`host=` / `clr=` / `adapter=` / `binding=` 与焦点类型）
3. `LINE` 第一个点之后输入 `100-30`，回车后是否变成 `70`
4. `%TEMP%\CadMath03.log` 末尾几行

四项都对，就把 `adapters/adapters.json` 里 `legacy-r23` 的 `status` 改成 `host-tested` 并发下一版。

## 校验

```
053b71dc7ffd4242791fc31a8f01930eeed143001a384cf879ed6335bfcd29aa  CadMath-InlineMath-0.4.4.zip
```

```powershell
Get-FileHash .\CadMath-InlineMath-0.4.4.zip -Algorithm SHA256
```

## 包内结构

```
CadMath03.bundle/
  PackageContents.xml                  Series R25.0 ~ R25.1
  Contents/Win64/                      .NET 8       2025 / 2026
  Contents/Win64-2024/                 .NET 4.8     2021 ~ 2024（编译基准 24.3）
  Contents/Win64-2020/                 .NET 4.8     2020（编译基准 23.1）
CadMath03-2024.bundle/                 2021–2024 专用（ApplicationPlugins 全局安装）
CadMath03-2020.bundle/                 2020 专用（同上）
setup.json                             发行清单（hosts[] 按系列选入口）
tools/setup/                           安装器
```

三个宿主各自带一份 `CadMath.Core.dll` 与 `CadMath.Abstractions.dll`——同一套源码，按不同 SDK 各编一次。

## 命令

| 命令 | 作用 |
| --- | --- |
| `CM3ON` | 重新开启拦截（适配器异常后需要它恢复） |
| `CM3OFF` | 暂停拦截，输入原样交给 CAD |
| `CM3STATUS` | 开关、活动适配器、宿主版本、已替换次数、最后一次错误、日志路径 |
| `CM3CHECK` | 读上一次选中 LINE 的长度 |
| `CM3PROBE` | 打印宿主与适配器诊断（release、acmgd 版本、绑定解析、焦点类型） |

## 支持的写法

```
100-30            → 70          长度、半径、直径、距离
(1200+800)/3      → 666.666666666667
10+5,20*2         → 15,40       点坐标（x,y 或 x,y,z）
100-30<45         → 70<45       极坐标（距离<角度）
@100-30,0         → @70,0       相对
#10*2,5           → #20,5       绝对
```

限制：单个表达式 512 字符、嵌套 32 层、结果 1e-12 ~ 1e15；`10/3` 在整数提示下会被拒绝而不是取整；
含字母或以 `(` 开头的输入原样放行，LISP 不受影响。

## 已知限制

- 只支持底部命令行，不支持浮动命令行面板与对话框。
- 适配器异常时保护性关闭拦截（fail closed），需手动 `CM3ON`。
- 2020 为实验性支持；2021–2023 用同一份 24.3 宿主，按官方兼容表应当可用但未逐一实跑。
- 更新只走 GitHub Releases，网络不可用时安装与卸载仍然可用。

## 完整变更

- [`v0.4.3...v0.4.4`](https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.3...v0.4.4)
- [安装器文档](https://github.com/Oreak-jack/autocad-inline-math/blob/v0.4.4/docs/INSTALLER.md)
- [架构说明](https://github.com/Oreak-jack/autocad-inline-math/blob/v0.4.4/docs/ARCHITECTURE.md)
