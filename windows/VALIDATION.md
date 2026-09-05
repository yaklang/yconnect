# Windows 本机验证记录

日期：2026-09-05。最终构建：`20260905-105649`，Windows x64 / .NET Framework 4.8 / WPF。

## 已验证

- `build.ps1 -Test -Smoke -Package -VerifyLogin -NoProxy` 完整通过，Release 构建 0 警告、0 错误。
- 31 项核心测试通过：8 个客户端、协议筛选、原生凭证读取器、重复应用不写入、原始字节恢复、Windows UTF-8 BOM、外部改动保护、多文件失败回滚、写后校验、私有 ACL/DPAPI、拒绝硬链接、会话恢复/退出/过期/断网重试、HTTP 凭证隔离。
- 源码构建和便携包均完成原生 WPF 控件自动操作。每次记录 43 次按钮操作，并通过真实原生确认弹窗完成全部 8 个适配器的应用和恢复；另覆盖模型搜索/筛选、模拟 Key CRUD/兑换、基础检查、测试调用确认、两种登录模式、PIN/失焦、左右贴边和主题切换。
- 实际 Windows 合成截图和 WPF 视觉树截图均生成并人工视觉检查。小组件正文不透明，圆角外透明；浅色/深色主题、阴影、按钮文字对比度和管理窗口底色正常。原生截图使用本应用自己的受控背景。
- 本机真实显示器工作区为 3440 × 1392（100% DPI）。100%/125%/150%/200% 缩放、负坐标显示器和左右定位另有几何单元测试，并非宣称全部真实多屏环境已经实机测试。
- 真实官网 `/api/health` 返回 `ok`。遵循本机代理时官网提示登录暂不可用；启用应用直连后，官方页面及微信二维码正常加载，并截图确认二维码与提示完整可见。API 与 WebView2 一起绕过代理，系统设置未更改。
- 便携包体积 799,426 字节（约 780.7 KiB）；解压后 2,202,684 字节（约 2.10 MiB）。EXE 为 218,624 字节。无需捆绑 Electron、Chromium 或 .NET 运行时。未打开扫码窗口时没有浏览器子进程。
- 本机空闲采样（未登录、托盘常驻、开发隔离目录）：工作集约 91 MiB，private bytes 约 75 MiB；66.5 秒内累计 CPU 时间保持 0.59375 秒不变。该数据不是所有设备或登录后的内存上限，扫码窗口的 WebView2 另有临时占用。

证据保存在本机忽略目录 `windows/.test-output/20260905-105649/`：

- `core/results.txt`
- `native-ui/ui-results.txt`、`packaged-native-ui/ui-results.txt`
- `packaged-native-ui/20-widget-light-native.png`
- `packaged-native-ui/21-widget-dark-native.png`
- `packaged-native-ui/22-manager-native.png`
- `official-login/live-login-results.json`、`official-login/official-login-native.png`

## 仍需要用户授权的在线验证

真实 YakCool 账户尚未扫码授权。真实余额同步、在线 Key 创建/删除、兑换到账和付费模型调用没有用模拟数据冒充已完成。当前 CRUD、兑换与配置测试全部使用醒目标记的演示数据和隔离目录；未修改用户真实客户端配置、系统代理或开机启动项。

8 个适配器已经验证生成内容、原生界面应用与恢复，但不代表本机已安装并运行全部第三方客户端。Windows 原生配置不等于 WSL 中的配置。Gemini CLI 仍需协议桥。

便携包未代码签名，未进行其他 Windows 设备、ARM64、商店安装包或真实多显示器的端到端发行验证。
