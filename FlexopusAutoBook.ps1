#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-books a desk and parking spot in Flexopus via the REST API.

.DESCRIPTION
    Run in -Discover mode first to find your IDs, then fill in config.json
    and schedule with Task Scheduler to run just after midnight on weekdays.

.EXAMPLE
    # Discovery mode - lists buildings, locations, bookables, and your user info
    .\FlexopusAutoBook.ps1 -Discover

.EXAMPLE
    # Normal booking mode
    .\FlexopusAutoBook.ps1

.EXAMPLE
    # Book for a specific date instead of the next weekday
    .\FlexopusAutoBook.ps1 -Date "yyyy-MM-dd"
#>

[CmdletBinding()]
param(
    [switch]$Discover,
    [string]$Date
)

# ============================================================================
# CONFIGURATION - Loaded from config.json
# ============================================================================
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.json not found in $PSScriptRoot" -ForegroundColor Red
    Write-Host "Copy config.example.json to config.json and fill in your values." -ForegroundColor Yellow
    exit 1
}

$json = Get-Content -Path $configPath -Raw | ConvertFrom-Json

# Build BookableNames with integer keys (JSON only supports string keys)
$bookableNames = @{}
if ($json.BookableNames) {
    $json.BookableNames.PSObject.Properties | ForEach-Object {
        $bookableNames[[int]$_.Name] = $_.Value
    }
}

# Handle fallback arrays — ConvertFrom-Json may return $null for empty arrays
$deskFallbacks = @()
if ($json.DeskFallbacks) {
    $deskFallbacks = @($json.DeskFallbacks | ForEach-Object {
        @{ BookableId = [int]$_.BookableId; LocationId = [int]$_.LocationId }
    })
}
$parkingFallbacks = @()
if ($json.ParkingFallbacks) {
    $parkingFallbacks = @($json.ParkingFallbacks | ForEach-Object {
        @{ BookableId = [int]$_.BookableId; LocationId = [int]$_.LocationId }
    })
}

$Config = @{
    Domain           = $json.Domain
    ApiToken         = $json.ApiToken
    UserId           = [int]$json.UserId
    UserEmail        = $json.UserEmail
    Desk             = @{
        BookableId = [int]$json.Desk.BookableId
        LocationId = [int]$json.Desk.LocationId
        FromTime   = $json.Desk.FromTime
        ToTime     = $json.Desk.ToTime
    }
    Parking          = @{
        BookableId = [int]$json.Parking.BookableId
        LocationId = [int]$json.Parking.LocationId
        FromTime   = $json.Parking.FromTime
        ToTime     = $json.Parking.ToTime
    }
    BookableNames    = $bookableNames
    DeskFallbacks    = $deskFallbacks
    ParkingFallbacks = $parkingFallbacks
    DeskDaysAhead    = [int]$json.DeskDaysAhead
    ParkingDaysAhead = [int]$json.ParkingDaysAhead
    LogFile          = Join-Path $PSScriptRoot "FlexopusAutoBook.log"
    Ntfy             = @{
        Enabled = [bool]$json.Ntfy.Enabled
        Topic   = $json.Ntfy.Topic
        Server  = $json.Ntfy.Server
    }
}

# Ensure TLS 1.2 (PS 5.1 defaults to TLS 1.0 which most APIs reject)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry -ForegroundColor $(switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    })
    if ($Config.LogFile) {
        $entry | Out-File -Append -FilePath $Config.LogFile -Encoding UTF8
    }
}

