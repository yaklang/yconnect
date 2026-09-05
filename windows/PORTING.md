# Windows port notes

本次移植以 `darwin/Sources/YConnect` 的 API、安全边界和 8 个配置器为依据，保留 macOS 实现不变。
原生界面、托盘、窗口定位、凭证保护和启动项改用 WPF / Win32 / DPAPI / HKCU Run。
当前原生目标为 Windows x64，不把 WPF 描述为跨平台 UI；平台无关协议与配置逻辑集中于 `YConnect/Core`。

> Windows UI 变更前必须对照 [YConnect macOS 交互基线与 Windows 适配规范](../docs/macos-ux-reference-for-windows.md)。平台控件可以不同，但信息层级、文案语义、默认启动行为、已安装客户端过滤、复制路径和安全确认不得漂移。

## 本地关联仓库

| 本地目录 | 来源 | 本次参考提交 |
| --- | --- | --- |
| `related/ytray` | `yaklang/ytray` | `84c482f856282cfc1b0135cab942c33e9719fcac` |
| `related/yakcool.com` | `VillanCh/yakcool.com` | `c27fe187f98c2d7888cd9f329d6d4314aa6bb338` |
| `related/aibalance-server` | `yaklang/aibalance-server` | `3f00e0f78a9948313cbc2e382bf28d383a71f054` |

以上目录是本地独立 Git 克隆，在主仓库中忽略，不冒充已提交的 submodule。
YTray 用于 Windows 原生托盘与贴边交互参考；YakCool 用于公开账户/扫码协议；aibalance-server 用于网关协议参考。本次未更改这些仓库。

## 关键边界

- 账户接口只发送公开用户 Cookie，业务接口只发送 Bearer Key；不使用员工凭证。
- 当前 Key 的 `/api/key/models` 是协议能力的权威来源，不以账户展示目录推断可调用能力。
- 基础检查只读 `/api/health`、`/api/key/info`、`/api/key/models`；真实模型测试需原生确认弹窗。
- WebView2 只用于官方扫码页，按需创建并释放。程序包只有共享运行时的托管桥和 native loader。
- 半透明区域仅为小组件/边缘入口的外部圆角和阴影；正文卡片始终有明确不透明底色，避免桌面内容透入文字。
- 演示环境、开发环境、验证环境和正式数据独立，测试不改真实客户端配置或启动项。
- 便携包未代码签名；面向其他用户正式发行前应增加 Authenticode 签名和 Windows 安装包验证。

初期 Electron 技术草稿已退出构建链，在本机 `.tmp/electron-prototype` 留存；不在源码提交或 Windows 便携产物中。
