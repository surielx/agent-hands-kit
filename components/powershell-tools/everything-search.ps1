# everything-search.ps1 - Everything command line (es.exe) wrapper
# Usage: everything-search.ps1 <query / es options...>
#   All arguments are passed through to es.exe as-is (do not pass -instance;
#   this wrapper manages the instance selection itself).
#   Examples:
#     everything-search.ps1 desktop-agent.exe
#     everything-search.ps1 -path <work-root> ext:md
#     everything-search.ps1 -n 20 -sort-date-modified-desc *.log
# Final line: EVERYTHING_OK count=<result lines> / EVERYTHING_FAILED <reason>
# Exit code: 0 on success, es.exe exit code (non-zero) on failure.
#
# How the search is served (session mechanics, verified 2026-11-11):
# es.exe IPC reaches only an Everything instance running in the SAME logon
# context (window station) as this process - the same Windows session is NOT
# enough, because every scheduled-task / SSH logon gets its own window
# station. Also, only ONE instance of a given name can exist per session.
# This wrapper therefore works in stages:
#   1. Try the default instance (the desktop GUI instance answers here).
#   2. On IPC error 8, try the dedicated instance named FRIEND, which the
#      resident session chain (wake.ps1) starts inside its own context.
#   3. If FRIEND does not answer either, a stale FRIEND instance from an
#      earlier context is holding the name in this session: this wrapper
#      stops that instance (same session, FRIEND name only - the default /
#      desktop instance is never touched), starts FRIEND in its own
#      context, waits for the index, and retries.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$es = "$env:USERPROFILE\tools\everything\es.exe"
$ev = 'C:\Program Files\Everything\Everything.exe'
if (-not (Test-Path $es)) {
    Write-Output "EVERYTHING_FAILED es.exe not found: $es"
    exit 1
}
if ($args.Count -eq 0) {
    Write-Output 'EVERYTHING_FAILED no query given (pass a search string or es options)'
    exit 1
}

$out = & $es @args 2>&1
$code = $LASTEXITCODE

if ($code -eq 8 -and (Test-Path $ev)) {
    $namedArgs = @('-instance', 'FRIEND') + $args
    $out = & $es @namedArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 8) {
        Start-Sleep -Seconds 5
        $out = & $es @namedArgs 2>&1
        $code = $LASTEXITCODE
    }
    if ($code -eq 8) {
        # Clear the stale FRIEND instance resident in this session (it
        # belongs to another logon context and can never answer here),
        # then start FRIEND in this context and wait for it to answer.
        $mySess = (Get-Process -Id $PID).SessionId
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Everything.exe' -and $_.SessionId -eq $mySess -and $_.CommandLine -match '-instance\s+FRIEND' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
        Start-Process -FilePath $ev -ArgumentList '-instance','FRIEND','-startup' -WindowStyle Hidden
        for ($i = 0; $i -lt 36; $i++) {
            Start-Sleep -Seconds 5
            $out = & $es @namedArgs 2>&1
            $code = $LASTEXITCODE
            if ($code -ne 8) { break }
        }
    }
}

$lines = @($out | ForEach-Object { "$_" } | Where-Object { $_ -ne '' })
$totalLines = $lines.Count
$shownLines = $totalLines
if ($code -eq 0 -and -not ($args -contains '-n') -and $totalLines -gt 200) {
    $lines = $lines[0..199]
    $shownLines = 200
}
$lines | ForEach-Object { Write-Output $_ }
if ($shownLines -lt $totalLines) {
    Write-Output ("TRUNCATED shown $shownLines of $totalLines (add -n <count> to the query for more)")
}

if ($code -ne 0) {
    # Fallback (added 2026-11-13): for a plain filename-like query, fall back to a
    # ripgrep file listing over $env:AGENT_HOME instead of failing outright when the
    # Everything IPC is unreachable from this logon context.
    $rgExe = "$env:USERPROFILE\tools\bin\rg.exe"
    if ($code -eq 8 -and $args.Count -eq 1 -and $args[0] -match '^[\w\.\-\*]+$' -and (Test-Path $rgExe)) {
        $pat = $args[0].Replace('*', '')
        if ($pat.Length -ge 3) {
            $hits = @(& $rgExe --files "$env:AGENT_HOME" 2>$null | Where-Object { $_ -like "*$pat*" } | Select-Object -First 100)
            if ($hits.Count -gt 0) {
                $hits | ForEach-Object { Write-Output $_ }
                Write-Output ("EVERYTHING_OK count=" + $hits.Count + ' (rg fallback)')
                exit 0
            }
        }
    }
    if ($code -eq 8) {
        Write-Output 'EVERYTHING_FAILED Everything is not running in this logon context (IPC error 8)'
    } elseif ($lines.Count -gt 0) {
        Write-Output ("EVERYTHING_FAILED es exit " + $code + ': ' + $lines[0])
    } else {
        Write-Output ("EVERYTHING_FAILED es exit " + $code)
    }
    exit $code
}
if ($shownLines -lt $totalLines) { Write-Output ("EVERYTHING_OK count=" + $totalLines + " shown=" + $shownLines) }
else { Write-Output ("EVERYTHING_OK count=" + $totalLines) }
exit 0
