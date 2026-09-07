# Windows 本机验证记录

## 2026-09-06 · MSIX AppData 重定向根因

- 安装路径真实复现 `read-session/DirectoryNotFoundException`，但 `C:\Users\V\Documents` 和逻辑会话目录均存在。用文件句柄核验发现 `AppData\Local\YConnect\LaunchSessions` 实际位于 Codex MSIX 包的 `LocalCache\Local\YConnect\LaunchSessions`；外部 Windows Terminal 不共享这一重定向视图。不是工作目录不存在，也不是 .NET 启动前退出；此前 CMD 中转猜测未解决此根因，已移除。
- 会话目录、隔离客户端配置路径、工作目录及可执行文件按句柄解析实际路径。一次性 DPAPI 信封仍消费即删除，Key 不进入命令行；未迁移、删除或重建用户登录。保留独立多会话、PowerShell 模块路径初始化和有界等待修复。
- 真实账户与本机安装启动器验证记录 `windows/.test-output/live-physical-path/result.txt`：Codex 和 Grok Build 均以 `deepseek-v4-flash`、真实 Documents 工作目录成功进入客户端启动阶段，未发送模型提示词。新增 AppData 到外部 Windows Terminal 的自动回归，避免只在 Documents 项目目录内验证而漏过包重定向。
- 仍明确区分进程启动与完整 TUI/模型对话验收。终端 UI 不能由桌面操作技能自动操控，已请求用户确认实际界面。
- 用户随后确认上述 Codex / Grok 两个窗口均为正常客户端界面。最终 57 项回归通过（包含 MSIX AppData 跨进程测试），包 `windows/artifacts/YConnect-0.2.0-windows-x64-20260906-213231/` 的 15 个文件已完整替换本机安装并逐项核对哈希，重启管理中心；替换前后登录及偏好哈希一致。旧文件备份 `windows/artifacts/local-backup-before-physical-path-20260906-213231/`。这次替换包含主程序和启动器，不只是重启旧版。

## 2026-09-06 · 交互启动、多会话与验证纠正

- 复现了实际交互路径的问题：Windows PowerShell `-NoExit` 在继承 PowerShell 7 的 `PSModulePath` 时停在初始化，启动脚本第一行未执行；相同命令仅移除新进程继承的模块路径后恢复正常。不修改用户或机器环境。此前自动退出的只读命令测试不足以覆盖这一问题。
- 启动不再使用全局 `Store.Run/Busy`，每个请求单独捕获 Key、模型、目录并记录结果；停止等待与失败不会阻塞其他请求。创建进程移到后台；PID 与创建时间回执使关闭后的请求及时结束。Windows Terminal 的路径交接采用编码数据，覆盖工作目录中的中文、空格、`&` 和字面 `%PATH%`。
- 56 项核心回归通过，最终记录 `windows/.test-output/20260906-181009/core/results.txt`。WinExe/WPF 交互集成验证位于 `windows/.test-output/20260906-170812/`：两个长驻交互测试子进程并行、不同 Key/模型/目录、真实控制台输入输出句柄、UI 仍启用、关闭一个不影响另一个、第三次启动、CMD/PowerShell，以及本机 Codex/Grok 的交互启动。测试使用假 Key，没有发送模型提示词，**不是实际模型调用成功的证明**。
- 原交互测试用强制结束清理子进程，导致 Windows Terminal 保留退出提示窗口，给用户桌面造成干扰；该清理缺陷不应忽略。已清理确认没有活动子会话的测试 Terminal 进程。调整为等待交互启动器正常结束，测试窗口明确命名“YConnect 验证（非客户端）”，不再冒充 Codex 界面。交互测试为显式 `-LauncherSmoke` 选项，不是常规构建要求。
- `parallel-pending.png` / `parallel-ready.png` 为应用自身 WPF 排版截图；没有把这些图或进程存活结果冒充终端内点击、真实对话的验收。桌面操作技能禁止终端 UI 自动化，此边界须明确保留。

## 2026-09-06 · Windows Terminal 启动交接修订

