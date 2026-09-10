# Y CONNECT

[YAKCOOL](https://yakcool.com/) 的原生桌面客户端：查看余额与消费、管理 API Key、账户充值，并为本地 AI 编程工具配置模型和启动独立会话。

## 下载

| 平台 | 要求 | 安装包 |
| --- | --- | --- |
| macOS | macOS 14+，Apple Silicon / Intel | [通用 DMG](https://aliyun-oss.yaklang.com/yconnect/0.5.0/YConnect-0.5.0-darwin-universal.dmg) |
| Windows | Windows 10/11 x64，.NET Framework 4.8 | [安装程序](https://aliyun-oss.yaklang.com/yconnect/0.5.0/YConnect-0.5.0-windows-x64-setup.exe) · [便携 ZIP](https://aliyun-oss.yaklang.com/yconnect/0.5.0/YConnect-0.5.0-windows-x64.zip) |

[GitHub Releases / 更新说明](https://github.com/yaklang/yconnect/releases) · [最新版本](https://aliyun-oss.yaklang.com/yconnect/version.txt) · [SHA-256 校验](https://aliyun-oss.yaklang.com/yconnect/0.5.0/SHA256SUMS.txt)

正式发行的 macOS 应用经过 Developer ID 签名与 Apple 公证，Windows 程序和安装包经过 Authenticode 签名。macOS 将应用拖入 Applications；Windows 运行安装程序或解压便携包。Windows 扫码登录需要系统 WebView2。

## 主要功能

- **账户与 Key**：微信扫码登录 YAKCOOL 账户，查看余额、消费、管理 Key 和扫码充值；也可仅连接 API Key。
- **桌面速览**：菜单栏 / 系统托盘、贴边小组件、深浅色模式。
- **客户端配置**：选择 Key 和兼容模型，一键应用配置，保留备份并支持恢复。
- **独立启动**：选择工作目录，在终端启动 Agent；会话配置独立保存。
- **连接诊断**：检查服务、Key 和模型可用性；真实模型调用及能力测试需确认后执行，可能产生费用。

支持 OpenCode、Pi、Claude Code、Claude Desktop、Codex、Grok Build、OpenClaw、Hermes。独立终端启动仅适用于 CLI 客户端；OpenClaw 需要先准备独立网关。Gemini CLI 暂需额外协议桥。

## 数据与凭据

macOS 使用 Keychain，Windows 使用 DPAPI 保护会话。下游客户端通过私有文件或 helper 读取 Key。配置修改前自动备份；开发模式使用独立数据与客户端配置目录。

## 开发

macOS 使用 Swift / AppKit / SwiftUI，打包需要 Xcode Command Line Tools 和 ImageMagick：

```sh
swift test --package-path darwin
./script/package-macos.sh --dev
```

Windows 使用 C# / WPF，需要 .NET SDK 和 Inno Setup（生成安装程序时）：

```powershell
./windows/build.ps1 -Test -Package -Installer
```

[开发与适配参考](docs/DEVELOPMENT.md) · [Windows 说明](windows/README.md) · [版本、签名与发布](docs/RELEASING.md)
