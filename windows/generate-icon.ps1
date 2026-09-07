$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$assetDirectory = Join-Path $PSScriptRoot 'Assets'
[void][System.IO.Directory]::CreateDirectory($assetDirectory)
$brandDirectory = Join-Path $PSScriptRoot '..\resources\brand'

# Keep the supplied artwork, including its transparency and padding. Windows
# 10/11 supports PNG-compressed frames at all the sizes below.
function Write-BrandIcon([string]$Source, [string]$Destination) {
    $image = [System.Drawing.Image]::FromFile($Source)
    $sizes = @(16,24,32,40,48,64,128,256)
    $frames = New-Object 'System.Collections.Generic.List[byte[]]'
    try {
        foreach ($size in $sizes) {
            $bitmap = New-Object System.Drawing.Bitmap $size,$size
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $frame = New-Object System.IO.MemoryStream
            try {
                $graphics.Clear([System.Drawing.Color]::Transparent)
                $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.DrawImage($image, 0, 0, $size, $size)
                $bitmap.Save($frame, [System.Drawing.Imaging.ImageFormat]::Png)
                $frames.Add($frame.ToArray())
            } finally { $frame.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
        }
        $stream = [System.IO.File]::Create($Destination)
        $writer = New-Object System.IO.BinaryWriter $stream
        try {
            $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
            $offset = 6 + 16 * $sizes.Count
            for ($i = 0; $i -lt $sizes.Count; $i++) {
                $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
                $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
                $writer.Write([byte]0); $writer.Write([byte]0)
                $writer.Write([uint16]1); $writer.Write([uint16]32)
                $writer.Write([uint32]$frames[$i].Length); $writer.Write([uint32]$offset)
                $offset += $frames[$i].Length
            }
            foreach ($bytes in $frames) { $writer.Write($bytes) }
        } finally { $writer.Dispose(); $stream.Dispose() }
    } finally { $image.Dispose() }
}

Write-BrandIcon (Join-Path $brandDirectory 'yakcool-desktop.png') (Join-Path $assetDirectory 'yconnect.ico')
Write-BrandIcon (Join-Path $brandDirectory 'yakcool-tile.png') (Join-Path $assetDirectory 'yconnect-tray.ico')
