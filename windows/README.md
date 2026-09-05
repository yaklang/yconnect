# YConnect for Windows

C# + 原生 WPF 桌面客户端。不是 Electron；主界面不使用 HTML 或浏览器渲染。
复用 Windows 自带的 .NET Framework 4.8，只有扫码窗口按需加载系统 WebView2，关闭后释放。

## 运行

Windows 10 1903+ / Windows 11，x64。较早系统需安装 .NET Framework 4.8。
解压整个便携目录，双击 **YConnect.exe**，不要只移动 EXE 而遗漏 DLL。
默认在屏幕右边显示贴边入口。鼠标靠近并短暂停留，即可看到不抢焦点的余额速览；移开自动收起，点击打开完整小组件。设置中可以改为只显示百分比或关闭速览。

## 下载发行版

[GitHub Releases](https://github.com/yaklang/yconnect/releases) 同时提供 Windows x64 安装程序、免安装 ZIP 和 macOS 通用 DMG。Windows 安装程序按当前用户安装，不需要管理员权限；卸载保留账户数据和第三方客户端配置。当前 Windows 包尚未进行 Authenticode 签名。

CI 使用 `./windows/build.ps1 -Test -Package -Installer` 构建；本地生成安装程序另需 Inno Setup 6。版本号从根目录 `VERSION` 读取，并检查与 C# 项目版本一致。
小组件右上角 PIN 固定后不会因失焦而收起。余额卡片、文字与空白区域可直接拖动，松手后柔和贴边；输入框和按钮保留原本操作。边缘入口支持拖动高度、左右切换和多显示器。托盘图标也能打开面板。
首次正式运行默认开启随 Windows 登录启动，可在设置中关闭；已有用户的选择会保留。开发和演示环境不写启动项。
无需管理员权限。没有修改防火墙、系统代理或第三方客户端配置的自动启动步骤。

源码构建需 .NET SDK 8 或更新版本：

```powershell
.\windows\build.ps1 -Test -Smoke -Package -Run
```

产物在 `windows/artifacts/`；构建不会打包 .NET/Chromium 运行时。
`-Smoke` 需要已解锁的交互式 Windows 桌面，用原生 WPF 自动化控件操作并截图。

## 登录

- **YakCool 账户**：点击「在 YConnect 内扫码」，在独立窗口中的 YakCool 官方 HTTPS 页面扫码。页面加载失败可重新加载；二维码过期可使用官方页面的刷新入口。
- **API Key**：粘贴业务 Key，验证额度和当前 Key 可用模型后连接。不提供账户管理权限。
- 扫码需 [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)。系统通常已经提供；不随安装包捆绑 Chromium。没有 WebView2 时 API Key 模式仍可使用。
- 如代理导致微信资源加载失败，使用 `YConnect.exe --no-proxy` 或在偏好设置开启「直连网络」后重启。API 和 WebView2 都绕过代理，直连选择会保存在本应用偏好中，不修改系统代理。构建脚本也支持 `-NoProxy`。
- `YConnect.exe --no-proxy --login` 可直接打开直连模式的官方扫码窗口。
- 只接收 `yakcool.com` 的 `yakcool_user_session` 安全 Cookie，再调用公开用户接口验证。员工会话不会被当成公开账户登录。
- 会话/API Key 使用当前 Windows 用户的 DPAPI 加密，保存在 `%LOCALAPPDATA%\YConnect\Credentials`。正常退出应用可恢复登录；退出账户清理会话。暂时断网保留加密凭证，恢复后可重试；明确的 401 会清理过期凭证。
- 退出登录不自动删除已经应用的客户端配置；如需删除，应先在客户端接入页恢复配置。

## 功能

原生托盘与屏幕贴边小组件、浅/深色主题、余额和额度、当前 Key 切换、账户 Key 创建/复制/删除、兑换码、模型搜索/协议筛选、接入信息复制、配置预览/备份/应用/恢复、分层连接检查、需确认的最小模型测试、可选开机启动。

8 个独立适配器：OpenCode、Codex、Claude Code、Claude Desktop 第三方推理版、Pi、Grok Build、OpenClaw、Hermes。界面只显示原生检测到已安装的客户端，并按最近使用排序；小组件超过 4 个时显示最近 3 个与「更多」。仅有残留配置文件不算已安装。Gemini CLI 需要协议桥，不纳入可配置入口。

管理中心侧栏默认展开，使用区别于正文的暖灰/深灰底色；可手动收起，底部保留 YAKCOOL 品牌、当前账户与连接状态。账户概览集中提供 Key 操作、模型搜索与复制、五种协议地址、全部已安装客户端、刷新与连接检查等常用操作，与小组件共用连接控件。小组件支持互斥展开协议/模型；「复制接入信息」包含敏感 Key，只应交给可信的人。复制 Key 和接入信息后，剪贴板内容在 60 秒后仍未变化时会自动清理。

动效遵循 Windows 的减少动画设置；只有交互/刷新时短暂发光，没有常驻循环动画。设计细节见 [Windows 桌面交互](UX.md)。

| 客户端 | Windows 默认配置位置 |
| --- | --- |
| OpenCode | `%USERPROFILE%\.config\opencode\opencode.json`，支持 `XDG_CONFIG_HOME` |
| Codex | `%USERPROFILE%\.codex\config.toml`，支持 `CODEX_HOME` |
| Claude Code | `%USERPROFILE%\.claude\settings.json`，支持 `CLAUDE_CONFIG_DIR` |
| Claude Desktop 3p | `%LOCALAPPDATA%\Claude-3p\configLibrary` |
| Pi | `%USERPROFILE%\.pi\agent\models.json`、`settings.json` |
| Grok Build | `%USERPROFILE%\.grok\config.toml` |
| OpenClaw | `%USERPROFILE%\.openclaw\openclaw.json` |
| Hermes | `%USERPROFILE%\.hermes\config.yaml` |

这些是 **Windows 原生客户端** 的配置，不会修改 WSL 内的 Linux 配置。Hermes 等工具是否能在 Windows 原生运行，仍取决于对应客户端自身支持。已验证生成配置，不代表本机安装并运行了全部第三方客户端。

写入前按当前 Key 的协议能力筛选模型；预览不显示真实密钥。未知 JSON 字段保留，但写回为标准 JSON，原注释/排版不保留。TOML/YAML 保留管理范围外的文本；不支持安全修改的复杂结构会明确拒绝。

凭证读取器是独立的几 KB C# EXE，不拼接 shell 命令。兼容客户端 file 引用的密钥文件需可被当前用户读取，因此该文件以明文存储、使用仅当前用户和 SYSTEM 的私有 ACL；**不是声称所有落盘文件都加密**。会话和备份使用 DPAPI。写入支持预览哈希检查、多文件失败回滚和恢复前外部改动检测；拒绝软链接/reparse point 与硬链接。最近 20 份成功备份保留。

## 验证与开发隔离

```powershell
.\windows\build.ps1 -Test                   # 核心、安全、会话与 8 个适配器测试
.\windows\build.ps1 -Smoke                  # 真实 WPF 控件操作 + 原生窗口截图
.\windows\build.ps1 -VerifyLogin            # 真实官网健康检查和扫码页面加载
```

`--demo` 使用醒目标记的模拟数据，配置写入 `%LOCALAPPDATA%\YConnectDemo\ClientSandbox`。
`--development` 使用真实 API、独立数据目录和隔离配置目录。
`--smoke --output=...` 使用隔离数据与自动化测试；不会使用真实凭证或调用付费模型。
`--verify-login --output=...` 只验证真实登录页与微信 iframe 加载，不会完成授权或伪造扫码成功。
验证输出包含 PNG 和结果记录；文件名含 `native` 的 PNG 是应用自身窗口在受控背景上的实际 Windows 合成截图，其余是 WPF 视觉树截图。`render-125/150` 是高 DPI 渲染检查，不代表修改了系统显示缩放。测试包含自身演示窗口的真实鼠标拖动、余额速览点击及不抢焦点检查。均在忽略目录 `.test-output/` 中。

完整真实账户授权、实际余额/API Key CRUD、兑换到账，以及第三方客户端真实模型调用，需要用户自己的扫码、有效 Key 和对应客户端；不使用模拟结果声称已完成这些在线验证。

关联仓库在根目录 `related/`，`yconnect.code-workspace` 将它们与本仓库放入同一工作区。它们不是 Windows 应用运行依赖，也不包含在发布包中。详见 `PORTING.md`。