- 不再在 UI 等待超时的 `finally` 中删除尚有效的会话。正常等待 30 秒，超时仍允许有效期内的延迟启动；会话保持两分钟 TTL、消费即删除，后台及下次启动清理过期加密信封。
- `ready` 由专用终端中的确认命令或真正启动客户端的 `--run` 返回；缺少客户端/目录、损坏信封、过期请求和客户端立即失败均返回 `failed` 与阶段/类型/错误码，不再一律提示路径错误。错误诊断不序列化异常原文、环境或 Key。
- 55 项回归通过；新增等待超时后原始信封仍能被延迟启动消费、只清理过期信封、失败阶段、立即非零退出与错误脱敏。首次证据位于 `windows/.test-output/terminal-fix-first/`。
- 本机安装的 Grok 与 Codex 已通过 Windows Terminal 使用隔离目录和演示 Key 分别完成只读 `inspect` / `features list`，退出码为 0；没有发送模型提示词。证据目录 `windows/.test-output/terminal-fix-real-cli/`。不将只读 CLI 验证描述为真实付费会话验证，也未认定此前偶发失败一定由超时导致。
- 最终 `build.ps1 -Test -Package` 输出为 `windows/artifacts/YConnect-0.2.0-windows-x64-20260906-162207/`，55 项测试通过；便携包与本机安装路径的启动器均再次完成真实 Windows Terminal / Grok / Codex 只读启动。已核对替换的 15 个载荷文件哈希并重启管理中心，账户会话与偏好哈希未变。旧版本保存在 `windows/artifacts/local-backup-before-terminal-fix-20260906-162207/`；没有关闭用户的客户端终端或改写其全局配置。

## 2026-09-06 · 原生扫码充值

- 充值入口已改为 C#/WPF 原生金额与支付弹窗，共用单实例。直接使用官网公开账户接口 `POST /api/payments/orders`、`GET /api/payments/orders/{order_no}`，不使用运维接口或业务 Key；充值前核对账户归属、整数分金额和返回订单编号。
- 回归包含金额边界/小数精度、订单复用金额不符、双击并发、账户切换后的延迟响应、过期/失败/关闭/网络恢复，以及仅 `paid + verified` 才报成功。打开弹窗、重新打开未支付订单和登录后返回金额页均不会自动下单。
- `build.ps1 -Test -RechargeSmoke -Package` 的 53 项测试与源码/便携包充值功能冒烟通过（初次完整证据：`windows/.test-output/20260906-143930/`）。新增浅色/深色金额、二维码、成功页 18 张截图，合计 78 张布局截图；二维码使用独立 ZXing 解码器验证 100% / 125% / 150% 截图。二维码生成依赖 QRCoder；ZXing 仅用于测试，不随应用打包。
- 已逐张查看金额、深色二维码、付款成功与余额更新的 WPF 截图。自动执行的原生 WPF 控件测试覆盖自定义 12.34 元、支付宝、单实例与关闭重开、演示到账、全局余额更新、API Key 权限边界、账户登录后回到金额页。
- 当前桌面合成截图被其他窗口遮挡，不能据此宣称真实 DWM 合成通过。增强截图 HWND 遮挡检查，遇到遮挡明确记录 `NOT VERIFIED`，不将其他应用图像当作本应用验证。旧完整冒烟也在桌面拖动断言处停止；该结果与充值功能通过分别记录。
- 全部支付验证使用隔离 Demo/HTTP fixture；真实订单创建、扫码付款与实际支付平台到账尚未执行，真实支付请求为 0。二维码和会话不写入支付日志；关闭停止后续轮询，重启后历史订单在官网核对。
- 最终重跑证据为 `windows/.test-output/20260906-144146/`：53 项测试、源码与便携包两轮充值功能验证通过；便携 ZIP 923,132 字节。已将 14 个载荷文件更新至 `%LOCALAPPDATA%/Programs/YConnect` 并逐文件核对哈希，停止旧实例后用 `--manager --recharge` 重启，仅打开金额输入页。登录会话哈希保持不变，旧程序备份在 `windows/artifacts/local-backup-before-recharge-20260906-144146/`。

