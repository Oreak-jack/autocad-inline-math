# CadMath03 0.4.3 · AutoCAD 2024 正式支持

0.4.2 把 2024 的宿主（.NET Framework 4.8）放进了同一个包，但适配器状态停在 `planned`——正式包不给 2024 装。
这一版把它打开：`legacy-r24` 已经是 `host-tested`，装完就能在 2024 上用。

真机验证过的行为与 2025/2026 一致：

- 底部命令行输入 `100-30` 回车 → 变成 `70`
- 坐标 `10+5,20*2` → `15,40`，极坐标 `100-30<45` → `70<45`，`@` / `#` 前缀照常
- 一次按键只处理一次（日志里 `msg=0x100` 单条）
- `CM3PROBE` 能读出宿主 release、acmgd 版本、活动适配器与焦点类型

## 安装

关掉 AutoCAD，解压，双击 `CadMath-Setup.cmd` → 选 `1`：

```
[SCAN]  已发现 1 个 CAD 实例（AutoCAD 2024 - 简体中文，R24.3，构建 24.3.xxx）
[MATCH] 计划安装到 1 个实例：AutoCAD 2024 → legacy-r24
[REGISTER] 已注册 AutoCAD 2024（Contents\Win64-2024\CadMath03.dll）
[DONE]  安装完成：0.4.3，1 个实例
```

2024 的 `LOADER` 指向 `Contents\Win64-2024\CadMath03.dll`，2025/2026 指向 `Contents\Win64\CadMath03.dll`，
同一个包、两条路径、互不影响。已经装了 0.4.1 / 0.4.2 的，菜单 `2`（检查更新并安装）会原地升级。

## 校验

```
938433bd696080b57f22805840f4184099f7b95598320c8ba662864294978403  CadMath-InlineMath-0.4.3.zip
```

```powershell
Get-FileHash .\CadMath-InlineMath-0.4.3.zip -Algorithm SHA256
```

## 本版变化

- `adapters/adapters.json`：`legacy-r24` 的 `status` 从 `planned` 改为 `host-tested`（`verified: true`）
- 版本号统一升到 0.4.3（`Directory.Build.props` 是唯一来源）
- 文档：README 的"AutoCAD 2024（实验版）"改为正式支持；`docs/ARCHITECTURE.md` 第 10 节把"编译期结论、
  运行期待验证"改成已验证事实；`docs/INSTALLER.md` 的实验包说明改为"供以后接入更老版本用"
- 无功能改动、无行为改动：0.4.2 的实验包与 0.4.3 正式包跑的是同一份 2024 代码，差别只在清单里的一个状态字段

## 命令

| 命令 | 作用 |
| --- | --- |
| `CM3ON` | 重新开启（适配器故障关闭后用它恢复） |
| `CM3OFF` | 关闭 |
| `CM3STATUS` | 开关状态、活动适配器、替换次数、最后错误、日志路径 |
| `CM3CHECK` | 读上一次选中 LINE 的长度 |
| `CM3PROBE` | 宿主与适配器诊断（release、acmgd 版本、绑定解析、焦点类型） |

## 已知限制

- 支持范围是 2024 ~ 2026（R24.0 ~ R24.3、R25.0、R25.1）；2023 及以前还没做，接入方式见 README 的"新增适配器"
- 命令白名单仍是适配器内的 15 个命令（`LINE` `PLINE` `CIRCLE` `ARC` `RECTANG` `OFFSET` `MOVE` `COPY`
  `ROTATE` `SCALE` `STRETCH` `FILLET` `CHAMFER` `POLYGON` `ELLIPSE` `LENGTHEN`）
- 只支持底部命令行；浮动的命令行窗口与国际化版本还没验证
- 如果日志里出现成对的 `replacement_requested`，说明同时加载了两份插件（多半是手动 `NETLOAD` 了旧 DLL）

## 完整变更

https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.2...v0.4.3
