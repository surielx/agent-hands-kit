# img-peek.ps1 - make a small preview of an image for visual checks, so the full
# image itself does not have to be read into the context.
# Modes:
#   (default)      shrink the whole image so its long edge is <= -MaxEdge
#   -Crop x,y,w,h  cut one region (original-image coordinates), then shrink if needed
#   -Crops "x,y,w,h;x,y,w,h;..."  cut several regions and tile them into one sheet,
#                  each cell labelled with its index and origin (original coordinates)
#   -Pair <image2> place this image and image2 side by side, each shrunk to fit -MaxEdge
# Read the preview, then map positions back: original = origin + preview_coord / scale
# (origin and scale are printed in the result line).
# Usage: powershell -ExecutionPolicy Bypass -File tools\img-peek.ps1 -Image <png|jpg> [-Crop x,y,w,h] [-Crops "x,y,w,h;..."] [-Pair <image>] [-MaxEdge 512] [-Out <png>]
# Final line: IMGPEEK_OK <out> size=<w>x<h> src=<W>x<H> [origin=<x>,<y> scale=<s>] / IMGPEEK_FAILED <reason> next: <what to try>
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [string]$Crop,
    [string]$Crops,
    [string]$Pair,
    [int]$MaxEdge = 512,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
function Fail([string]$r, [string]$next) { Write-Output "IMGPEEK_FAILED $r next: $next"; exit 1 }

Add-Type -AssemblyName System.Drawing

function Parse-Rect([string]$s) {
    $p = $s.Split(',') | ForEach-Object { $_.Trim() }
    if ($p.Count -ne 4) { throw "bad rect: $s" }
    $v = $p | ForEach-Object { [int]$_ }
    return [System.Drawing.Rectangle]::new($v[0], $v[1], $v[2], $v[3])
}
function Fit-Scale([int]$w, [int]$h, [int]$maxW, [int]$maxH) {
    $s = [Math]::Min($maxW / [double]$w, $maxH / [double]$h)
    if ($s -gt 1) { $s = 1 }
    return $s
}
function Resize-Bmp([System.Drawing.Bitmap]$src, [int]$nw, [int]$nh) {
    $dst = [System.Drawing.Bitmap]::new($nw, $nh)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, $nw, $nh)
    } finally { $g.Dispose() }
    return $dst
}
function Clamp-Rect([System.Drawing.Rectangle]$r, [int]$W, [int]$H) {
    $x = [Math]::Max(0, $r.X); $y = [Math]::Max(0, $r.Y)
    $w = [Math]::Min($r.Width, $W - $x); $h = [Math]::Min($r.Height, $H - $y)
    if ($w -le 0 -or $h -le 0) { return $null }
    return [System.Drawing.Rectangle]::new($x, $y, $w, $h)
}

