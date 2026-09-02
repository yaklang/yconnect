# YConnect

YConnect 是 YakCool 的原生 macOS 客户端：常驻菜单栏，并提供与 YTray 一致的屏幕边缘小组件，用于查看账户或 API Key 状态、管理 Key、兑换额度、执行基础连接测试，以及安全地把 YakCool 接入 OpenCode。

> 当前版本：`0.1.0` · 支持 macOS 14 及以上

## 核心体验

- 菜单栏常驻：快速查看连接状态、余额，复制当前 API Key，打开完整管理页。
- 屏幕边缘小组件：默认贴在右侧，可上下拖动、切换左右侧、PIN 固定，交互和视觉参数沿用 YTray。
- 两种认证模式：
  - **YakCool 账户**：在客户端内打开 YakCool 官方页面，使用微信扫码登录；可查看账户与额度、兑换、创建/复制/删除 API Key。
  - **API Key**：只查看这把 Key 的状态、额度信息和可用模型；不会获得账户管理权限。
- OpenCode 一键配置：选择 Key 与兼容模型，保留其他 provider 和未知配置字段，写前备份并支持恢复。
- 基础测试：分层检查 YakCool 健康状态、Key 权限与模型列表；真实模型调用必须二次确认，并且只发送固定测试文本。

YakCool 当前没有面向 C 端的用户名/密码登录接口。员工后台登录与公开用户登录属于不同权限面，YConnect 不会混用；账户模式只接受公开用户会话 `yakcool_user_session`。

## 安全设计

YConnect 把凭证视为敏感数据，而不是普通偏好设置：

- 用户会话和独立 API Key 保存在 macOS Keychain，保护级别为 `AfterFirstUnlockThisDeviceOnly`。
- API Key 不进入 UserDefaults、日志、仓库或 `opencode.json`。
- 账户 Cookie 只发送到 `yakcool.com`；业务 Key 只发送到 YakCool 自查询接口和受信任的 Yaklang HTTPS 网关。
- OpenCode 的 Key 写入 `~/Library/Application Support/YConnect/Secrets/opencode-yakcool-key`，权限固定为 `0600`。
- `~/.config/opencode/opencode.json` 只保存 `{file:...}` 引用；每次变更前在 `~/Library/Application Support/YConnect/Backups/OpenCode/` 创建私有备份。
- OpenCode 写入采用临时文件、同步落盘、原子替换、写后校验和失败回滚；“恢复最近备份”也在事务中执行。
- 开发包使用独立 bundle id、Keychain service、Application Support 和 OpenCode 沙盒路径，不接触正式数据。

OpenCode 会得到一个 `yakcool` provider：

```json
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
```

示例中的 `models` 会由当前 Key 的实际可用模型填充；YConnect 只选择支持 Chat Completions 的模型。现有配置中的其他字段和 provider 会被保留。

## 本地开发

项目是无第三方依赖的 Swift Package，UI 使用 AppKit + SwiftUI。

```bash
git clone https://github.com/yaklang/yconnect.git
cd yconnect
./script/startup.sh
```

`startup.sh` 会启用开发隔离模式。也可以直接构建和测试：

```bash
swift build --package-path darwin --configuration release
swift test --package-path darwin
```

如果本机已安装 OpenCode，可额外运行隔离的真实 CLI 兼容性测试；测试只使用临时目录和假 Key，不会读取或改写用户配置：

```bash
YCONNECT_RUN_OPENCODE_INTEGRATION=1 \
  swift test --package-path darwin --filter OpenCodeCLIIntegrationTests
```

渲染 UI 预览：

```bash
BIN="$(swift build --package-path darwin --configuration release --show-bin-path)/YConnect"
"$BIN" --render-widget /tmp/yconnect-widget.png
"$BIN" --render-manager /tmp/yconnect-manager.png --section openCode
"$BIN" --render-edge-dock /tmp/yconnect-edge.png
"$BIN" --render-tray-icon /tmp/yconnect-tray.png
```

焦点与失焦行为 smoke test：

```bash
"$BIN" --development --smoke-widget-focus
"$BIN" --development --smoke-widget-transient
"$BIN" --development --smoke-edge-widget-focus
```

失败的 smoke test 会返回非零退出码，便于 CI 识别。

## 打包

本机架构的开发隔离包：

```bash
./script/package-macos.sh --dev
```

正式包和 DMG：

```bash
./script/package-macos.sh --arch arm64 --dmg
./script/package-macos.sh --arch amd64 --dmg
./script/package-macos.sh --arch universal --dmg
```

打包依赖 Xcode Command Line Tools 与 ImageMagick。脚本会创建 `.app`、生成 ICNS、进行 ad-hoc hardened runtime 签名并验证架构。发布流水线可再调用 `macos-codesign.sh` 和 `macos-notarize.sh` 完成 Developer ID 签名与公证。

首次提交还没有 Git `HEAD` 时，打包脚本使用 build number `1`；GitHub Actions 中使用 `GITHUB_RUN_NUMBER`。正式发布的推荐顺序是先打包 `.app`，再签名、公证应用、创建 DMG，最后公证 DMG：

```bash
version="$(tr -d '[:space:]' < VERSION)"
./script/package-macos.sh --arch arm64
APPLE_CODESIGN_IDENTITY="Developer ID Application: ..." \
  ./script/macos-codesign.sh dist/darwin-arm64/YConnect.app
APPLE_ID="..." APPLE_TEAM_ID="..." APPLE_APP_PASSWORD="..." \
  ./script/macos-notarize.sh dist/darwin-arm64/YConnect.app
./script/create-macos-dmg.sh dist/darwin-arm64/YConnect.app "$version" arm64
APPLE_ID="..." APPLE_TEAM_ID="..." APPLE_APP_PASSWORD="..." \
  ./script/macos-notarize.sh "dist/YConnect-$version-darwin-arm64.dmg"
```

不要把签名证书、Apple ID 专用密码或其他发布凭据写入仓库；CI 应通过 GitHub Actions Secrets 注入。

## 项目结构

```text
darwin/
  Sources/YConnect/
    AppController.swift          # 菜单栏、窗口、焦点与生命周期
    EdgeDock.swift               # 左右贴边组件与快捷操作
    WebLogin.swift               # 官方微信扫码登录容器
    YConnectStore.swift          # 两种认证模式与业务状态
    YakCoolAPI.swift             # YakCool API 与权限边界
    Security.swift               # Keychain 凭证仓库
    OpenCodeConfigurator.swift   # 备份、原子写入、校验与恢复
    Views.swift                  # 小组件与完整管理 UI
  Tests/YConnectTests/
script/                          # 启动、打包、签名、公证与 DMG
```

## 权限边界

| 模式 | 凭证 | 能力 |
| --- | --- | --- |
| YakCool 账户 | `yakcool_user_session` Cookie | 账户/余额、兑换、API Key 管理、测试、OpenCode 配置 |
| API Key | Bearer business key | 当前 Key 状态、近似或独立额度、可用模型、测试、OpenCode 配置 |

YConnect 不接受账户监控 Token 代替业务 API Key，也不会把员工后台 Cookie 当成公开用户会话。

## 相关项目

- [YakCool](https://yakcool.com/)
- [YTray](https://github.com/yaklang/ytray)
- [OpenCode 配置文档](https://opencode.ai/docs/config/)
- [OpenCode Provider 文档](https://opencode.ai/docs/providers/)
