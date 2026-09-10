# 客户端更新与版本发布

## 用户路径

正式版启动 15 秒后检查 `latest.json`，之后每六小时检查一次。小组件和管理中心显示“新版本”，菜单及设置提供“检查更新”。设置中可以关闭自动检查、查看版本说明或手动下载。检查使用独立的无 Cookie、无凭据请求，不依赖登录，也不消耗模型额度；请求有超时与响应大小限制。

后台检查不弹窗、不下载、不安装。用户点击后：

- macOS：Sparkle 原生更新窗口展示说明、下载进度，完成验证后安装并重新打开。权限不足时通过系统授权处理；运行在 DMG、只读目录等不适合更新的位置时显示错误，可改用手动下载。
- Windows 安装版：WinSparkle 显示下载进度并验证更新包，随后启动 Inno Setup 的精简安装界面；只显示进度与错误，成功后重新打开 Y CONNECT。禁止强制关闭其他应用或重启操作系统。
- Windows 便携版：先明确询问是否转为安装版。账户数据沿用同一数据目录，原便携目录保留，不静默替换用户任意目录。

忙碌操作或原生弹窗未完成时不开始更新。更新只替换应用文件，账户数据、钥匙串/DPAPI 凭据和第三方客户端配置不在安装包的删除范围内。已启动的独立 Agent 会话不属于更新器的关闭对象；Windows 的关闭应用过滤器限定为 `YConnect.exe`。

断网、无效元数据、下载失败、签名失败、取消等情况保留当前可用版本，可重试或使用手动下载。首次从 0.4.0 升级必须手动下载一次，因为旧版不包含更新器。开发、预览和自动化测试环境不会检查或安装正式更新。

## 信任与依赖

macOS 固定使用 Sparkle 2.9.6，SPM 下载使用上游给出的 SHA-256；打包保留 framework 符号链接并从内到外签署其辅助进程。Windows 固定 WinSparkle 0.9.4 x64，下载分发 ZIP 后校验固定 SHA-256，随应用打包 DLL 和许可证。

两端对最终 DMG/EXE 验证同一 Ed25519 公钥的签名，公钥位于 `resources/updates/ed25519-public-key.txt`；macOS 同时验证 Developer ID，发布流程保留 Apple 公证和 Windows Authenticode。`latest.json` 只决定提示信息，实际安装必须再次通过原生更新引擎的签名校验。不会执行 JSON 提供的任意脚本或命令。

私钥是 CI 的 `YCONNECT_UPDATE_PRIVATE_KEY` Secret，PEM 格式，不写入仓库、安装包、日志或公开索引。维护者应在独立的安全位置备份；签名脚本会核对私钥对应的公钥与仓库公钥一致。普通发版不能重新生成密钥；轮换必须按两端更新引擎的迁移要求分阶段进行，避免让已有客户端失去更新能力。

## 每次发布

1. `python3 script/version.py --set X.Y.Z` 同步版本，更新 README 下载地址并创建 `docs/releases/vX.Y.Z.md`。
2. 在发布分支运行 Release 工作流。两端执行单元、界面、启动、原生更新引擎、签名与安装包检查。
3. `prepare-updates` 下载两端最终签名产物，生成 manifest、SHA-256、更新说明与两个带 Ed25519 签名的 appcast；发布分支只产生 `prepared-release` 验收产物，不上线。
4. 验证通过后，将相同提交合入 main，并推送 `vX.Y.Z` 标签。发布流水线验证标签与 VERSION 一致，上传不可变版本文件，并从 CDN 下载验证。
5. 原生更新源先就绪，再更新 `latest.json` 等版本索引，最后创建 GitHub Release；每个公开入口都验证字节内容。

macOS `CFBundleVersion = major × 1,000,000 + minor × 1,000 + patch`，各部分必须小于 1000。它与同一版本的 CI 重跑次数、工作流名称无关，确保 Sparkle 不会因构建号倒退而漏掉更新。Windows 使用标准三段版本。

根目录增加 `appcast-macos.xml`、`appcast-windows.xml`；不可变版本目录也保存这两份文件。已有 manifest/schema、历史索引和手动下载地址保持兼容。版本发布不能覆盖不同字节的历史文件或降低 latest；出现问题应发布更高的修复版本。上传中断后复用已验收的 `prepared-release` 产物恢复，不能重新生成不同签名/公证时间戳的同版本文件进行覆盖。

## 验收

- Swift 单元测试覆盖数字版本排序、拒绝降级、错误产品/域名/平台/重复资产、响应大小与开发环境隔离。
- `script/test-macos-updater.py` 使用临时应用、随机测试公钥和本机订阅源运行真实 Sparkle：拒绝篡改，正常替换应用并重新启动，保留模拟账户数据。
- Windows 原生测试使用同样的 Ed25519 标准签名与真实 WinSparkle DLL，验证有效下载能进入安装交接、篡改包不能进入安装；安装执行由测试回调截获。
- Windows CI 从已发布的签名版 0.4.0 实际覆盖升级，核对新程序哈希、自动重启与账户数据保留，同时验证包内版本、签名及卸载，正式发布额外检查签名时间戳。正常更新使用同一 Inno Setup 安装器。
- Python 发布测试覆盖签名与公钥一致性、版本序号、不可变文件、历史记录、订阅源和版本指针的发布顺序及 CDN 校验。

参考：[Sparkle](https://sparkle-project.org/documentation/)、[WinSparkle](https://winsparkle.org/guides/publishing-updates/)、[Inno Setup 更新参数](https://jrsoftware.org/ishelp/topic_setupcmdline.htm)。
