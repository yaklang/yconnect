# Y CONNECT for Windows

C# + 原生 WPF 桌面客户端。不是 Electron；主界面不使用 HTML 或浏览器渲染。

启动器会等待真实客户端（或专用终端）确认就绪，不再把终端进程创建当作启动成功。Windows Terminal 冷启动等待最长 30 秒，等待超时不会立即删除尚有效的加密会话；会话两分钟有效，消费即删除，过期后清理。错误会显示启动阶段与安全错误码，诊断文件 `LaunchSessions/<会话>/launch-error.json` 不记录 Key、完整环境或异常原文。
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

- **YAKCOOL 账户**：点击「在 Y CONNECT 内扫码」，在独立窗口中的 YAKCOOL 官方 HTTPS 页面扫码。页面加载失败可重新加载；二维码过期可使用官方页面的刷新入口。
- **API Key**：粘贴业务 Key，验证额度和当前 Key 可用模型后连接。不提供账户管理权限。
- 扫码需 [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)。系统通常已经提供；不随安装包捆绑 Chromium。没有 WebView2 时 API Key 模式仍可使用。
- 如代理导致微信资源加载失败，使用 `YConnect.exe --no-proxy` 或在偏好设置开启「直连网络」后重启。API 和 WebView2 都绕过代理，直连选择会保存在本应用偏好中，不修改系统代理。构建脚本也支持 `-NoProxy`。
- `YConnect.exe --no-proxy --login` 可直接打开直连模式的官方扫码窗口。
- 只接收 `yakcool.com` 的 `yakcool_user_session` 安全 Cookie，再调用公开用户接口验证。员工会话不会被当成公开账户登录。
- 会话/API Key 使用当前 Windows 用户的 DPAPI 加密，保存在 `%LOCALAPPDATA%\YConnect\Credentials`。正常退出应用可恢复登录；退出账户清理会话。暂时断网保留加密凭证，恢复后可重试；明确的 401 会清理过期凭证。
- 退出登录不自动删除已经应用的客户端配置；如需删除，应先在客户端接入页恢复配置。

## 功能

### 客户端启动器

在「客户端启动器」选择 Key、模型、工作目录和 Windows Terminal / PowerShell / CMD，点击「启动新会话」。每次启动使用独立连接，不修改现有客户端配置；也可以「仅打开专用终端」，准备好连接后再输入 `yconnect` 启动。客户端退出后终端保留，可再次运行。小组件客户端右侧的启动按钮沿用上次选择的工作目录；首次使用先进入启动器设置目录。

OpenCode 使用进程内配置，Codex 使用命令行覆盖与独立 provider，Claude Code 使用会话设置与环境凭证读取器；Pi、Grok Build、Hermes 使用独立客户端目录。后者的会话记录保存在 Y CONNECT 的 `LaunchSessions`，不会导入原有插件或登录状态。OpenClaw 提供带独立配置的专用终端，需按需运行本地 agent 或网关；Claude Desktop 仍使用原有配置预览流程。

Key 不进入命令行、脚本正文或会话配置文件。交接文件用 DPAPI 加密并设置私有权限，终端启动器读取后立即删除；Windows Terminal 即使已有进程也能正确收到本次连接。Key 随新终端的进程环境传给客户端，不修改系统环境变量。独立会话的 Key 在窗口关闭前保持不变；在 Y CONNECT 切换 Key 不会改动已经运行的会话。

「固定配置与备份」保留预览、备份、应用与恢复，适合希望日后从其他入口启动也默认使用 YAKCOOL 的用户。该区域默认收起，终端启动不需要先应用配置。

