$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$assetDirectory = Join-Path $PSScriptRoot 'Assets'
[void][System.IO.Directory]::CreateDirectory($assetDirectory)
$bitmap = New-Object System.Drawing.Bitmap 64,64
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(185,105,83))
$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White),5
try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pen.StartCap = $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.FillEllipse($brush,2,2,60,60)
    $graphics.DrawLine($pen,19,19,32,35)
    $graphics.DrawLine($pen,32,35,45,19)
    $graphics.DrawLine($pen,32,35,32,48)
    $handle = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($handle)
    $stream = [System.IO.File]::Create((Join-Path $assetDirectory 'yconnect.ico'))
    try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose() }
} finally { $pen.Dispose(); $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
