# read-doc.ps1 - read a PDF as text, and page images only when asked.
# Usage: powershell -ExecutionPolicy Bypass -File tools\read-doc.ps1 -File <pdf> [-OutDir <dir>] [-MaxPages 20] [-Pages 'a-b'] [-Images]
# Output: <name>-doc\doc.txt (layout-preserved text); page-01.png ... only with -Images.
# Final line: DOC_READY <dir> pages=<n> chars=<n> images=<n>
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$OutDir,
    [int]$MaxPages = 20,
    [int]$Dpi = 110,
    [string]$Pages = '',
    [switch]$Images
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
function Fail([string]$r) { Write-Output "DOC_FAILED $r next: check the file exists and really is a PDF"; exit 1 }

$poppler = "$env:USERPROFILE\tools\bin\poppler"
$pdftotext = Join-Path $poppler 'pdftotext.exe'
$pdftoppm  = Join-Path $poppler 'pdftoppm.exe'
$pdfinfo   = Join-Path $poppler 'pdfinfo.exe'
if (-not (Test-Path $pdftotext)) { Fail 'pdftotext not installed' }
try { $pdfPath = (Resolve-Path -LiteralPath $File).Path } catch { Fail "file not found: $File" }
if ([IO.Path]::GetExtension($pdfPath) -ne '.pdf') { Fail 'only PDF is supported' }

if (-not $OutDir) {
    $base = [IO.Path]::GetFileNameWithoutExtension($pdfPath)
    $OutDir = Join-Path ([IO.Path]::GetDirectoryName($pdfPath)) ($base + '-doc')
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outPath = (Resolve-Path -LiteralPath $OutDir).Path

# NOTE: the page-count variable must not be named $pages - PowerShell names are
# case-insensitive and it would collide with the -Pages parameter.
$totalPages = 0
# poppler prints syntax warnings to stderr for imperfect PDFs; with
# ErrorActionPreference=Stop those become terminating errors, so run all
# poppler calls with it softened (results are checked via the output files).
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
if (Test-Path $pdfinfo) {
    $info = & $pdfinfo $pdfPath 2>$null
    foreach ($line in $info) { if ($line -match '^Pages:\s+(\d+)') { $totalPages = [int]$Matches[1] } }
}
$firstPage = 1
$lastPage = $totalPages
if ($Pages -match '^\s*(\d+)\s*-\s*(\d+)\s*$') { $firstPage = [int]$Matches[1]; $lastPage = [int]$Matches[2] }
elseif ($Pages -match '^\s*(\d+)\s*$') { $firstPage = [int]$Matches[1]; $lastPage = [int]$Matches[1] }
elseif ($Pages) { $ErrorActionPreference = $prevEap; Fail "bad -Pages format, use 'a-b' or 'a'" }
if ($lastPage -le 0 -or ($totalPages -gt 0 -and $lastPage -gt $totalPages)) { $lastPage = $totalPages }
if ($lastPage -le 0) { $lastPage = $MaxPages }
if (($lastPage - $firstPage + 1) -gt $MaxPages) { $lastPage = $firstPage + $MaxPages - 1 }

$txtPath = Join-Path $outPath 'doc.txt'
& $pdftotext -layout -enc UTF-8 -f $firstPage -l $lastPage $pdfPath $txtPath 2>$null
$ErrorActionPreference = $prevEap
if (-not (Test-Path $txtPath)) { Fail 'pdftotext produced no output' }
$chars = ([IO.File]::ReadAllText($txtPath, [Text.Encoding]::UTF8)).Length

$imgCount = 0
if ($Images) {
    $ErrorActionPreference = 'Continue'
    $prefix = Join-Path $outPath 'page'
    & $pdftoppm -png -r $Dpi -f $firstPage -l $lastPage $pdfPath $prefix 2>$null
    $ErrorActionPreference = $prevEap
    $imgCount = @(Get-ChildItem $outPath -Filter 'page-*.png' -File -ErrorAction SilentlyContinue).Count
}

Write-Output ("PAGES total={0} range={1}-{2} images={3}" -f $totalPages, $firstPage, $lastPage, $imgCount)
Write-Output "DOC_READY $outPath pages=$($lastPage - $firstPage + 1) chars=$chars images=$imgCount"
