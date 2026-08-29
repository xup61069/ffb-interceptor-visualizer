# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing

function New-DashboardPreview {
    param([string]$Name, [string]$Destination)

    $isOverlay = $Name -like '*Overlay*'
    $width = if ($isOverlay) { 480 } else { 800 }
    $height = if ($isOverlay) { 160 } else { 480 }
    # Keep the script source ASCII-safe for Windows PowerShell 5, which reads
    # BOM-less UTF-8 source using the active ANSI code page.
    $separator = [char]0x00B7
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $background = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#101318'))
    $panel = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#1B2128'))
    $track = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#29313A'))
    $red = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#FF5252'))
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#F4F6F8'))
    $muted = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#9FAAB6'))
    $border = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml('#39434E'), 1)

    try {
        $graphics.FillRectangle($background, 0, 0, $width, $height)
        if ($isOverlay) {
            $graphics.FillRectangle($red, 3, 3, 7, 154)
            $titleFont = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $stateFont = New-Object System.Drawing.Font('Segoe UI', 27, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $valueFont = New-Object System.Drawing.Font('Segoe UI', 29, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $smallFont = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            try {
                $graphics.DrawString('FFB COMMAND', $titleFont, $muted, 23, 14)
                $graphics.DrawString('CLIP', $stateFont, $white, 23, 38)
                $graphics.FillRectangle($track, 176, 27, 282, 30)
                $graphics.FillRectangle($red, 176, 27, 279, 30)
                $graphics.FillRectangle($white, 450, 23, 3, 38)
                $graphics.DrawString('99.4%', $valueFont, $white, 176, 65)
                $graphics.DrawString('CLIP 1S   7.8%', $titleFont, $white, 315, 70)
                $graphics.DrawString("game.exe $separator COMMAND $separator NOT MOTOR TORQUE", $smallFont, $muted, 23, 119)
            }
            finally { $titleFont.Dispose(); $stateFont.Dispose(); $valueFont.Dispose(); $smallFont.Dispose() }
        }
        else {
            $titleFont = New-Object System.Drawing.Font('Segoe UI', 24, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $labelFont = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $valueFont = New-Object System.Drawing.Font('Segoe UI', 31, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $monoFont = New-Object System.Drawing.Font('Consolas', 15, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            try {
                $graphics.FillRectangle($red, 24, 22, 64, 6)
                $graphics.DrawString('FFB INTERCEPTOR', $titleFont, $white, 24, 31)
                $graphics.DrawString("game.exe $separator PID 4242 $separator AUTOMATIC", $labelFont, $muted, 520, 36)
                $graphics.FillRectangle($panel, 24, 84, 752, 90)
                $graphics.DrawRectangle($border, 24, 84, 752, 90)
                $graphics.DrawString('DIRECTINPUT COMMAND', $labelFont, $muted, 40, 94)
                $graphics.FillRectangle($track, 40, 128, 575, 26)
                $graphics.FillRectangle($red, 40, 128, 571, 26)
                $graphics.FillRectangle($white, 602, 124, 3, 34)
                $graphics.DrawString('99.4%', $valueFont, $white, 641, 111)

                $graphics.FillRectangle($red, 24, 190, 220, 126)
                $graphics.DrawString('CLIP', $valueFont, $white, 91, 215)
                $graphics.DrawString('98% / 95% HYSTERESIS', $labelFont, $white, 48, 276)
                foreach ($x in @(260, 436, 612)) { $graphics.FillRectangle($panel, $x, 190, 160, 126); $graphics.DrawRectangle($border, $x, 190, 160, 126) }
                $graphics.DrawString("CLIP $separator 1 SECOND", $labelFont, $muted, 273, 208)
                $graphics.DrawString('7.8%', $valueFont, $white, 300, 248)
                $graphics.DrawString('PEAK COMMAND', $labelFont, $muted, 454, 208)
                $graphics.DrawString('100%', $valueFont, $white, 470, 248)
                $graphics.DrawString('AFTER GAINS', $labelFont, $muted, 638, 208)
                $graphics.DrawString('62.1%', $valueFont, $white, 635, 248)

                $graphics.FillRectangle($panel, 24, 334, 752, 96)
                $graphics.DrawString('EFFECT GAIN  80.0%       ACTIVE  2       DROPS  0', $monoFont, $white, 42, 350)
                $graphics.DrawString('DEVICE GAIN  78.0%       UNSUPPORTED  1  PROTOCOL ERRORS  0', $monoFont, $white, 42, 392)
                $graphics.DrawString("COMMAND SIGNAL $separator NOT PHYSICAL MOTOR TORQUE", $labelFont, $muted, 24, 449)
            }
            finally { $titleFont.Dispose(); $labelFont.Dispose(); $valueFont.Dispose(); $monoFont.Dispose() }
        }
        $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $border.Dispose(); $muted.Dispose(); $white.Dispose(); $red.Dispose()
        $track.Dispose(); $panel.Dispose(); $background.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    }
}

$sourceDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Dashboards'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\dist'
}
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null

$dashboards = @(
    'FFB Interceptor 800x480',
    'FFB Interceptor Overlay 480x160'
)

foreach ($name in $dashboards) {
    $definition = Join-Path $sourceDirectory ($name + '.djson')
    $metadata = $definition + '.metadata'
    Get-Content -LiteralPath $definition -Raw | ConvertFrom-Json | Out-Null
    Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json | Out-Null

    $temporaryRoot = [System.IO.Path]::GetFullPath(
        (Join-Path ([System.IO.Path]::GetTempPath()) ('ffb-interceptor-dashboard-' + [Guid]::NewGuid().ToString('N'))))
    $systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([System.IO.Path]::GetFileName($temporaryRoot)).StartsWith('ffb-interceptor-dashboard-', [StringComparison]::Ordinal)) {
        throw "Unsafe temporary path: $temporaryRoot"
    }

    try {
        $dashboardFolder = Join-Path $temporaryRoot $name
        [System.IO.Directory]::CreateDirectory($dashboardFolder) | Out-Null
        Copy-Item -LiteralPath $definition -Destination (Join-Path $dashboardFolder ($name + '.djson'))
        Copy-Item -LiteralPath $metadata -Destination (Join-Path $dashboardFolder ($name + '.djson.metadata'))
        $preview = Join-Path $dashboardFolder ($name + '.djson.png')
        New-DashboardPreview -Name $name -Destination $preview
        Copy-Item -LiteralPath $preview -Destination (Join-Path $dashboardFolder ($name + '.djson.00.png'))
        Copy-Item -LiteralPath $preview -Destination (Join-Path $resolvedOutput ($name + '.preview.png')) -Force

        $package = [System.IO.Path]::GetFullPath((Join-Path $resolvedOutput ($name + '.simhubdash')))
        if (-not $package.StartsWith($resolvedOutput, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe output path: $package"
        }
        if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $temporaryRoot,
            $package,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false)
        Write-Host "Built $package"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }
}