function Send-NtfyNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Priority = "default",
        [string]$Tags = ""
    )
    if (-not $Config.Ntfy.Enabled) { return }
    try {
        $headers = @{
            Title    = $Title
            Priority = $Priority
            Tags     = $Tags
        }
        Invoke-RestMethod -Uri "$($Config.Ntfy.Server)/$($Config.Ntfy.Topic)" `
            -Method Post -Body $Message -Headers $headers -ErrorAction Stop
    }
    catch {
        Write-Log "ntfy notification failed: $($_.Exception.Message)" -Level "WARN"
    }
}

$BaseUrl = "https://$($Config.Domain).flexopus.com/api/v1"
$ApiHeaders = @{
    "Authorization" = "Bearer $($Config.ApiToken)"
    "Accept"        = "application/json"
}

function Invoke-FlexopusApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [hashtable]$Body,
        [hashtable]$Query
    )

    $uri = "$BaseUrl$Endpoint"

    $splat = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $ApiHeaders
        ErrorAction = "Stop"
    }

    # For GET requests, pass query params via -Body (PS appends them as query string)
    if ($Method -eq "GET" -and $Query) {
        $splat.Body = $Query
    }

    # For POST/PUT, send JSON body
    if ($Method -ne "GET" -and $Body) {
        $splat.Body        = ($Body | ConvertTo-Json -Depth 5)
        $splat.ContentType = "application/json"
    }

    Write-Verbose "Request: $Method $uri"

    try {
        $response = Invoke-RestMethod @splat
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody  = $_.ErrorDetails.Message
        if ($statusCode) {
            Write-Log "API call failed: $Method $Endpoint - HTTP $statusCode - $errorBody" -Level "ERROR"
        } else {
            Write-Log "API call failed: $Method $Endpoint - $($_.Exception.Message)" -Level "ERROR"
        }
        return $null
    }
}

function Get-NextTargetDate {
    param([int]$DaysAhead)

    if ($Date) {
        return [datetime]::ParseExact($Date, "yyyy-MM-dd", $null)
    }

    $target = (Get-Date).AddDays($DaysAhead).Date

    # Skip weekends
    while ($target.DayOfWeek -eq "Saturday" -or $target.DayOfWeek -eq "Sunday") {
        $target = $target.AddDays(1)
    }

    return $target
}

function Test-BookableAvailable {
    param(
        [int]$BookableId,
        [datetime]$TargetDate
    )

    $from = $TargetDate.ToString("yyyy-MM-ddT00:00:00Z")
    $to   = $TargetDate.AddDays(1).ToString("yyyy-MM-ddT00:00:00Z")

    $result = Invoke-FlexopusApi -Endpoint "/bookables/$BookableId/bookings" -Query @{
        from = $from
        to   = $to
    }

    if ($null -eq $result) { return $false }

    # If there are existing bookings for that day, the slot may be taken
    # Check if any booking overlaps with our desired time
    return ($result.data.Count -eq 0)
}

function New-Booking {
    param(
        [int]$BookableId,
        [int]$LocationId,
        [string]$FromTime,
        [string]$ToTime,
        [datetime]$TargetDate
    )

    $fromDateTime = "$($TargetDate.ToString('yyyy-MM-dd'))T${FromTime}:00.000000Z"

    $toDateTime = "$($TargetDate.ToString('yyyy-MM-dd'))T${ToTime}:00.000000Z"

    $body = @{
        bookable_id = $BookableId
        user_id     = $Config.UserId
        location_id = $LocationId
        from_time   = $fromDateTime
        to_time     = $toDateTime
    }

    return Invoke-FlexopusApi -Endpoint "/bookings" -Method "POST" -Body $body
}

function Invoke-BookWithFallback {
    param(
        [string]$ResourceType,
        [hashtable]$Primary,
        [array]$Fallbacks,
        [datetime]$TargetDate
    )

    # Try primary
    Write-Log "Checking availability of $ResourceType (Bookable ID: $($Primary.BookableId))..."
    $available = Test-BookableAvailable -BookableId $Primary.BookableId -TargetDate $TargetDate

    if ($available) {
        Write-Log "Primary $ResourceType is available, booking..."
        $result = New-Booking `
            -BookableId $Primary.BookableId `
            -LocationId $Primary.LocationId `
            -FromTime   $Primary.FromTime `
            -ToTime     $Primary.ToTime `
            -TargetDate $TargetDate

        if ($result) {
            Write-Log "$ResourceType booked successfully! Booking ID: $(if ($result.data.id) { $result.data.id } else { $result.data[0].id })" -Level "SUCCESS"
            return @{ Success = $true; BookableId = $Primary.BookableId; IsFallback = $false }
        }
    }
    else {
        Write-Log "Primary $ResourceType is not available." -Level "WARN"
    }

    # Try fallbacks
    foreach ($fallback in $Fallbacks) {
        Write-Log "Trying fallback $ResourceType (Bookable ID: $($fallback.BookableId))..."
        $available = Test-BookableAvailable -BookableId $fallback.BookableId -TargetDate $TargetDate

        if ($available) {
            Write-Log "Fallback $ResourceType available, booking..."
            $result = New-Booking `
                -BookableId $fallback.BookableId `
                -LocationId $fallback.LocationId `
                -FromTime   $Primary.FromTime `
                -ToTime     $Primary.ToTime `
                -TargetDate $TargetDate

            if ($result) {
                Write-Log "Fallback $ResourceType booked! Booking ID: $(if ($result.data.id) { $result.data.id } else { $result.data[0].id })" -Level "SUCCESS"
                return @{ Success = $true; BookableId = $fallback.BookableId; IsFallback = $true }
            }
        }
        else {
            Write-Log "Fallback $ResourceType (ID: $($fallback.BookableId)) also unavailable." -Level "WARN"
        }
    }

    Write-Log "Failed to book any $ResourceType." -Level "ERROR"
    return @{ Success = $false }
}

# ============================================================================
# DISCOVERY MODE
# ============================================================================

function Invoke-Discovery {
    Write-Host "`n=== FLEXOPUS DISCOVERY MODE ===" -ForegroundColor Cyan
    Write-Host "This will pull your tenant's structure so you can fill in the config.`n"

    # Look up user by email
    Write-Host "--- YOUR USER INFO ---" -ForegroundColor Yellow
    $user = Invoke-FlexopusApi -Endpoint "/users/by-email/$($Config.UserEmail)"
    if ($user) {
        Write-Host "  User ID:    $($user.data.id)" -ForegroundColor Green
        Write-Host "  Name:       $($user.data.name)"
        Write-Host "  Email:      $($user.data.email)"
    }
    else {
        Write-Host "  Could not find user by email. Check the UserEmail in config." -ForegroundColor Red
    }

    # List buildings and locations
    Write-Host "`n--- BUILDINGS & LOCATIONS ---" -ForegroundColor Yellow
    $buildings = Invoke-FlexopusApi -Endpoint "/buildings"
    if ($buildings) {
        foreach ($building in $buildings.data) {
            Write-Host "`n  Building: $($building.name) (ID: $($building.id))" -ForegroundColor Cyan
            if ($building.address) { Write-Host "  Address:  $($building.address)" }

            foreach ($location in $building.locations) {
                Write-Host "    Location: $($location.name) [Code: $($location.code)] (ID: $($location.id))"

                # List bookables for each location
                $bookables = Invoke-FlexopusApi -Endpoint "/locations/$($location.id)/bookables"
                if ($bookables -and $bookables.data.Count -gt 0) {
                    foreach ($bookable in $bookables.data) {
                        $typeLabel = switch ($bookable.type) {
                            0 { "Desk" }
                            1 { "Parking" }
                            2 { "Meeting Room" }
                            3 { "Home Office" }
                            default { "Unknown" }
                        }
                        $statusLabel = switch ($bookable.status) {
                            0 { "Flexible" }
                            1 { "Blocked" }
                            2 { "Assigned" }
                            default { "Unknown" }
                        }
                        $tags = $(if ($bookable.tags) { " [Tags: $($bookable.tags -join ', ')]" } else { "" })
                        Write-Host "      ${typeLabel}: $($bookable.name) (BookableId: $($bookable.id)) - Status: ${statusLabel}${tags}" -ForegroundColor Gray
                    }
                }
            }
        }
    }

    Write-Host "`n--- NEXT STEPS ---" -ForegroundColor Yellow
    Write-Host "1. Copy the relevant IDs from above into config.json."
    Write-Host "2. Set your UserId, Desk BookableId/LocationId, and Parking BookableId/LocationId."
    Write-Host "3. Optionally add fallback IDs."
    Write-Host "4. Run without -Discover to test a booking.`n"
}

# ============================================================================
# MAIN
# ============================================================================

if ($Discover) {
    Invoke-Discovery
    return
}

# Validate config
if ($Config.Domain -eq "yourcompany" -or $Config.ApiToken -eq "YOUR_API_TOKEN" -or $Config.UserId -eq 0) {
    Write-Log "Config not set up. Run with -Discover first to find your IDs, then update config.json." -Level "ERROR"
    exit 1
}

$deskDate    = Get-NextTargetDate -DaysAhead $Config.DeskDaysAhead
$parkingDate = Get-NextTargetDate -DaysAhead $Config.ParkingDaysAhead

Write-Log "=========================================="
Write-Log "Flexopus Auto-Book"
Write-Log "  Desk target:    $($deskDate.ToString('yyyy-MM-dd')) ($($deskDate.DayOfWeek))"
Write-Log "  Parking target: $($parkingDate.ToString('yyyy-MM-dd')) ($($parkingDate.DayOfWeek))"
Write-Log "=========================================="

# --- Desk ---
Write-Log "Checking for existing desk bookings on $($deskDate.ToString('yyyy-MM-dd'))..."
$deskBookings = Invoke-FlexopusApi -Endpoint "/users/$($Config.UserId)/bookings" -Query @{
    from = $deskDate.ToString("yyyy-MM-ddT00:00:00Z")
    to   = $deskDate.AddDays(1).ToString("yyyy-MM-ddT00:00:00Z")
}

$hasDesk = $false
if ($deskBookings -and $deskBookings.data.Count -gt 0) {
    foreach ($booking in $deskBookings.data) {
        if ($booking.bookable.type -eq 0) {
            Write-Log "Already have a desk booking for this date (ID: $($booking.id), Desk: $($booking.bookable.name)). Skipping desk." -Level "WARN"
            $hasDesk = $true
        }
    }
}

if (-not $hasDesk) {
    $deskResult = Invoke-BookWithFallback `
        -ResourceType "Desk" `
        -Primary $Config.Desk `
        -Fallbacks $Config.DeskFallbacks `
        -TargetDate $deskDate
}

# --- Parking ---
Write-Log "Checking for existing parking bookings on $($parkingDate.ToString('yyyy-MM-dd'))..."
$parkingBookings = Invoke-FlexopusApi -Endpoint "/users/$($Config.UserId)/bookings" -Query @{
    from = $parkingDate.ToString("yyyy-MM-ddT00:00:00Z")
    to   = $parkingDate.AddDays(1).ToString("yyyy-MM-ddT00:00:00Z")
}

$hasParking = $false
if ($parkingBookings -and $parkingBookings.data.Count -gt 0) {
    foreach ($booking in $parkingBookings.data) {
        if ($booking.bookable.type -eq 1) {
            Write-Log "Already have a parking booking for this date (ID: $($booking.id), Spot: $($booking.bookable.name)). Skipping parking." -Level "WARN"
            $hasParking = $true
        }
    }
}

if (-not $hasParking) {
    $parkingResult = Invoke-BookWithFallback `
        -ResourceType "Parking" `
        -Primary $Config.Parking `
        -Fallbacks $Config.ParkingFallbacks `
        -TargetDate $parkingDate
}

# --- Send ntfy notification ---
$dateLabel = $parkingDate.ToString("ddd dd MMM")

# Build parking part of the notification
if ($hasParking) {
    $ntfyTitle = "Already booked"
    $parkingMsg = "Parking: already booked"
    $ntfyTags = "parking,white_check_mark"
}
elseif ($parkingResult -and $parkingResult.Success) {
    $spotName = $Config.BookableNames[[int]$parkingResult.BookableId]
    if (-not $spotName) { $spotName = "Spot $($parkingResult.BookableId)" }
    if ($parkingResult.IsFallback) {
        $primaryName = $Config.BookableNames[[int]$Config.Parking.BookableId]
        if (-not $primaryName) { $primaryName = "Spot $($Config.Parking.BookableId)" }
        $ntfyTitle = "$spotName (fallback)"
        $parkingMsg = "$primaryName was taken. Booked $spotName for $dateLabel."
    }
    else {
        $ntfyTitle = "$spotName"
        $parkingMsg = "Booked for $dateLabel."
    }
    $ntfyTags = "parking,white_check_mark"
}
else {
    $ntfyTitle = "Parking failed"
    $parkingMsg = "No spots available for $dateLabel."
    $ntfyTags = "parking,x"
}

# Build desk part
if ($hasDesk) {
    $deskMsg = "Desk: already booked"
}
elseif ($deskResult -and $deskResult.Success) {
    $deskName = $Config.BookableNames[[int]$deskResult.BookableId]
    if (-not $deskName) { $deskName = "Desk $($deskResult.BookableId)" }
    if ($deskResult.IsFallback) {
        $deskMsg = "Desk: $deskName (fallback)"
    }
    else {
        $deskMsg = "Desk: $deskName"
    }
}
else {
    $deskMsg = "Desk: failed"
}

# Combine into notification body
if ($hasParking -and $hasDesk) {
    $ntfyTitle = "Already booked"
    $ntfyBody = "Parking and desk already booked for $dateLabel"
}
else {
    $ntfyBody = "$parkingMsg $deskMsg"
}

Send-NtfyNotification -Title $ntfyTitle -Message $ntfyBody -Tags $ntfyTags

Write-Log "=========================================="
Write-Log "Auto-book complete."
Write-Log "=========================================="
