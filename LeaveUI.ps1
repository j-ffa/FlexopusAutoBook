#Requires -Version 5.1
<#
.SYNOPSIS
    Opens a calendar in your browser for managing annual leave.

.DESCRIPTION
    Starts a small web server that only this PC can reach (localhost) and opens
    LeaveUI.html in your default browser. Leave saved there is written to the
    AnnualLeave list in config.json, which FlexopusAutoBook.ps1 reads on every
    run, so changes apply from the next scheduled run.

    Only the AnnualLeave section of config.json is rewritten; everything else in
    the file, including its formatting, is left as it is. The previous version is
    kept as config.backup.json.

    Stop the server with the Close button on the page, or Ctrl+C here.

.EXAMPLE
    .\LeaveUI.ps1

.EXAMPLE
    # Use a different port and don't open a browser
    .\LeaveUI.ps1 -Port 9000 -NoBrowser
#>

[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$ConfigPath,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }
$ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
$HtmlPath   = Join-Path $PSScriptRoot "LeaveUI.html"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "ERROR: config not found: $ConfigPath" -ForegroundColor Red
    Write-Host "Copy config.example.json to config.json and fill in your values." -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path -LiteralPath $HtmlPath)) {
    Write-Host "ERROR: LeaveUI.html not found in $PSScriptRoot" -ForegroundColor Red
    exit 1
}

# Backup and temp files sit next to the config and match the config*.json gitignore rule
$configDir  = Split-Path -Parent $ConfigPath
$configName = [IO.Path]::GetFileNameWithoutExtension($ConfigPath)
$BackupPath = Join-Path $configDir "$configName.backup.json"
$TempPath   = Join-Path $configDir "$configName.saving.json"

$Invariant = [Globalization.CultureInfo]::InvariantCulture
$LeaveKey  = "AnnualLeave"

# ============================================================================
# LEAVE PARSING
# ============================================================================

function ConvertTo-LeaveDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq "") { throw "A leave entry is missing its From or To date." }
    if ($Value -is [datetime]) { return $Value.Date }
    $parsed = [datetime]::MinValue
    if ($Value -is [string] -and $Value -match '^\d{4}-\d{2}-\d{2}$' -and
        [datetime]::TryParseExact($Value, "yyyy-MM-dd", $Invariant, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    throw "'$Value' is not a valid date. Dates must be written as yyyy-MM-dd."
}

# Turns AnnualLeave entries ("yyyy-MM-dd" strings and { From, To } objects) into a
# sorted list of { From, To } ranges, merging any that overlap or run into each other
function Get-MergedRanges {
    param([object[]]$Entries)

    $ranges = foreach ($entry in $Entries) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string] -or $entry -is [datetime]) {
            $day = ConvertTo-LeaveDate $entry
            [pscustomobject]@{ From = $day; To = $day }
        }
        else {
            $from = ConvertTo-LeaveDate $entry.From
            $to   = ConvertTo-LeaveDate $entry.To
            if ($to -lt $from) {
                throw "The leave from $($entry.From) to $($entry.To) ends before it starts."
            }
            [pscustomobject]@{ From = $from; To = $to }
        }
    }

    $merged = New-Object System.Collections.Generic.List[object]
    foreach ($range in @($ranges | Where-Object { $null -ne $_ } | Sort-Object From)) {
        $last = if ($merged.Count -gt 0) { $merged[$merged.Count - 1] } else { $null }
        if ($last -and $range.From -le $last.To.AddDays(1)) {
            if ($range.To -gt $last.To) { $last.To = $range.To }
        }
        else {
            $merged.Add([pscustomobject]@{ From = $range.From; To = $range.To })
        }
    }
    return , $merged.ToArray()
}

# A string that changes whenever the saved leave changes; lets the page detect
# config.json being edited by something else while it was open
function Get-LeaveVersion {
    param([object[]]$Ranges)
    return (@($Ranges | ForEach-Object {
        $_.From.ToString("yyyy-MM-dd", $Invariant) + "/" + $_.To.ToString("yyyy-MM-dd", $Invariant)
    }) -join ";")
}