## 2026-09-06 · 独立终端启动器与健康检查复核

- `windows/build.ps1 -Test -Smoke -Package` 完整通过：Release 0 警告 / 0 错误，47 项测试通过，源码二进制与便携包的两轮完整原生 WPF 冒烟均通过。证据目录为 `windows/.test-output/20260906-131433/`，含 100% / 125% / 150% 布局图、实际 Windows 合成图、鼠标拖动与聚焦/复制/配置应用恢复记录。实际查看了启动器、窄窗口、深色启动器、小组件及健康检查截图。
- 真实免费检查使用本机已有登录，在只读诊断流程中确认服务、Key 和模型列表全部通过，返回 20 个授权模型，付费模型请求为 0。修正了官网 `enabled` 与旧客户端 `active/ok` 判断不一致的问题，演示数据也与官网契约对齐。额度用尽、空列表、未登录、Key 失效均有独立回归。
- 模型探测不再使用统一 20 秒超时；模型等待上限 120 秒，完整画像 4 分钟，可取消。空响应不会被 thinking-off / effort 判为通过，截断与只有思考分别保留证据，错误答案标为待核实。基础请求失败后停止剩余请求，协议验证来自真实响应；工具回灌用仅在工具结果中出现的随机标记。
- CMD、PowerShell 和真实 Windows Terminal 均通过原生子进程验证：Key 通过环境交接、工作目录正确，带空格/引号/反斜杠/百分号/与号的参数不会错位或执行。npm CMD shim 另有包含字面 `%PATH%` 的路径与参数回归。一次性凭证交接文件 DPAPI 加密，读取即删除；生成的脚本/配置/命令行不包含 Key。
- 本机真实 Codex 和 Grok CLI 已用隔离目录接受临时 provider / 模型配置（`features list` / `inspect`），没有向模型发送提示词。其他适配器验证生成配置与参数，不声称已安装或实际运行全部客户端。
- 独立启动保留全部原配置；OpenCode / Codex / Claude Code 可临时覆盖连接，Pi / Grok / Hermes 使用独立客户端目录。OpenClaw 准备专用终端，按需启动 agent / 网关；Claude Desktop 保留固定配置流程。小组件提供快捷启动。
- 本机旧安装载荷备份于 `windows/artifacts/local-backup-before-launcher-20260906/`；更新时只替换程序文件，账户数据和第三方配置不在替换范围。

## 2026-09-06 · 全协议目录、能力画像与充值入口

- Release 编译 0 警告、0 错误，39 项测试全部通过；新增完整模型能力画像回归。
- 模型目录不再把 AIBalance Provider 的原生上游模式误当成用户入口能力。所有可用模型展示并可筛选 Responses、Anthropic Messages、Chat Completions；多协议客户端配置仍优先采用服务端报告的原生模式。
- 连接测试新增与 AIBalance 对齐的 15 项能力画像：协议、响应/指令、随机标记 OCR、工具 auto/结构/指定/回灌、thinking 开关和 6 档 reasoning effort。完整流程最多 13 次真实请求，工具结构不重复调用，基础失败会停止后续项目；结果区分“网关接受”与“观察到可见 thinking”。
- 完整复制载荷覆盖当前模型/客户端、全部模型名称和 ID、三种协议、五个 URL、API Key 与 YakCool/YConnect 品牌入口，仍执行 60 秒敏感剪贴板清理。
- 管理中心全局标题栏、概览余额卡、小组件余额卡和托盘均提供 YakCool 官方充值入口。
- 新增并逐张查看模型目录、能力画像和小组件的浅色/深色 100%/125%/150% 渲染图；本轮一共生成 60 张隔离 PNG，证据位于 `windows/.test-output/quality-final/layout/`。
- 原生 WPF 冒烟运行完成侧栏 12 次导航聚焦/选择回归与真实 Windows 合成截图；随后因目标窗口被其他窗口遮挡，安全拒绝鼠标拖动并停止，未把这次部分运行记录成完整通过。已有自动布局、协议载荷和 39 项测试均通过。
- 本地 `related/aibalance-server` 已在 `yconnect.code-workspace` 中。源码中的协议矩阵、reasoning policy 与 provider validation 15 项定义已复核；本机未安装 Go SDK，因此没有重跑服务端 Go 测试。

