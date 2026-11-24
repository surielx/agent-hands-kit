# web-read.ps1 - read a web page as extracted main text, in bounded chunks.
# Usage:
#   web-read.ps1 -Url <url> [-Offset <char offset>] [-MaxChars <n, default 6000>] [-Refresh]
#   web-read.ps1 -Url <source url> -Link <n>   (follow the n-th link of the source page, then read it)
# Output: a header line (chars A-B / total, next offset), at most MaxChars of text,
#         the links whose anchor text appears inside the returned range ([n] text -> url),
#         and a final line "WEB_READ_OK next=<offset|END> total=<chars> cache=<file>".
# The full extracted text and the link list are cached under $env:AGENT_HOME\fetched\
# so continuation reads (-Offset) and link follows do NOT refetch the page.
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [int]$Offset = 0,
    [int]$MaxChars = 6000,
    [int]$Link = 0,
    [switch]$Refresh,
    [switch]$Outline,
    [string]$Find = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Fail([string]$reason) {
    Write-Output "WEB_READ_FAILED $reason next: check the URL is right; for JavaScript-heavy pages use the browser agent instead"
    exit 1
}

if ($MaxChars -lt 500) { $MaxChars = 500 }
if ($MaxChars -gt 20000) { $MaxChars = 20000 }
if ($Offset -lt 0) { $Offset = 0 }

$cacheDir = "$env:AGENT_HOME\fetched"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

function Get-Slug([string]$u) {
    try {
        $uri = [System.Uri]$u
        $s = ($uri.Host + $uri.AbsolutePath) -replace '[^A-Za-z0-9]+', '_'
        $s = $s.Trim('_')
        if ($s.Length -gt 80) { $s = $s.Substring(0, 80) }
        return $s
    } catch { Fail "bad URL: $u" }
}

function Get-LinksFile([string]$slug) { Join-Path $cacheDir "$slug.links.txt" }
function Get-TextFile([string]$slug) { Join-Path $cacheDir "$slug.read.txt" }
function Get-OutlineFile([string]$slug) { Join-Path $cacheDir "$slug.outline.txt" }

# --- link follow: resolve against the source page's cached link list ---
if ($Link -gt 0) {
    $srcSlug = Get-Slug $Url
    $lf = Get-LinksFile $srcSlug
    if (-not (Test-Path -LiteralPath $lf)) { Fail "no cached links for source page; read it first: $Url" }
    $lines = [IO.File]::ReadAllLines($lf, [Text.Encoding]::UTF8)
    $found = $null
    foreach ($ln in $lines) {
        $parts = $ln -split "`t", 3
        if ($parts.Count -eq 3 -and [int]$parts[0] -eq $Link) { $found = $parts[2]; break }
    }
    if (-not $found) { Fail "link $Link not found on $Url" }
    Write-Output "WEB_READ_FOLLOW link=$Link url=$found"
    $Url = $found
    $Offset = 0
}

$slug = Get-Slug $Url
$textFile = Get-TextFile $slug
$linksFile = Get-LinksFile $slug

# --- fetch + extract when not cached ---
if ($Refresh -or -not (Test-Path -LiteralPath $textFile)) {
    $html = $null
    $browser = $null
    $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { $browser = $c; break } }
    if ($browser) {
        $domFile = Join-Path $env:TEMP 'web-read.dom.html'
        $errFile = Join-Path $env:TEMP 'web-read.err.log'
        $profileDir = Join-Path $env:TEMP 'web-read-profile'
        if (Test-Path -LiteralPath $profileDir) { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue }
        $bargs = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', "--user-data-dir=$profileDir", '--virtual-time-budget=8000', '--dump-dom', $Url)
        try {
            $p = Start-Process -FilePath $browser -ArgumentList $bargs -PassThru -WindowStyle Hidden -RedirectStandardOutput $domFile -RedirectStandardError $errFile
            if ($p.WaitForExit(90000) -and (Test-Path -LiteralPath $domFile)) {
                $html = [IO.File]::ReadAllText($domFile, [Text.Encoding]::UTF8)
            } else { try { $p.Kill() } catch {} }
        } catch { $html = $null }
        Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $html -or $html.Length -lt 200) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AgentRead/1.0' } -TimeoutSec 60 -UseBasicParsing
            $html = $resp.Content
        } catch { Fail "fetch failed: $($_.Exception.Message)" }
    }
    if (-not $html) { Fail "empty response" }

    # links first (before tags are stripped): numbered, in document order, absolute URLs
    $baseUri = [System.Uri]$Url
    $linkLines = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $idx = 0
    foreach ($m in [regex]::Matches($html, '(?is)<a\s[^>]*?href\s*=\s*["'']([^"'']+)["''][^>]*>(.*?)</a>')) {
        $href = $m.Groups[1].Value.Trim()
        if (-not $href -or $href.StartsWith('#') -or $href.StartsWith('javascript:') -or $href.StartsWith('mailto:')) { continue }
        try { $abs = ([System.Uri]::new($baseUri, $href)).AbsoluteUri } catch { continue }
        $atext = [regex]::Replace($m.Groups[2].Value, '(?s)<[^>]+>', ' ')
        $atext = [System.Net.WebUtility]::HtmlDecode($atext)
        $atext = [regex]::Replace($atext, '\s+', ' ').Trim()
        if ($atext.Length -gt 80) { $atext = $atext.Substring(0, 80) }
        if ($seen.ContainsKey($abs)) { continue }
        $seen[$abs] = $true
        $idx++
        $linkLines.Add("$idx`t$atext`t$abs")
    }
    [IO.File]::WriteAllLines($linksFile, $linkLines, [Text.Encoding]::UTF8)

    # main text extraction (same approach as web-fetch.ps1)
    $text = $html
    $text = [regex]::Replace($text, '(?is)<script.*?</script>', ' ')
    $text = [regex]::Replace($text, '(?is)<style.*?</style>', ' ')
    $text = [regex]::Replace($text, '(?is)<svg.*?</svg>', ' ')
    $text = [regex]::Replace($text, '(?is)<(nav|header|footer|aside)\b.*?</\1>', ' ')
    $text = [regex]::Replace($text, '(?is)<!--.*?-->', ' ')
    $text = [regex]::Replace($text, '(?i)<br\s*/?>', "`n")
    $text = [regex]::Replace($text, '(?i)</(p|div|li|h1|h2|h3|h4|tr|section|article)>', "`n")
    $text = [regex]::Replace($text, '(?s)<[^>]+>', ' ')
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = [regex]::Replace($text, '[ \t]+', ' ')
    $text = [regex]::Replace($text, '(\r?\n\s*){3,}', "`n`n")
    $text = $text.Trim()
    [IO.File]::WriteAllText($textFile, $text, [Text.Encoding]::UTF8)

    # outline: headings from the raw HTML, located in the extracted text
    $outlineLines = New-Object System.Collections.Generic.List[string]
    $searchFrom = 0
    foreach ($m in [regex]::Matches($html, '(?is)<h([1-4])\b[^>]*>(.*?)</h\1>')) {
        $htext = [regex]::Replace($m.Groups[2].Value, '(?s)<[^>]+>', ' ')
        $htext = [System.Net.WebUtility]::HtmlDecode($htext)
        $htext = [regex]::Replace($htext, '\s+', ' ').Trim()
        if ($htext.Length -lt 2) { continue }
        $pos = $text.IndexOf($htext, $searchFrom)
        if ($pos -lt 0) { $pos = $text.IndexOf($htext) }
        if ($pos -lt 0) { continue }
        $searchFrom = $pos + $htext.Length
        $outlineLines.Add(("{0}`tH{1}`t{2}" -f $pos, $m.Groups[1].Value, $htext))
    }
    [IO.File]::WriteAllLines((Get-OutlineFile $slug), $outlineLines, [Text.Encoding]::UTF8)
}