# ============================================================================
# CONFIG FILE
# ============================================================================

function Read-Config {
    $bytes  = [IO.File]::ReadAllBytes($ConfigPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }

    # Refuse non-UTF-8 files rather than silently mangling their characters on save
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch {
        throw "config.json isn't saved as UTF-8. Re-save it as UTF-8 and try again."
    }

    try {
        $json = $text | ConvertFrom-Json
    }
    catch {
        throw "config.json isn't valid JSON: $($_.Exception.Message)"
    }

    $entries = @()
    if ($json.PSObject.Properties[$LeaveKey]) { $entries = @($json.$LeaveKey) }

    return @{
        Text   = $text
        Json   = $json
        HasBom = $hasBom
        Ranges = Get-MergedRanges $entries
    }
}

# Index just past the closing quote of the JSON string that opens at $Start
function Skip-JsonString {
    param([string]$Text, [int]$Start)
    $i = $Start + 1
    while ($i -lt $Text.Length) {
        if ($Text[$i] -eq '\') { $i += 2; continue }
        if ($Text[$i] -eq '"') { return $i + 1 }
        $i++
    }
    throw "config.json has an unterminated string."
}

# Finds the [ ... ] value of a top-level key; returns the positions of its brackets, or $null
function Find-TopLevelArray {
    param([string]$Text, [string]$Key)

    $depth = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($c -eq '"') {
            $end = Skip-JsonString $Text $i
            if ($depth -eq 1 -and $Text.Substring($i + 1, $end - $i - 2) -eq $Key) {
                $match = [regex]::new('\G\s*:\s*(\[)?').Match($Text, $end)
                if ($match.Success) {
                    if (-not $match.Groups[1].Success) {
                        throw "$Key in config.json isn't a list. Fix it by hand, then try again."
                    }
                    $open = $match.Groups[1].Index
                    $nested = 0
                    $j = $open
                    while ($j -lt $Text.Length) {
                        $d = $Text[$j]
                        if ($d -eq '"') { $j = Skip-JsonString $Text $j; continue }
                        if ($d -eq '[' -or $d -eq '{') { $nested++ }
                        elseif ($d -eq ']' -or $d -eq '}') {
                            $nested--
                            if ($nested -eq 0) { return @{ Open = $open; Close = $j } }
                        }
                        $j++
                    }
                    throw "config.json has an unclosed bracket."
                }
            }
            $i = $end
            continue
        }
        if ($c -eq '{' -or $c -eq '[') { $depth++ }
        elseif ($c -eq '}' -or $c -eq ']') { $depth-- }
        $i++
    }
    return $null
}

# Written in the same style as config.example.json: single days as strings,
# multi-day leave as one-line { "From", "To" } objects
function Format-LeaveArray {
    param([object[]]$Ranges, [string]$Indent, [string]$IndentUnit, [string]$Newline)

    if ($Ranges.Count -eq 0) { return "[]" }
    $items = foreach ($range in $Ranges) {
        $from = $range.From.ToString("yyyy-MM-dd", $Invariant)
        $to   = $range.To.ToString("yyyy-MM-dd", $Invariant)
        if ($from -eq $to) { "$Indent$IndentUnit`"$from`"" }
        else { "$Indent$IndentUnit{ `"From`": `"$from`", `"To`": `"$to`" }" }
    }
    return "[" + $Newline + ($items -join ",$Newline") + $Newline + $Indent + "]"
}