适配依据：[Codex 自定义 provider](https://learn.chatgpt.com/docs/config-file/config-advanced)、[OpenCode 进程配置](https://opencode.ai/docs/config/)、[Claude Code 会话参数](https://code.claude.com/docs/en/cli-reference)、[Grok 配置目录](https://docs.x.ai/build/settings)、[Pi 配置](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent)、[Hermes 配置](https://hermes-agent.nousresearch.com/docs/user-guide/configuration/)、[OpenClaw 独立目录](https://docs.openclaw.ai/help/environment)。

原生托盘与屏幕贴边小组件、浅/深色主题、余额和额度、全局充值入口、当前 Key 切换、账户 Key 创建/复制/删除、兑换码、模型搜索/协议筛选、完整接入信息复制、配置预览/备份/应用/恢复、分层连接检查、需确认的最小模型测试与完整能力画像、可选开机启动。

8 个独立适配器：OpenCode、Codex、Claude Code、Claude Desktop 第三方推理版、Pi、Grok Build、OpenClaw、Hermes。界面只显示原生检测到已安装的客户端，并按最近使用排序；小组件超过 4 个时显示最近 3 个与「更多」。仅有残留配置文件不算已安装。Gemini CLI 需要协议桥，不纳入可配置入口。

管理中心侧栏默认展开，使用区别于正文的暖灰/深灰底色；可手动收起，底部保留 YAKCOOL 品牌、当前账户与连接状态。账户概览集中提供 Key 操作、模型搜索与复制、五种协议地址、全部已安装客户端、刷新与连接检查等常用操作，与小组件共用连接控件。

充值可从管理中心标题栏、余额卡、小组件或托盘打开同一个原生弹窗：输入 ¥1–¥10,000（最多两位小数），选择微信或支付宝，明确点击生成支付码后才创建订单。二维码在本机生成，不加载远程图片；展示前核对订单金额，仅服务端确认 `paid + verified` 后提示成功并刷新全局余额。支持两分钟展示倒计时、手动更新二维码、查询延迟到账、关闭后在本次运行中继续查询。API Key 模式须先登录账户，官网仍保留为订单核对入口。程序重启后请到官网核对此前订单，不要重复付款。

`./windows/build.ps1 -Test -RechargeSmoke -Package` 验证原生充值控件及便携包，全部使用隔离演示订单，不发送真实支付请求。桌面合成截图受其他窗口遮挡时明确标记 `NOT VERIFIED`；功能断言与 WPF 内容截图单独记录。

小组件支持互斥展开协议/模型；「复制完整接入」包含当前推荐模型、当前客户端、全部可用模型名称与 ID、三种协议、五个接入地址、敏感 Key 及 YAKCOOL/YConnect 官方入口，只应交给可信的人。复制 Key 和完整接入信息后，剪贴板内容在 60 秒后仍未变化时会自动清理。

模型目录展示客户端真正可以请求的 **YAKCOOL 网关入口协议**，而不是只展示 Provider 的原生上游模式。AIBalance 会在 Chat Completions、Responses 和 Anthropic Messages 与模型原生协议之间转换；支持多种传输的客户端仍优先采用模型原生模式生成配置。

完整模型能力画像复刻 AIBalance 的 15 个检测维度：协议发现、响应与固定指令遵循、随机标记图片 OCR、自动/指定工具调用、工具结构、工具结果回灌、thinking 开关，以及 minimal、low、medium、high、xhigh、max 六档思考强度。工具结构复用自动工具调用的响应，因此完整画像最多产生 13 次真实模型调用；开始前必须确认，基础调用失败会停止后续付费检测。客户端只能观察网关响应，因此会明确区分「网关接受请求」与「响应中确实出现可见 reasoning」，不会把隐藏思考虚报为可见思考。

基础检查按官网 `key.status = enabled` 验证 Key；额度用尽与空模型列表单独提示，未登录或 Key 验证失败时跳过依赖项。模型请求最多等待 120 秒，完整检测最多 4 分钟，支持停止检测。输出截断、只有思考没有答案、空响应与答案偏差分别呈现；最小测试也保留正文/Thinking 证据。工具回灌使用只出现在工具结果中的随机标记，避免固定答案造成假通过。目录中的协议是网关提供的转换入口，只有实际调用后才会标记本次协议验证通过。

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
.\windows\build.ps1 -LauncherSmoke          # 交互终端集成检查；会打开测试窗口，需空闲桌面
```

`--demo` 使用醒目标记的模拟数据，配置写入 `%LOCALAPPDATA%\YConnectDemo\ClientSandbox`。
`--development` 使用真实 API、独立数据目录和隔离配置目录。
`--smoke --output=...` 使用隔离数据与自动化测试；不会使用真实凭证或调用付费模型。
`--verify-login --output=...` 只验证真实登录页与微信 iframe 加载，不会完成授权或伪造扫码成功。
独立启动支持同时多开，不使用全局忙碌锁；每次点击单独捕获 Key、模型和工作目录，原配置不变。启动结果逐条显示；「停止等待」只停止本次状态观察，不关闭已经打开的终端。Windows PowerShell 使用自身默认模块路径，避免继承 PowerShell 7 模块导致交互启动卡住。
验证输出包含 PNG 和结果记录；文件名含 `native` 的 PNG 是应用自身窗口在受控背景上的实际 Windows 合成截图，其余是 WPF 视觉树截图。`render-125/150` 是高 DPI 渲染检查，不代表修改了系统显示缩放。测试包含自身演示窗口的真实鼠标拖动、余额速览点击及不抢焦点检查。均在忽略目录 `.test-output/` 中。

完整真实账户授权、实际余额/API Key CRUD、兑换到账，以及第三方客户端真实模型调用，需要用户自己的扫码、有效 Key 和对应客户端；不使用模拟结果声称已完成这些在线验证。

关联仓库在根目录 `related/`，`yconnect.code-workspace` 将它们与本仓库放入同一工作区。它们不是 Windows 应用运行依赖，也不包含在发布包中。详见 `PORTING.md`。
