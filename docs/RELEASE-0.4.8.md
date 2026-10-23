# CadMath03 0.4.8 · 安装器版本号跟着发行包走

0.4.8 只动安装器的一处显示问题，插件本身（三个宿主、拦截行为、数学能力）与 0.4.7 完全一致。

---

## 修了什么

0.4.7 的包里，安装器横幅和日志印的是 `v0.4.5`——那是脚本里的编译期常量，一直没跟着版本号走。
你在 0.4.7 上安装时看到的 `CadMath 安装与更新工具 v0.4.5` 就是这个原因，装出来的插件其实是 0.4.7。

0.4.8 改成：启动时读发行包根目录的 `setup.json`，取其中的 `toolVersion` 作为工具版本；读不到才退回常量。
所以横幅、日志、`setup.json` 三处的版本号从此不可能再各说各话。

```text
 CadMath 安装与更新工具 v0.4.8
[2026-10-23 16:31:38] [INFO] [START] 程序启动，工具版本 0.4.8
[2026-10-23 16:31:38] [INFO] [VERIFY] 逐文件校验通过：31 个文件
[2026-10-23 16:31:38] [INFO] [VERIFY] 包校验通过：CadMath03 0.4.8，运行时清单 1 个适配器
[2026-10-23 16:31:38] [INFO] [DONE] 安装完成：0.4.8，1 个实例
```

## 从 0.4.7 升级

0.4.7 的菜单 2 是可用的，直接选 `2` 即可自助更新。
从 0.4.5 及更早版本上来的，仍需手动解压 zip 跑菜单 `1` 一次（0.4.5 与更早的更新流程是坏的）。

## 验证

- `tools/setup/tests/Test-Setup.ps1`：`通过 35 项，失败 0 项`（CAD 已关闭，「拒绝在 CAD 运行时安装」那条按设计跳过）
- `tests/CadMath.Tests`：`checks=623 failures=0`
- 本机实测：从 0.4.7 升到 0.4.8，`LOADER` 指向 `payload\0.4.8\Contents\Win64\CadMath03.dll`，文件版本 `0.4.8.0`

## 交付物校验

```text
2ac02a7d0dedc91ffae51ae424bbeeedcfef7785f88e79debbb7e093f0f84dc0  CadMath-InlineMath-0.4.8.zip
cfa88f44a1fb175b6dbe85dccf79dd239b962e3319ebde30449fe8b718dafc10  CadMath-InlineMath-0.4.8-experimental.zip
9500a9a1481c943df49a1f37b3180e58ed64de9e4609da3762f04f2c5b29abf9  setup.json
```

## 已知限制

- 2020 仍是实验性支持：代码与安装流程已就绪，还没有真机反馈。
- 2021–2023 用同一份 24.3 编出的宿主，按官方兼容表覆盖 2021–2024，但没有逐一实跑。
- 升级到新版本后，`TRUSTEDPATHS` 里会留下一两条指向旧 payload 的失效路径（卸载时才精确清理），不影响功能。
- 只拦截底部命令行；浮动命令面板、对话框、快捷键宏不生效。

## 完整变更

- `v0.4.8` 与 `v0.4.7` 之间：<https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.7...v0.4.8>
- 全部提交：<https://github.com/Oreak-jack/autocad-inline-math/commits/main>
- 架构说明：[docs/ARCHITECTURE.md](ARCHITECTURE.md)
- 安装器细节：[docs/INSTALLER.md](INSTALLER.md)