# Replaces only the AnnualLeave array in the config text, leaving everything else untouched
function Set-LeaveInText {
    param([string]$Text, [object[]]$Ranges)

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $unitMatch = [regex]::Match($Text, '(?m)^([ \t]+)"')
    $unit = if ($unitMatch.Success) { $unitMatch.Groups[1].Value } else { "    " }

    $span = Find-TopLevelArray $Text $LeaveKey
    if ($span) {
        $lineStart = $Text.LastIndexOf([char]"`n", $span.Open) + 1
        $indent = [regex]::Match($Text.Substring($lineStart), '^[ \t]*').Value
        $array = Format-LeaveArray $Ranges $indent $unit $newline
        return $Text.Substring(0, $span.Open) + $array + $Text.Substring($span.Close + 1)
    }

    # No AnnualLeave yet: add it as the last top-level setting
    $closeBrace = $Text.LastIndexOf([char]'}')
    $before = $Text.Substring(0, $closeBrace).TrimEnd()
    $comma = if ($before.EndsWith("{")) { "" } else { "," }
    $array = Format-LeaveArray $Ranges $unit $unit $newline
    return $before + $comma + $newline + $unit + "`"$LeaveKey`": " + $array + $newline + $Text.Substring($closeBrace)
}

function Save-LeaveToConfig {
    param($Config, [object[]]$Ranges)

    $newText = Set-LeaveInText $Config.Text $Ranges

    # Check the edited file loads the way FlexopusAutoBook.ps1 reads it, and that
    # nothing but AnnualLeave changed, before touching the real file
    $newJson = $newText | ConvertFrom-Json
    foreach ($prop in $Config.Json.PSObject.Properties) {
        if ($prop.Name -eq $LeaveKey) { continue }
        $before = ConvertTo-Json -InputObject $prop.Value -Depth 10 -Compress
        $after  = ConvertTo-Json -InputObject $newJson.($prop.Name) -Depth 10 -Compress
        if ($before -cne $after) {
            throw "Saving would have changed '$($prop.Name)' in config.json, so nothing was saved."
        }
    }
    $written = Get-MergedRanges @($newJson.$LeaveKey)
    if ((Get-LeaveVersion $written) -ne (Get-LeaveVersion $Ranges)) {
        throw "The leave written to config.json didn't read back correctly, so nothing was saved."
    }

    $encoding = New-Object System.Text.UTF8Encoding($Config.HasBom)
    [IO.File]::WriteAllText($TempPath, $newText, $encoding)
    try {
        # Swaps the files in one step and keeps the previous version as the backup
        [IO.File]::Replace($TempPath, $ConfigPath, $BackupPath)
    }
    catch {
        # Some drives don't support Replace; fall back to backup-then-overwrite
        Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath -Force
        [IO.File]::WriteAllText($ConfigPath, $newText, $encoding)
        Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
    }
}

# Mirrors Get-NextTargetDate in FlexopusAutoBook.ps1: the furthest date that
# today's scheduled run will already have booked
function Get-BookedUntil {
    param($DaysAhead)
    $target = (Get-Date).Date.AddDays([int]$DaysAhead)
    while ($target.DayOfWeek -eq "Saturday" -or $target.DayOfWeek -eq "Sunday") {
        $target = $target.AddDays(1)
    }
    return $target.ToString("yyyy-MM-dd", $Invariant)
}

function Get-LeaveState {
    param($Config)
    return [ordered]@{
        leave       = @($Config.Ranges | ForEach-Object {
            [ordered]@{
                from = $_.From.ToString("yyyy-MM-dd", $Invariant)
                to   = $_.To.ToString("yyyy-MM-dd", $Invariant)
            }
        })
        version     = Get-LeaveVersion $Config.Ranges
        today       = (Get-Date).ToString("yyyy-MM-dd", $Invariant)
        bookedUntil = [ordered]@{
            desk    = Get-BookedUntil $Config.Json.DeskDaysAhead
            parking = Get-BookedUntil $Config.Json.ParkingDaysAhead
        }
        configPath  = $ConfigPath
    }
}

# ============================================================================
# HTTP
# ============================================================================

function Send-Text {
    param($Context, [int]$Status, [string]$Body, [string]$ContentType)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $response = $Context.Response
    $response.StatusCode = $Status
    $response.ContentType = $ContentType
    $response.ContentLength64 = $bytes.Length
    $response.Headers["Cache-Control"] = "no-store"
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Send-Json {
    param($Context, [int]$Status, $Object)
    Send-Text $Context $Status (ConvertTo-Json -InputObject $Object -Depth 6 -Compress) "application/json; charset=utf-8"
}

function Invoke-Request {
    param($Context)

    $request = $Context.Request
    $method  = $request.HttpMethod
    $path    = $request.Url.AbsolutePath

    # Only the page this script serves may change anything, not other sites open in the browser
    $requestOrigin = $request.Headers["Origin"]
    if ($method -ne "GET" -and $requestOrigin -and $requestOrigin -ne $script:Origin) {
        Send-Json $Context 403 @{ error = "Changes can only be made from the leave page itself." }
        return
    }

    switch ("$method $path") {
        "GET /" {
            Send-Text $Context 200 ([IO.File]::ReadAllText($HtmlPath)) "text/html; charset=utf-8"
        }
        "GET /api/leave" {
            try { $config = Read-Config }
            catch { Send-Json $Context 500 @{ error = $_.Exception.Message }; return }
            Send-Json $Context 200 (Get-LeaveState $config)
        }
        "PUT /api/leave" {
            if ($request.ContentType -notlike "application/json*") {
                Send-Json $Context 415 @{ error = "Send the leave as JSON." }
                return
            }
            $reader = New-Object IO.StreamReader($request.InputStream, [Text.Encoding]::UTF8)
            $raw = $reader.ReadToEnd()
            $reader.Close()

            try { $body = $raw | ConvertFrom-Json }
            catch { Send-Json $Context 400 @{ error = "The request wasn't valid JSON." }; return }
            if ($null -eq $body -or -not $body.PSObject.Properties["leave"]) {
                Send-Json $Context 400 @{ error = "The request didn't include any leave." }
                return
            }

            try { $config = Read-Config }
            catch { Send-Json $Context 500 @{ error = $_.Exception.Message }; return }

            if ((Get-LeaveVersion $config.Ranges) -ne [string]$body.version) {
                Send-Json $Context 409 @{ error = "config.json was changed by something else while this page was open." }
                return
            }

            try { $ranges = Get-MergedRanges @($body.leave) }
            catch { Send-Json $Context 400 @{ error = $_.Exception.Message }; return }

            try { Save-LeaveToConfig $config $ranges }
            catch { Send-Json $Context 500 @{ error = $_.Exception.Message }; return }

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Saved $($ranges.Count) leave period(s) to $ConfigPath" -ForegroundColor Green
            Send-Json $Context 200 (Get-LeaveState (Read-Config))
        }
        "POST /api/close" {
            Send-Json $Context 200 @{ ok = $true }
            $script:Running = $false
        }
        default {
            Send-Json $Context 404 @{ error = "Not found." }
        }
    }
}

# ============================================================================
# MAIN
# ============================================================================

# Try the requested port, then the next few in case it's taken
$listener = $null
foreach ($candidate in $Port..($Port + 9)) {
    $attempt = New-Object System.Net.HttpListener
    $attempt.Prefixes.Add("http://localhost:$candidate/")
    try {
        $attempt.Start()
        $listener = $attempt
        $Port = $candidate
        break
    }
    catch {
        $attempt.Close()
    }
}
if (-not $listener) {
    Write-Host "ERROR: Couldn't start the leave page on ports $Port-$($Port + 9). Try -Port with a different number." -ForegroundColor Red
    exit 1
}

$script:Origin  = "http://localhost:$Port"
$script:Running = $true

Write-Host ""
Write-Host "Leave page running at $($script:Origin)/" -ForegroundColor Cyan
Write-Host "Saving to $ConfigPath"
Write-Host "Click Close on the page, or press Ctrl+C here, to stop it."
Write-Host ""

if (-not $NoBrowser) { Start-Process "$($script:Origin)/" }

try {
    while ($script:Running) {
        # Poll instead of blocking so Ctrl+C can stop the loop
        $pending = $listener.GetContextAsync()
        while (-not $pending.AsyncWaitHandle.WaitOne(500)) { }
        $context = $pending.GetAwaiter().GetResult()
        try {
            Invoke-Request $context
        }
        catch {
            Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Red
            try { Send-Json $context 500 @{ error = $_.Exception.Message } } catch { }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "Leave page stopped."
}
