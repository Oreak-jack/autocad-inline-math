# CadMath03 0.4.11 · 覆盖范围下探到 AutoCAD 2015

0.4.11 没有新功能，只做一件事：把 0.4.10 定下的"一个版本带一份宿主"补到更老的 CAD 上——
新增 **2018、2017、2015–2016** 三个版本带，覆盖范围从 2021 起下探到 **2015**。

## 安装

1. 下载 `CadMath-InlineMath-0.4.11.zip`，**完整解压**（不要只在压缩包里双击）。
2. 关掉所有 AutoCAD。
3. 双击解压目录里的 `CadMath-Setup.cmd`，输入 `1` 回车。

装完后在 CAD 里试一句 `100-30` 加回车，半径/长度会变成 `70`；`CM3STATUS` 看状态，
`CM3PROBE` 看适配器到底挂上了没有。

已经装着 0.4.10 的机器可以在工具里输入 `2` 直接升级（同样要先关 CAD）。

## 本版变化

| 版本带 | 覆盖 AutoCAD | 编译基准 | 适配器 | 宿主目录 |
|---|---|---|---|---|
| R22.0 | 2018 | `22.0.0` | `legacy-r22` | `Contents/Win64-2018` |
| R21.0 | 2017 | `21.0.2` | `legacy-r21` | `Contents/Win64-2017` |
| R20.0 / R20.1 | 2015–2016 | `20.1.0` | `legacy-r20` | `Contents/Win64-2015` |

- 三个新宿主都是 `.NET Framework 4.8`，与 2021–2024 那套共用同一份拦截源码（`KeystrokeAdapter`），
  只是各自按所在版本带的**最旧 SDK** 编译。
- 拦截逻辑补了一条**焦点判定兜底**：先看是不是底部命令行那个 WPF 文本框（新版本走这条，行为不变）；
  不是的话再按窗口类名判断（`acautocomp` / `accmdlineui` / `acdyninput` / `dyninput` / `#32768` / `tooltip_class32`），
  用来兜住老版本上取不到那个 WPF 类型的情况。
- 这三个适配器在清单里是 `built`：编译、引用版本核对、安装流程都过了，但**没有真机回执**。
  状态 `host-tested` 要等有人在对应版本里跑通 `CM3PROBE` 与 `100-30`。

> 为什么不再往下做 2007–2014？`CadMath.Core` 与 `CadMath.Abstractions` 是 `netstandard2.0`，
> 运行下限是 **.NET Framework 4.6.1**（≈ AutoCAD 2015）。更老的 CAD 跑在 .NET 2.0–4.0 上，需要另起一套不依赖
> netstandard 的核心程序集，那是另一个量级的改造。

## 交付物校验

```
CadMath-InlineMath-0.4.11.zip
SHA-256 4c9c8ea4343c7d3ebd0c0e294d09fc01c4dc606ca840ca3d2ae7900bd93b85f8
```

`setup.json` 与 `SHA256SUMS.txt` 一并放在 Release 附件里，安装器每次安装前会逐文件核对里面的 SHA-256。

## 包内结构

```
CadMath-Setup.cmd                 安装器启动器（纯 ASCII + CRLF）
setup.json                        发行清单（hosts / files / adapters）
tools/setup/…                     命令行安装器本体
CadMath03.bundle/Contents/
  Win64/                          2026（.NET 8，编译基准 25.1.0）
  Win64-2025/                     2025（.NET 8，编译基准 25.0.1）
  Win64-2024/                     2021–2024（4.8，编译基准 24.0.0）
  Win64-2020/                     2020（4.8，编译基准 23.1.0）
  Win64-2018/                     2018（4.8，编译基准 22.0.0）
  Win64-2017/                     2017（4.8，编译基准 21.0.2）
  Win64-2015/                     2015–2016（4.8，编译基准 20.1.0）
CadMath03-2025.bundle/ … -2015.bundle/    各代专用 bundle（ApplicationPlugins 全局安装用）
```

安装器按检测到的实例系列选入口 DLL，多个版本可以同时装、互不影响。

## 命令

| 命令 | 作用 |
|---|---|
| `CM3ON` / `CM3OFF` | 打开 / 关闭底部命令行计算 |
| `CM3STATUS` | 版本、是否开启、绑定的适配器、宿主、已替换次数、最后错误、日志路径 |
| `CM3CHECK` | 选中对象后报告长度（只对直线输出） |
| `CM3PROBE` | 诊断：宿主版本、适配器、焦点类型、命令行绑定是否可用 |

## 支持的写法

| 输入 | 结果 |
|---|---|
| `100-30` | `70` |
| `(1200+800)/3` | `666.666666666667` |
| `2*3.5e2` | `700` |
| `10+5,20*2` | `15,40` |
| `100-30<45` | `70<45` |
| `@100-30,0` | `@70,0` |
| `<-30`、`<45` | 原样放行（AutoCAD 原生的"只给角度"） |

## 已知限制

- 只有底部命令行里的输入会被拦；动态输入提示框里的不算。
- 只拦白名单命令（`LINE` `PLINE` `CIRCLE` `ARC` `RECTANG` `OFFSET` `MOVE` `COPY` `ROTATE` `SCALE`
  `STRETCH` `FILLET` `CHAMFER` `POLYGON` `ELLIPSE` `LENGTHEN`）的数值提示。
- 适配器内部异常即关闭计算并写日志，需要 `CM3ON` 恢复（fail-closed）。
- 升级不会清理旧版本的负载目录与旧 `TRUSTEDPATHS` 条目，卸载时才清。
- 2020 与新增的 2018 / 2017 / 2015–2016 都还没有真机回执。

## 完整变更

https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.10...v0.4.11
