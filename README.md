# YConnect

YConnect 是 YakCool 的原生桌面客户端，也是一个面向 AI 编程工具的本地端点适配中心。macOS 使用 Swift/AppKit，Windows 使用 C#/WPF。它常驻菜单栏或系统托盘并提供与 YTray 一致的屏幕边缘小组件，用于查看账户或 API Key 状态、管理 Key、执行基础连接测试，以及把不同本地客户端安全切换到 YakCool。

> 当前版本：0.2.0 · macOS 14+；新增 Windows 10/11 x64 原生移植版

## Windows 原生版

使用系统 .NET Framework 4.8，无 Electron，无打包浏览器；仅扫码登录按需使用系统 WebView2。
运行 `./windows/build.ps1 -Test -Smoke -Package -Run` 构建、验证并启动。
Windows 路径、权限保护、登录与验证边界见 [Windows 说明](windows/README.md)；下方原有平台路径与 Keychain 说明针对 macOS。

## 核心体验

- 菜单栏常驻：快速查看连接状态和余额，复制当前 API Key，打开完整管理页。
- 屏幕边缘小组件：默认贴在右侧，可上下拖动、切换左右侧、PIN 固定，交互参数沿用 YTray。
- 两种认证模式：
  - **YakCool 账户**：在客户端内打开 YakCool 官方页面，通过微信扫码登录；可查看账户与额度、兑换、创建/复制/删除 API Key。
  - **API Key**：只查看当前 Key 的状态、额度和可用模型；不会获得账户管理权限。
- 客户端适配中心：按目标客户端支持的原生协议筛选模型，写前备份，一键应用并支持恢复。
- 基础测试：分层检查 YakCool 健康状态、Key 权限与模型列表；真实模型调用必须二次确认，并且只发送固定测试文本。

YakCool 当前没有面向 C 端的用户名/密码登录接口。员工后台登录与公开用户登录属于不同权限面，YConnect 不会混用；账户模式只接受公开用户会话 yakcool_user_session。

## 正式客户端适配

YConnect 不是只面向 OpenCode。0.2.0 提供 8 个独立、可写入、可恢复的原生适配器；Gemini CLI 单独标记为需要协议桥，不会用一个看似成功但实际不兼容的配置冒充支持：

| 客户端 | 配置位置 | YakCool 协议 | 凭证接入 |
| --- | --- | --- | --- |
| OpenCode | ~/.config/opencode/opencode.json | Chat Completions | 官方 file 引用 |
| Pi | ~/.pi/agent/models.json、settings.json | Responses → Messages → Chat | 官方 command 引用 |
| Claude Code | ~/.claude/settings.json | Anthropic Messages | 官方 apiKeyHelper |
| Claude Desktop | ~/Library/Application Support/Claude-3p/configLibrary | Anthropic Messages（仅 Claude 模型） | 官方 helper-script |
| Codex | ~/.codex/config.toml | Responses | provider auth.command |
| Grok Build | ~/.grok/config.toml | Responses → Messages → Chat | auth_provider.command |
| OpenClaw | ~/.openclaw/openclaw.json | Responses → Messages → Chat | 官方 file SecretRef |
| Hermes | ~/.hermes/config.yaml | Responses → Messages → Chat | 官方 key_cmd helper |

箭头表示同一客户端对模型协议的选择优先级。YConnect 会读取当前业务 Key 的真实模型列表，再为所选客户端筛选兼容模型；不会把一个 Chat-only 模型错误写进 Responses 或 Messages 配置。

每个客户端都是单独的适配器，实现同一套边界：

    YakCool Key + 可用模型
              │
              ▼
    客户端协议筛选 ──► 配置生成 ──► 多文件事务 ──► 写后校验
                             │              │
                             └──────────────► 私有备份 / 可恢复

适配器只拥有自己的 YakCool 节点、默认模型和凭证引用。JSON / JSONC / JSON5 配置会保留未知字段和其他 provider，但写回时统一为标准 JSON，因此原注释和排版不会保留；Codex / Grok 的窄范围 TOML 编辑器会保留无关表与注释，Hermes 的窄范围 YAML 编辑器会保留 YConnect 管理区之外的行与注释。

## 与 CC-Switch 的客户端范围

我们按 CC-Switch 当前源码里的 AppType 核对，而不是只看 README 中较旧的列表。当前实际有 9 个独立客户端类型：

| CC-Switch AppType | YConnect 状态 | 说明 |
| --- | --- | --- |
| Claude Code | 已适配 | Anthropic Messages |
| Claude Desktop | 已适配 | Anthropic Messages；helper-script 读取独立密钥文件 |
| Codex | 已适配 | Responses |
| Gemini CLI | 需协议桥 | 客户端发送 Gemini-native generateContent |
| Grok Build | 已适配 | Responses / Messages / Chat |
| OpenCode | 已适配 | Chat Completions |
| OpenClaw | 已适配 | Responses / Messages / Chat；file SecretRef |
| Hermes | 已适配 | Responses / Messages / Chat；v12 provider + key_cmd |
| Pi | 已适配 | Responses / Messages / Chat |

