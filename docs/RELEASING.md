# 版本、签名与发布

`VERSION` 是版本来源。Windows 各项目直接读取它；macOS 版本常量、Info.plist、根目录 `version.txt` 由以下命令同步。应用版本显示与 User-Agent 使用平台版本信息。

```sh
python3 script/version.py --set 0.5.0
python3 script/version.py
python3 -m unittest discover -s script/tests -v
```

更新 README 下载链接及 `docs/releases/v<版本>.md`，将发布改动整理为一个提交。PR 检查通过后合入 main，再推送对应 `v*` 标签。标签 Release 工作流执行两端测试、打包、真实签名与验证；全部通过后才上传 OSS 并创建 Release。需要单独预演签名或打包改动时，可先在发布分支运行 `workflow_dispatch`，它不发布产物。

## 凭据

GitHub Actions Secrets：

| Secret | 用途 |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | 含私钥的 Developer ID Application .p12 的 Base64 |
| `APPLE_CERTIFICATE_PASSWORD` | .p12 导出密码 |
| `APPLE_TEAM_ID` | 签名与公证团队 |
| `APPLE_ACCOUNT_EMAIL` | 公证账号，映射为 `APPLE_ID` |
| `APPLE_APP_PASSWORD` | Apple 应用专用密码 |
| `AZURE_YAK_CODE_SIGN_KEY_VAULT_URI` | Azure Key Vault 地址 |
| `AZURE_YAK_CODE_SIGN_KEY_VAULT_APPLICATION_ID` | Azure 应用 ID |
| `AZURE_YAK_CODE_SIGN_KEY_VAULT_CLIENT_SECRET` | Azure 应用凭据 |
| `AZURE_YAK_CODE_SIGN_KEY_VAULT_CERT_NAME` | 签名证书名 |
| `AZURE_YAK_CODE_SIGN_KEY_VAULT_DIRECTORY_ID` | Azure 租户 ID |
| `AZURE_YAK_CODE_SIGN_KEY_VAULT_TIMESTAMP_URL` | 可选时间戳服务，默认 DigiCert |
| `YCONNECT_UPDATE_PRIVATE_KEY` | Ed25519 更新签名私钥，PEM 格式；公钥固定在客户端中 |
| `OSS_KEY_ID` / `OSS_KEY_SECRET` | OSS 发布凭据 |

可使用共享给仓库的组织 Secrets。正式发布缺少必需凭据或验签失败会停止。普通分支和 PR 的构建不使用签名凭据。

## 验证与分发

- macOS：导入临时 Keychain，签署 Universal 应用，核对 Developer ID 与 Team ID；应用和 DMG 分别公证、staple，再从挂载的 DMG 检查签名、公证票据、架构、版本与 Gatekeeper；测试已打包程序的终端交互和凭据清理。
- Windows：运行单元及 UI/启动器测试，再签署凭据助手、启动器和主程序；凭据助手签名后嵌入主程序。签署安装程序与卸载程序，解压 ZIP、实际安装后核对签名、时间戳、证书一致性、版本与文件哈希，最后执行卸载测试。
- 发布：先上传 `oss://yaklang/yconnect/<版本>/`，从 CDN 下载并比较 SHA-256，再更新根目录索引，最后创建 GitHub Release。

每个版本包含 DMG、安装 EXE、便携 ZIP、各文件 `.sha256.txt`、`SHA256SUMS` / `SHA256SUMS.txt`、`manifest.json` 和 `version.txt`。

根目录维护 `version.txt`、`latest.txt`、`latest-version.txt`（纯版本号）、`latest.json`（当前版本 manifest）、`releases.json`（历史版本）。JSON 使用不转换内容的响应元数据，兼容原始字节读取。manifest 沿用 YTray 的 `schema_version/product/version/released_at/assets` 格式；Windows 文件名使用 x64，manifest 架构为 amd64；macOS 架构为 universal。

发布器从 OSS 读取历史索引，拒绝版本倒退或覆盖不同内容的既有版本文件。公证时间戳会使重新构建的产物产生不同哈希；已有版本目录时应复用已验证产物恢复发布，或修复后递增版本，不能直接覆盖。

公共入口：`https://aliyun-oss.yaklang.com/yconnect/`。这些文件提供下载与版本查询元数据；0.5.0 起支持用户点击触发的应用内更新，后台只进行版本检查。

## 终端与系统兼容验收

正式签名验收实测 macOS Terminal、iTerm2、Ghostty 和所选终端缺失时的回退，并验证 TTY、模型、工作目录、单次消费与凭据清理。kitty、WezTerm、Alacritty 是可选兼容入口，不保证所有环境可用；保留启动参数测试，可用 `--smoke-terminal-launch <bundle-id>` 做本机补验。

macOS 14 运行完整测试；Tahoe 的 Apple Silicon 和 Intel 使用同一个 Universal 安装包执行启动、窗口和重新打开检查。两端的代码签名、安装/卸载、更新验签和篡改拒绝继续作为发布门槛。
