# CadMath03 0.4.0 · 分层重写，去掉安装器

在 AutoCAD 命令行里直接写算式：`100-30` 回车变 `70`，`@100-30,0` 变成相对坐标 `@70,0`。

这一版**没有新增功能**，做的是内部结构：把 0.3.3 里那个身兼入口、命令、键盘拦截、状态机、日志、焦点探测的 `Plugin.cs` 拆成各管一段的模块，并去掉 470 行的 PowerShell 安装器。对你唯一可见的变化是**装法变简单了**，以及两个老毛病被修掉。

---

## 安装（3 步，不需要管理员权限）

1. **完全退出 AutoCAD**（DLL 已被进程占用，覆盖不会生效）
2. 解压，把 `CadMath03.bundle` 整个目录放到 `%APPDATA%\Autodesk\ApplicationPlugins\`

   ```powershell
   Expand-Archive .\CadMath-InlineMath-0.4.0.zip -DestinationPath $env:TEMP\cadmath -Force
   Copy-Item -Recurse -Force "$env:TEMP\cadmath\CadMath03.bundle" "$env:APPDATA\Autodesk\ApplicationPlugins\"
   ```

3. 启动 AutoCAD，命令行输入 `CM3STATUS`，看到下面这行就成功了：

   ```
   CadMath 0.4.0 开启=True 适配器=modern-r25 宿主=R25.1 替换请求=0 最后错误=-
   ```

不需要改注册表、不需要 `NETLOAD`、不需要 `APPLOAD`，AutoCAD 启动时会自己从 `ApplicationPlugins` 加载。

**卸载**：关闭 AutoCAD，删除 `%APPDATA%\Autodesk\ApplicationPlugins\CadMath03.bundle` 即可，不留残余。

---

## 从 0.3.3 升级

- 直接覆盖同一个目录。`ProductCode` / `UpgradeCode` 保持不变，注册表里指向的 DLL 路径也没变。
- 0.3.3 安装器留下的 `.CadMath-backup-*` 备份目录不再被使用，可以删掉。
- 想回退到 0.3.3：删掉新目录，用 0.3.3 的安装器重装。

---

## 本版变化

**结构**

- 拆成 5 个工程：`CadMath.Core`（表达式与判定）、`CadMath.Abstractions`（契约、适配器清单、版本选择）、`CadMath.Shell`（入口与 CM3 命令）、`CadMath.Adapter.Modern`（R25 输入拦截）、`CadMath.Adapter.Legacy`（R24 占位）。
- 适配器清单 `adapters.json` 决定加载哪个适配器：按 CAD 版本区间匹配、按优先级排序，每个适配器装进独立的可卸载加载上下文。
- 版本号只在 `Directory.Build.props` 里写一次，打包时注入 `PackageContents.xml`。

**修复**

- **一次回车被处理两次**：`WM_KEYDOWN` 与 `WM_CHAR` 都会触发替换，第二条消息读到的是尚未刷新的旧文本，于是同一个算式被算了两次。现在按一次按键只替换一次。
- **`CM3STATUS` 一直显示旧错误**：替换成功后错误信息没有清空，导致后面若干次成功操作仍报同一个错误。

**新增**

- `CM3CHECK`：输入算式后执行，选中最近创建的实体并输出长度，用于自检。
- 日志里每条替换记录带上触发消息类型（`msg=0x100` / `msg=0x102`），排查"按一下动两次"这类问题更快。

**兼容性**

- AutoCAD 2025 / 2026（`R25.0` / `R25.1`），需要 .NET 8 运行时。
- AutoCAD 2024 及更早版本：**暂不支持**。适配器接口已就位，`adapters.json` 里留了 `legacy-r24` 占位，加载时会明确提示"尚未实现"而不是静默失败。
- 与 0.3.3 的行为逐条对拍：617 条断言（数学 541 / 路由 45 / 宿主与清单选择 31）全部一致。

---

## 交付物校验

```
文件：CadMath-InlineMath-0.4.0.zip
大小：33,394 字节（32.6 KB）
SHA256：9BB3EBC38A975A1BF430AEADF365DD671B74AF7FC3B61C36EB897D8E877463A7
```

```powershell
Get-FileHash .\CadMath-InlineMath-0.4.0.zip -Algorithm SHA256
```

包内结构：

```
CadMath03.bundle/
  PackageContents.xml
  BUILD-INFO.txt
  Contents/Win64/
    CadMath03.dll
    CadMath.Core.dll
    CadMath.Abstractions.dll
    adapters.json
    Adapters/CadMath.Adapter.Modern.dll
    Adapters/CadMath.Adapter.Legacy.dll
```

---

## 命令

| 命令 | 作用 |
|---|---|
| `CM3ON` | 启用拦截（异常后自动关闭时用它恢复） |
| `CM3OFF` | 关闭拦截 |
| `CM3STATUS` | 显示版本、启用状态、当前适配器、识别到的 CAD 版本、替换次数、最后错误、被排除的适配器及原因 |
| `CM3CHECK` | 自检：选中最近创建的实体，若是直线则输出其长度（`G17` 精度） |

## 支持的写法

```
100-30          → 70
(1200+800)/3    → 666.666666666667
2*3.5e2         → 700
10+5,20*2       → 15,40          （坐标）
100-30<45       → 70<45          （距离<角度）
@100-30,0       → @70,0          （相对坐标）
#10*2,5         → #20,5          （绝对坐标）
```

限制：单个表达式最长 512 字符、括号嵌套最多 32 层、结果绝对值需落在 `1e-12` ~ `1e15` 之间。整数类提示（如 `POLYGON` 的边数）要求结果本身就是整数，`50/2` 可以，`10/3` 不会替换也不会四舍五入。

---

## 已知限制

- 只在**底部命令行**生效；浮动命令行面板和多行编辑框不在支持范围内（这是 0.3.3 就有的限制，本版未改）。
- 遇到非预期异常时选择**关闭拦截**而不是带病工作，需要 `CM3ON` 手动恢复；日志在 `%TEMP%\CadMath03.log`。
- 适配器的可卸载加载上下文只做了"能加载"，热卸载/热更新未在真机验证。
- 不含安装器、自动更新、多版本并行安装（这些留给下一阶段）。

---

## 完整变更

- 提交历史：<https://github.com/Oreak-jack/autocad-inline-math/compare/v0.3.3...v0.4.0>
- 架构设计：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 实施记录（0.3.3 → 0.4.0 逐项映射、不变式、验证过程）：[docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md)
