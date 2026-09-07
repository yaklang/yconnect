# YAKCOOL / Y CONNECT 品牌资源

来自用户提供的 YakCool.zip，保留原始矢量曲线与桌面图标。

| 文件 | 用途 |
| --- | --- |
| yakcool-mark.svg | 透明底主色 LOGO，应用内原生矢量的来源 |
| yakcool-mark-inverse.svg | 透明底白色反白标识 |
| yakcool-tile.svg | 主色底白色标识，托盘和彩色小图标 |
| yakcool-desktop.png | 原始 1024px 立体桌面图标，生成 macOS ICNS 和 Windows ICO |
| yakcool-tile.png | tile SVG 的 1024px 派生文件，供 Windows 图标生成脚本读取 |

macOS：`script/package-macos.sh` 直接缩放桌面 PNG，保留透明度；`BrandMark.swift` 精确保留 SVG 路径。Windows：`Views/Ui.cs` 使用同一路径生成 WPF Geometry，`windows/generate-icon.ps1` 生成应用与托盘的多尺寸图标。两个 ICO 作为资源纳入版本管理，新检出即可打包。

名称仅用于显示：YAKCOOL、Y CONNECT。内部标识、存储目录与现有安装升级标识继续沿用，避免丢失登录和配置。