日期：2026-09-05。Windows x64 / .NET Framework 4.8 / WPF。
基于 PR #7 `codex/macos-ux-reference` 的预览图与跨平台交互基线。本轮没有修改 macOS 实现。

## 截图标注问题修订

- Release 编译通过，0 警告、0 错误。38 项测试通过：37 项核心测试，以及新增的独立 STA 线程 WPF 布局/能力一致性回归。
- 新增回归生成 48 张 PNG：深浅主题，1080 × 760 / 850 × 640 管理中心，客户端适配，小组件默认/协议展开/模型展开/复制成功状态，各有 100% / 125% / 150% 渲染输出。
- 断言覆盖默认展开侧栏、侧栏与正文颜色区分、账户概览常见能力齐全、全部已安装客户端、窄屏单列和恢复双列、底部账户不被裁切、客户端等高行、键盘焦点仍可用、协议文本安全内缩、复制反馈单行且窗口高度不变。
- 已通过 Windows 桌面工具实际点击导航、打开协议、复制地址和固定面板，并拖到最小窗口尺寸查看。实际复制发现反馈换行导致位移，已修复并新增回归。最新鼠标输入复测因桌面工具仍报告 Esc 停止而没有继续；不将渲染测试写成实际点击测试。
- 小组件未被桌面工具列为独立可操作窗口，本次使用其真实 WPF 内容树离屏渲染检查。此项不等于重新完成原生桌面透明合成、真实登录或全部端到端操作。上一轮实机验证记录单独保留在下方。
- 最新隔离截图证据：`windows/.test-output/20260905-isolated-layout/core/layout/`，结果在同级 `results.txt`。
- 最终 `build.ps1 -Test -Package` 通过，包为 `windows/artifacts/YConnect-0.2.0-windows-x64-20260905-162141.zip`（830,685 字节）；对应的 38 项测试及 48 张渲染图在 `windows/.test-output/20260905-162141/core/`。本轮未重新执行 `-Smoke` 或真实扫码授权，也未推送远端。

### 渲染测试隔离修复

初版离屏渲染器创建 `App` 后，WPF 排队的 `OnStartup` 意外执行了正式启动流程。正式偏好文件在 16:13:50 被写入过；因缺少写入前副本，不推断具体字段差异，也未擅自回滚。复核时正式目录仅有 `preferences.json`，无登录会话文件；YConnect 开机启动项不存在，当前偏好为明确关闭启动。

渲染器现使用覆写空启动入口的专用 `RenderApplication`，并断言当前控制器始终是隔离演示控制器、动效关闭。修复后复测前后正式偏好 SHA-256 均为 `98EFC5C36CBD0EEB822CABAB0E705A2B88B63E598DD20979C8795000FEB6757B`，修改时间均保持 16:13:50。测试不调用正式启动、登录恢复或写入真实客户端配置。

## 上一轮完整验证（构建 20260905-121502）