$textAll = [IO.File]::ReadAllText($textFile, [Text.Encoding]::UTF8)
$total = $textAll.Length

if ($Outline) {
    $of = Get-OutlineFile $slug
    Write-Output "WEB_READ url=$Url mode=outline total=$total"
    if (Test-Path -LiteralPath $of) {
        $ol = [IO.File]::ReadAllLines($of, [Text.Encoding]::UTF8)
        if ($ol.Count -eq 0) { Write-Output "(no headings found on this page)" }
        else { Write-Output ($ol -join "`n") }
        Write-Output "(read a section with: web-read.ps1 -Url <url> -Offset <offset>)"
    } else {
        Write-Output "(no outline cached; run once with -Refresh to build it)"
    }
    Write-Output "WEB_READ_OK mode=outline total=$total cache=$textFile"
    exit 0
}

if ($Find) {
    $hits = New-Object System.Collections.Generic.List[int]
    $from = 0
    while ($true) {
        $p = $textAll.IndexOf($Find, $from, [StringComparison]::OrdinalIgnoreCase)
        if ($p -lt 0) { break }
        $hits.Add($p)
        $from = $p + $Find.Length
        if ($hits.Count -ge 20) { break }
    }
    Write-Output "WEB_READ url=$Url mode=find matches=$($hits.Count)"
    $shownH = 0
    foreach ($p in $hits) {
        if ($shownH -ge 5) { break }
        $s0 = [Math]::Max(0, $p - 200)
        $s1 = [Math]::Min($total, $p + $Find.Length + 200)
        Write-Output ("--- at offset $p ---")
        Write-Output $textAll.Substring($s0, $s1 - $s0)
        $shownH++
    }
    if ($hits.Count -gt $shownH) { Write-Output "(more matches exist; refine the keyword)" }
    Write-Output "WEB_READ_OK mode=find matches=$($hits.Count) total=$total"
    exit 0
}

if ($Offset -ge $total) { Fail "offset $Offset is beyond total $total" }
$len = [Math]::Min($MaxChars, $total - $Offset)
$slice = $textAll.Substring($Offset, $len)
$end = $Offset + $len
$next = if ($end -lt $total) { "$end" } else { "END" }

Write-Output "WEB_READ url=$Url"
Write-Output "chars $Offset-$end / $total next=$next"
Write-Output "-----"
Write-Output $slice
Write-Output "-----"

# links whose anchor text appears inside this range
if (Test-Path -LiteralPath $linksFile) {
    $shown = 0
    foreach ($ln in [IO.File]::ReadAllLines($linksFile, [Text.Encoding]::UTF8)) {
        $parts = $ln -split "`t", 3
        if ($parts.Count -eq 3 -and $parts[1].Length -ge 3 -and $slice.IndexOf($parts[1]) -ge 0) {
            Write-Output ("[{0}] {1} -> {2}" -f $parts[0], $parts[1], $parts[2])
            $shown++
            if ($shown -ge 30) { break }
        }
    }
    if ($shown -gt 0) { Write-Output "(follow one with: web-read.ps1 -Url <this page url> -Link <n>)" }
}
Write-Output "WEB_READ_OK next=$next total=$total cache=$textFile"