CC-Switch 的 README 仍写着 8 个应用，但源码已经包含第 9 个 Pi；Pi 从 v3.20.0 起成为正式 AppType。OMO / OMO Slim 是 OpenCode 变体，xAI、Codex OAuth、GitHub Copilot 等是 provider 或认证模式，它们不应重复算作客户端。

Gemini CLI 是明确的协议边界：CC-Switch 的 Gemini takeover 仍把 Gemini 请求传给 Gemini-compatible 上游，并不把 generateContent 转成 OpenAI 或 Anthropic 请求。YakCool 当前公开网关提供 Chat Completions、Responses 和 Anthropic Messages，因此 YConnect 不会把 Gemini CLI 伪装成“可直接应用”；需要先提供本地协议桥或服务端 Gemini-native 入口。

核对依据：

- [CC-Switch 当前 AppType 源码（固定提交）](https://github.com/farion1231/cc-switch/blob/c58a25b2ae583710f24ce8867e48340bda619f7d/src-tauri/src/app_config.rs#L377-L467)
- [CC-Switch README 的旧 8 应用列表](https://github.com/farion1231/cc-switch/blob/c58a25b2ae583710f24ce8867e48340bda619f7d/README.md#L208-L219)
- [CC-Switch v3.20.0 Pi 支持说明](https://github.com/farion1231/cc-switch/blob/c58a25b2ae583710f24ce8867e48340bda619f7d/docs/release-notes/v3.20.0-en.md#L1-L18)
- [CC-Switch Gemini pass-through handler](https://github.com/farion1231/cc-switch/blob/c58a25b2ae583710f24ce8867e48340bda619f7d/src-tauri/src/proxy/handlers.rs#L2047-L2098)
- [CC-Switch Gemini provider adapter](https://github.com/farion1231/cc-switch/blob/c58a25b2ae583710f24ce8867e48340bda619f7d/src-tauri/src/proxy/providers/gemini.rs#L160-L255)

## 安全设计

YConnect 把凭证视为敏感数据，而不是普通偏好设置：

- 用户会话和独立登录 API Key 保存在 macOS Keychain，保护级别为 AfterFirstUnlockThisDeviceOnly。
- API Key 不进入 UserDefaults、日志、仓库或客户端配置明文。
- 账户 Cookie 只发送到 yakcool.com；业务 Key 只发送到 YakCool 自查询接口和受信任的 Yaklang HTTPS 网关。
- 下游客户端需要读取的 Key 分别保存到 ~/Library/Application Support/YConnect/Secrets/，每个文件固定为 0600，配置里只写官方支持的 file / helper / command 引用。
- 每个客户端拥有独立备份目录；事务会同时快照所有目标文件，比较版本后按序原子写入，再执行格式和安全校验。
- 任一步骤失败都会回滚已触碰的文件；检测到外部并发修改时不会覆盖外部内容，并保留恢复快照。
- 备份目录为 0700，文件为 0600，manifest 只保存路径、权限、大小和哈希等元数据，不保存配置或 Key 明文。
- 每个客户端保留最近 20 个已完成快照；“恢复最近备份”同样经过并发保护与写后校验。
- 开发包使用独立 bundle id、Keychain service、Application Support 和完整客户端 Home 沙盒，不接触正式配置。

OpenCode 生成的 YakCool provider 形如：

    {
      "$schema": "https://opencode.ai/config.json",
      "provider": {
        "yakcool": {
          "name": "YakCool",
          "npm": "@ai-sdk/openai-compatible",
          "options": {
            "baseURL": "https://aibalance.yaklang.com/v1",
            "apiKey": "{file:/Users/you/Library/Application Support/YConnect/Secrets/opencode-yakcool-key}"
          },
          "models": {}
        }
      },
      "model": "yakcool/<selected-model>"
    }

示例中的 models 会由当前 Key 的实际可用模型填充；现有配置中的其他字段和 provider 会被保留。其他客户端使用同样的独立密钥原则，但按各自官方机制生成 JSON、JSON5、TOML 或 YAML。

## 本地开发

项目是无第三方依赖的 Swift Package，UI 使用 AppKit + SwiftUI。

    git clone https://github.com/yaklang/yconnect.git
    cd yconnect
    ./script/startup.sh

startup.sh 会启用开发隔离模式。也可以直接构建和测试：

    swift build --package-path darwin --configuration release
    swift test --package-path darwin

如果本机已安装 OpenCode，可额外运行隔离的真实 CLI 兼容性测试；测试只使用临时目录和假 Key，不会读取或改写用户配置：

    YCONNECT_RUN_OPENCODE_INTEGRATION=1 \
      swift test --package-path darwin --filter OpenCodeCLIIntegrationTests

渲染使用公开示例数据的 UI 预览：

    BIN="$(swift build --package-path darwin --configuration release --show-bin-path)/YConnect"
    "$BIN" --render-widget /tmp/yconnect-widget.png
    "$BIN" --render-manager /tmp/yconnect-manager.png --section clients
    "$BIN" --render-edge-dock /tmp/yconnect-edge.png
    "$BIN" --render-tray-icon /tmp/yconnect-tray.png

旧的 --section openCode 参数仍作为 clients 的兼容别名。

焦点与失焦行为 smoke test：

    "$BIN" --development --smoke-widget-focus
    "$BIN" --development --smoke-widget-transient
    "$BIN" --development --smoke-edge-widget-focus

失败的 smoke test 会返回非零退出码，便于 CI 识别。

## 打包

本机架构的开发隔离包：

    ./script/package-macos.sh --dev

开发签名的本机包和 DMG：

    ./script/package-macos.sh --arch arm64 --dmg
    ./script/package-macos.sh --arch amd64 --dmg
    ./script/package-macos.sh --arch universal --dmg

打包依赖 Xcode Command Line Tools 与 ImageMagick。上述命令会创建 `.app`、生成 ICNS、进行 ad-hoc hardened runtime 签名并验证架构，适合开发验证；GitHub Actions 也只验证这一开发产物，不代表 Apple 正式发行签名。

正式发布应先生成未封装 DMG 的 `.app`，使用 Developer ID 完成签名，再从已签名的应用创建 DMG，最后提交公证并 stapling：

    ./script/package-macos.sh --arch universal
    ./script/macos-codesign.sh dist/darwin-universal/YConnect.app
    ./script/create-macos-dmg.sh dist/darwin-universal/YConnect.app 0.2.0 universal dist/YConnect-0.2.0-darwin-universal.dmg
    ./script/macos-notarize.sh dist/YConnect-0.2.0-darwin-universal.dmg

`macos-notarize.sh` 也接受一个已经 Developer ID 签名的 `.app`；脚本会临时压缩后提交，并把票据 stapling 回原应用。

不要把签名证书、Apple ID 专用密码或其他发布凭据写入仓库；CI 应通过 GitHub Actions Secrets 注入。

## 项目结构

    darwin/
      Sources/YConnect/
        AppController.swift             # 菜单栏、窗口、焦点与生命周期
        EdgeDock.swift                  # 左右贴边组件与快捷操作
        WebLogin.swift                  # 官方微信扫码登录容器
        YConnectStore.swift             # 认证、业务状态与客户端选择
        YakCoolAPI.swift                # YakCool API 与权限边界
        Security.swift                  # Keychain 凭证仓库
        ClientConfiguration.swift       # 客户端协议、注册表与覆盖范围
        DefaultClientConfigurationRegistry.swift # 8 个正式适配器的组合入口
        ConfigurationTransaction.swift  # 多文件备份、CAS、原子写入与恢复
        OpenCodeConfigurator.swift      # OpenCode 配置实现
        PiClaudeConfigurators.swift     # Pi 与 Claude Code 适配器
        CodexConfigurator.swift         # Codex Responses 适配器
        GrokBuildConfigurator.swift     # Grok Build 多协议适配器
        ExtendedClientConfigurators.swift # Claude Desktop / OpenClaw / Hermes
        TOMLConfigurationEditor.swift   # Codex / Grok 的窄范围 TOML 编辑器
        Views.swift                     # 小组件与完整管理 UI
      Tests/YConnectTests/
    script/                             # 启动、打包、签名、公证与 DMG

## 权限边界

| 模式 | 凭证 | 能力 |
| --- | --- | --- |
| YakCool 账户 | yakcool_user_session Cookie | 账户/余额、兑换、API Key 管理、测试、客户端配置 |
| API Key | Bearer business key | 当前 Key 状态、近似或独立额度、可用模型、测试、客户端配置 |

YConnect 不接受账户监控 Token 代替业务 API Key，也不会把员工后台 Cookie 当成公开用户会话。

## 客户端规范来源

- [OpenCode 配置](https://opencode.ai/docs/config/) 与 [Provider](https://opencode.ai/docs/providers/)
- [Pi custom models](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md) 与 [custom providers](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md)
- [Claude Code LLM gateway](https://code.claude.com/docs/en/llm-gateway-connect) 与 [settings](https://code.claude.com/docs/en/settings)
- [Codex config reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Grok Build settings reference](https://docs.x.ai/build/settings/reference)
- [Claude Desktop third-party configuration](https://claude.com/docs/third-party/claude-desktop/configuration)、[credential helper](https://claude.com/docs/third-party/claude-desktop/credential-helper) 与 [gateway](https://claude.com/docs/third-party/claude-desktop/gateway)
- [OpenClaw provider configuration](https://github.com/openclaw/openclaw/blob/main/docs/gateway/config-tools.md#L591-L628)、[SecretRef](https://github.com/openclaw/openclaw/blob/main/docs/gateway/secrets.md#L266-L354) 与 [file provider](https://github.com/openclaw/openclaw/blob/main/docs/gateway/secrets.md#L462-L485)
- [Hermes configuration paths](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/configuration.md#L203-L245) 与 [v12 custom provider / key_cmd](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/integrations/providers.md#L1154-L1183)

## 相关项目

- [YakCool](https://yakcool.com/)
- [YTray](https://github.com/yaklang/ytray)
- [CC-Switch](https://github.com/farion1231/cc-switch)