- `build.ps1 -Test -Smoke -Package -VerifyLogin -NoProxy` 完整通过，Release 构建 0 警告、0 错误。
- **37 项核心测试**：原有 8 个适配器、安全写入/回滚、DPAPI/ACL、会话和 HTTP 边界；新增安装过滤/最近排序、启动默认与明确关闭/失败重试/隔离、拖动交互排除、靠近距离几何、账户与共享 Key 额度隐私、Key 命名建议与模型权限保持。
- **源码与便携版各 74 次 WPF 按钮操作**。两轮均通过原生确认框完成全部 8 个适配器的隔离应用和恢复，验证模型搜索/过滤、模拟 Key 创建/删除/兑换、基础检查、付费调用确认、账户/API Key 模式、显式粘贴、固定/失焦和主题切换。
- **点击不跳动回归**：6 个导航项在展开/收起侧栏下逐个聚焦、选择，所有导航位置和尺寸保持不变。小组件刷新、固定、关闭和复制 Key 聚焦前后，按钮尺寸、位置与窗口总高度也保持不变。聚焦边框改为叠加绘制，不参与布局。
- **真实鼠标交互**：在本应用演示进程的可见 HWND 内，拖动管理中心标题和小组件余额卡片；验证释放后原生贴边与位置保存。实际点击不激活的余额速览，打开完整组件。目标被外部窗口遮挡时，测试拒绝发送鼠标输入。
- **余额速览**：实测靠近停留后出现、移开后消失；出现前后前台窗口句柄不变。金额、隐私百分比、深色主题和共享 Key 近似百分比正确。关闭速览、减少动效及快速关闭/重开竞争均有断言。
- **复制与安装列表**：Key、模型 ID、5 个独立 URL、完整接入信息分别检查剪贴板内容。敏感内容仅使用假 Key。Windows 短暂占用剪贴板时有有界重试，使用原生 Unicode 写入避免 OLE 刷新阻塞。安装数量 0/1/3/4/5 均有截图和断言；管理中心同样过滤。
- **密度与对齐**：小组件从第一轮的 408 × 720.66 DIP 调整为 **400 × 622.66 DIP**（相同默认演示内容高度减少约 13.6%）。管理中心默认 1080 × 760，卡片对齐、Key 紧凑行、Key/模型并排，侧栏 208/76。最小管理窗口 850 × 640 和较短工作区布局有截图。
- **实际渲染**：每轮 77 张 PNG，包含真实 Windows 合成截图。正文不透明，圆角外缘透明；深浅主题、阴影、边缘速览和账户底部信息已逐项查看。十个基线对应状态都有 100% / 125% / 150% WPF 渲染目标输出。
- **真实登录页**：直连模式下官网健康检查返回 ok，YakCool 登录页和微信二维码 iframe 加载成功，已查看实际原生窗口截图。没有完成扫码授权，也没有伪造成功回调。

本机真实显示器工作区为 3440 × 1392，100% DPI。125% / 150% 是 WPF 高 DPI 渲染检查，另有 100/125/150/200% 与负坐标显示器的几何测试；不是宣称已经在不同物理显示器或不同系统缩放下完成端到端测试。

## 本机证据

根目录：`windows/.test-output/20260905-121502/`（已忽略，不含真实账户凭证）。

- `core/results.txt`
- `native-ui/ui-results.txt`、`packaged-native-ui/ui-results.txt`
- `packaged-native-ui/20-widget-light-native.png`、`21-widget-dark-native.png`、`22-manager-native.png`
- `packaged-native-ui/native-28-peek-balance.png`、`native-29-peek-percentage.png`、`native-30-peek-dark.png`
- `packaged-native-ui/33-peek-shared-key.png`
- `packaged-native-ui/34-sidebar-focus.png`、`35-sidebar-collapsed-focus.png`
- `packaged-native-ui/*-render-125.png`、`*-render-150.png`
- `official-login/live-login-results.json`、`official-login/official-login-native.png`

## 包与运行开销

便携包不捆绑 Electron、Chromium 或 .NET 运行时；扫码窗口按需使用系统 WebView2。主程序包约 0.8 MiB，解压约 2.2 MiB，未签名。

自动 UI/截图检查后的进程工作集约 157 MiB，private bytes 约 176 MiB；包含大量截图/自动化分配，不是常驻空闲值或所有设备的内存上限。未打开扫码窗口时不需要浏览器子进程。边缘微光为有限动画，不做常驻循环。

## 仍未完成的外部验证

真实 YakCool 账户没有在本轮扫码授权。真实余额同步、在线 Key 创建/删除、兑换到账和付费模型调用未以演示结果冒充完成；测试均使用清晰标记的假数据和隔离目录，没有改真实客户端配置、系统代理或开机启动项。

8 个适配器验证的是生成配置、原生界面应用和恢复，不代表本机已经安装并启动全部第三方客户端。Windows 原生配置不等于 WSL 配置，Gemini CLI 仍需协议桥。

便携包未 Authenticode 签名，未进行其他设备、ARM64、商店安装包、干净 Windows 安装环境或真实多显示器端到端发行验证。
