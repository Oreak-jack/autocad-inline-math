# CadMath03 0.4.7 · 菜单 2 现在会告诉你它在干什么

0.4.7 只动安装器界面，插件本身（三个宿主、拦截行为、数学能力）与 0.4.6 完全一致。

---

## 为什么改

之前点菜单 `2`，回车之后屏幕会一动不动好几秒：请求 GitHub、下载十几 KB 的清单、
再下载两百多 KB 的安装包，全程没有任何输出。分不清"在干活"还是"已经卡死"。

## 现在长这样

```text
  1/5 连接与版本查询
        网络可达
  请求 https://api.github.com/repos/Oreak-jack/autocad-inline-math/releases/latest
    （最长等待 20 秒，失败会自动重试）
    → 完成，用时 0.7 秒
        发行版：v0.4.7
  2/5 下载并校验清单 setup.json
        下载 setup.json（12 KB）
    已下载 12 KB / 12 KB（100%）
  下载完成：12 KB，用时 0.0 秒
        清单 OK：v0.4.7，3 个适配器，31 个文件校验值
发现新版本 v0.4.7（当前 未安装）
[更新说明（节选）]
  ▸ CadMath03 0.4.7 · 菜单 2 现在会告诉你它在干什么
  ...
下载并安装这个更新？ [y/N]：y
  3/5 下载安装包
[UPDATE] 下载 CadMath-InlineMath-0.4.7.zip（215 KB）
    已下载 215 KB / 215 KB（100%），839 KB/s
  下载完成：215 KB，用时 0.3 秒
  4/5 解压、逐文件校验、替换负载并注册
[EXTRACT] 解压安装包：CadMath-InlineMath-0.4.7.zip
[VERIFY] 逐文件校验 31 个文件…
[VERIFY] 逐文件校验通过：31 个文件
[MATCH] 计划安装到 1 个实例：AutoCAD 2026 → modern-r25
[COPY] 负载已暂存：...\payload\0.4.7.stage-<事务号>
[REGISTER] 已注册 AutoCAD 2026（Contents\Win64\CadMath03.dll）
[DONE] 安装完成：0.4.7，1 个实例
更新成功：v0.4.7。请重启 AutoCAD 后输入 CM3STATUS 确认。
```

下载改成自己读响应流、每 0.4 秒刷新一行"已下载 X / Y（百分比），速度"；
请求失败会写明"第 N 次失败：原因"和"2 秒后重试"，不会再静默等待。

## 下载之后到底做了什么

1. 下载的 zip 落在 `%TEMP%\cadmath-update-<随机>`，**不在**用户目录里乱放；
2. 解压到同一临时目录，按 `setup.json` 的 `files[]` 逐个算 SHA-256（31 个文件）；
3. 校验 `PackageContents.xml` 的版本与程序集版本一致；
4. 给每个实例选适配器（`modern-r25` / `legacy-r24` / `legacy-r23`），任一实例不匹配就整体不落地；
5. 记注册表快照 → 写 `pending.json` → 新负载解到 `payload\<版本>.stage-<事务号>`；
6. 旧负载移进 `%LOCALAPPDATA%\CadMathInlineMath\backups\<时间戳>-<事务号>\`；
7. 新负载落位 → 逐实例写 `HKLM/HKCU` 注册项并回读确认 `LOADER` 文件存在；
8. 写 `state.json` → 清 `pending.json` → 删掉临时目录。

中途任何一步失败：恢复注册表快照、删新负载、把旧负载从备份移回，并明确告诉你回滚成功还是失败。

## 从 0.4.6 升级

直接在工具里选菜单 `2` 即可（0.4.6 的更新流程已经修好）。0.4.5 及更早仍是坏的，请手动解压 zip 选菜单 `1`。

## 验证

- `tools/setup/tests/Test-Setup.ps1`：`通过 36 项，失败 0 项`
- `tests/CadMath.Tests`：`checks=623 failures=0`
- 端到端：对真实 GitHub 发行版跑了一遍菜单 2，全程可见进度，`更新成功：v0.4.7`

## 交付物校验

```text
8a5a0e329b97472588a9f04d001bb2273005211a4f2415a5c8679e24d2ae2dc2  CadMath-InlineMath-0.4.7.zip
3317ede66a5f4e65011a1bafad1f40a1a970349fc051ee45e8612989ddef6575  CadMath-InlineMath-0.4.7-experimental.zip
```

`setup.json` 的校验值见同目录的 `SHA256SUMS.txt`。

## 已知限制

- 2020 仍是实验性支持：代码与安装流程已就绪，还没有真机反馈。
- 2021–2023 用同一份 24.3 编出的宿主，按官方兼容表覆盖 2021–2024，但没有逐一实跑。
- 只拦截底部命令行；浮动命令面板、对话框、快捷键宏不生效。
- 下载进度依赖服务器返回 `Content-Length`；拿不到时只显示已下载字节数。

## 完整变更

- `v0.4.7` 与 `v0.4.6` 之间：<https://github.com/Oreak-jack/autocad-inline-math/compare/v0.4.6...v0.4.7>
- 全部提交：<https://github.com/Oreak-jack/autocad-inline-math/commits/main>
- 架构说明：[docs/ARCHITECTURE.md](ARCHITECTURE.md)
- 安装器细节：[docs/INSTALLER.md](INSTALLER.md)