try { $imgPath = (Resolve-Path -LiteralPath $Image).Path } catch { Fail "image not found: $Image" 'check the path' }
$src = [System.Drawing.Bitmap]::new($imgPath)
$W = $src.Width; $H = $src.Height
$dir = [IO.Path]::GetDirectoryName($imgPath)
$base = [IO.Path]::GetFileNameWithoutExtension($imgPath)
$mode = 'full'; $extra = ''
$result = $null
try {
    if ($Crops) {
        $mode = 'sheet'
        $rects = @()
        foreach ($part in $Crops.Split(';')) {
            if ($part.Trim().Length -eq 0) { continue }
            try { $r = Parse-Rect $part } catch { Fail "bad -Crops entry: $part" 'use x,y,w,h;x,y,w,h in original coordinates' }
            $cr = Clamp-Rect $r $W $H
            if (-not $cr) { Fail "crop outside image: $part" 'keep regions inside the source image' }
            $rects += $cr
        }
        if ($rects.Count -eq 0) { Fail 'no crops given' 'pass at least one region' }
        $cellMax = 360; $labelH = 20
        $cells = @()
        foreach ($r in $rects) {
            $piece = $src.Clone($r, $src.PixelFormat)
            $s = Fit-Scale $r.Width $r.Height $cellMax $cellMax
            $nw = [Math]::Max(1, [int][Math]::Round($r.Width * $s)); $nh = [Math]::Max(1, [int][Math]::Round($r.Height * $s))
            $small = Resize-Bmp $piece $nw $nh
            $piece.Dispose()
            $cells += @{ Img = $small; Rect = $r }
        }
        $cols = if ($cells.Count -le 2) { $cells.Count } elseif ($cells.Count -le 4) { 2 } else { 3 }
        $rows = [int][Math]::Ceiling($cells.Count / $cols)
        $colW = @{}; $rowH = @{}
        for ($i = 0; $i -lt $cells.Count; $i++) {
            $c = $i % $cols; $rw = [int][Math]::Floor($i / $cols)
            if (-not $colW.ContainsKey($c) -or $cells[$i].Img.Width -gt $colW[$c]) { $colW[$c] = $cells[$i].Img.Width }
            $hh = $cells[$i].Img.Height + $labelH
            if (-not $rowH.ContainsKey($rw) -or $hh -gt $rowH[$rw]) { $rowH[$rw] = $hh }
        }
        $sheetW = 0; foreach ($k in $colW.Keys) { $sheetW += $colW[$k] }
        $sheetH = 0; foreach ($k in $rowH.Keys) { $sheetH += $rowH[$k] }
        $sheet = [System.Drawing.Bitmap]::new($sheetW, $sheetH)
        $g = [System.Drawing.Graphics]::FromImage($sheet)
        try {
            $font = New-Object System.Drawing.Font ('Consolas', 11, [System.Drawing.FontStyle]::Bold)
            $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
            $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
            $yOff = @{}; $acc = 0; for ($rw = 0; $rw -lt $rows; $rw++) { $yOff[$rw] = $acc; $acc += $rowH[$rw] }
            $xOff = @{}; $acc = 0; for ($c = 0; $c -lt $cols; $c++) { $xOff[$c] = $acc; $acc += $colW[$c] }
            for ($i = 0; $i -lt $cells.Count; $i++) {
                $c = $i % $cols; $rw = [int][Math]::Floor($i / $cols)
                $x = $xOff[$c]; $y = $yOff[$rw]
                $r = $cells[$i].Rect
                $g.FillRectangle($bg, $x, $y, $colW[$c], $labelH)
                $g.DrawString(("#{0} {1},{2},{3},{4}" -f $i, $r.X, $r.Y, $r.Width, $r.Height), $font, $brush, $x + 2, $y + 2)
                $g.DrawImage($cells[$i].Img, $x, $y + $labelH)
                $cells[$i].Img.Dispose()
            }
        } finally { $g.Dispose() }
        $s2 = Fit-Scale $sheetW $sheetH 1200 1200
        if ($s2 -lt 1) {
            $smallSheet = Resize-Bmp $sheet ([int][Math]::Round($sheetW * $s2)) ([int][Math]::Round($sheetH * $s2))
            $sheet.Dispose(); $result = $smallSheet
        } else { $result = $sheet }
        $extra = "cells=$($cells.Count)"
        if (-not $Out) { $Out = Join-Path $dir ($base + '-peek-sheet.png') }
    } elseif ($Crop) {
        $mode = 'crop'
        try { $r0 = Parse-Rect $Crop } catch { Fail "bad -Crop: $Crop" 'use x,y,w,h in original coordinates' }
        $r = Clamp-Rect $r0 $W $H
        if (-not $r) { Fail "crop outside image: $Crop" 'keep the region inside the source image' }
        $piece = $src.Clone($r, $src.PixelFormat)
        $s = Fit-Scale $r.Width $r.Height $MaxEdge $MaxEdge
        $nw = [Math]::Max(1, [int][Math]::Round($r.Width * $s)); $nh = [Math]::Max(1, [int][Math]::Round($r.Height * $s))
        $result = Resize-Bmp $piece $nw $nh
        $piece.Dispose()
        $extra = "origin=$($r.X),$($r.Y) scale=$([Math]::Round($s, 3))"
        if (-not $Out) { $Out = Join-Path $dir ($base + '-peek-crop.png') }
    } elseif ($Pair) {
        $mode = 'pair'
        try { $pairPath = (Resolve-Path -LiteralPath $Pair).Path } catch { Fail "pair image not found: $Pair" 'check the path' }
        $src2 = [System.Drawing.Bitmap]::new($pairPath)
        try {
            $s1 = Fit-Scale $W $H $MaxEdge $MaxEdge
            $a = Resize-Bmp $src ([int][Math]::Max(1, [int][Math]::Round($W * $s1))) ([int][Math]::Max(1, [int][Math]::Round($H * $s1)))
            $s2 = Fit-Scale $src2.Width $src2.Height $MaxEdge $MaxEdge
            $b = Resize-Bmp $src2 ([int][Math]::Max(1, [int][Math]::Round($src2.Width * $s2))) ([int][Math]::Max(1, [int][Math]::Round($src2.Height * $s2)))
            $gap = 8
            $cw = $a.Width + $gap + $b.Width; $ch = [Math]::Max($a.Height, $b.Height)
            $canvas = [System.Drawing.Bitmap]::new($cw, $ch)
            $g = [System.Drawing.Graphics]::FromImage($canvas)
            try { $g.DrawImage($a, 0, 0); $g.DrawImage($b, $a.Width + $gap, 0) } finally { $g.Dispose() }
            $a.Dispose(); $b.Dispose()
            $s3 = Fit-Scale $cw $ch 1200 1200
            if ($s3 -lt 1) {
                $smallCanvas = Resize-Bmp $canvas ([int][Math]::Round($cw * $s3)) ([int][Math]::Round($ch * $s3))
                $canvas.Dispose(); $result = $smallCanvas
            } else { $result = $canvas }
        } finally { $src2.Dispose() }
        $extra = 'pair=left:Image right:Pair'
        if (-not $Out) { $Out = Join-Path $dir ($base + '-peek-pair.png') }
    } else {
        $s = Fit-Scale $W $H $MaxEdge $MaxEdge
        $nw = [Math]::Max(1, [int][Math]::Round($W * $s)); $nh = [Math]::Max(1, [int][Math]::Round($H * $s))
        $result = Resize-Bmp $src $nw $nh
        $extra = "scale=$([Math]::Round($s, 3))"
        if (-not $Out) { $Out = Join-Path $dir ($base + '-peek.png') }
    }
    $result.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output "IMGPEEK_OK $Out size=$($result.Width)x$($result.Height) src=${W}x${H} mode=$mode $extra"
    $result.Dispose()
} finally {
    $src.Dispose()
}
