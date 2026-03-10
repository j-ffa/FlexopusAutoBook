#Requires -Version 5.1
<#
.SYNOPSIS
    Discovers Flexopus IDs needed to configure FlexopusAutoBook.ps1.
.DESCRIPTION
    Makes read-only GET requests to list your user info, buildings,
    locations, and bookable resources (desks, parking, etc.).
.EXAMPLE
    .\Discover.ps1
#>

$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.json not found in $PSScriptRoot" -ForegroundColor Red
    Write-Host "Copy config.example.json to config.json and fill in Domain, ApiToken, and UserEmail." -ForegroundColor Yellow
    exit 1
}
$json = Get-Content -Path $configPath -Raw | ConvertFrom-Json

$Domain   = $json.Domain
$ApiToken = $json.ApiToken
$Email    = $json.UserEmail

$BaseUrl  = "https://$Domain.flexopus.com/api/v1"
$Headers  = @{
    "Authorization" = "Bearer $ApiToken"
    "Accept"        = "application/json"
}

function Get-Api {
    param([string]$Endpoint)
    try {
        return Invoke-RestMethod -Uri "$BaseUrl$Endpoint" -Headers $Headers -Method GET -ErrorAction Stop
    }
    catch {
        Write-Host "  FAILED: $Endpoint - $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# --- User lookup ---
Write-Host "`n=== YOUR USER INFO ===" -ForegroundColor Yellow
$user = Get-Api -Endpoint "/users/by-email/$Email"
if ($user) {
    Write-Host "  User ID : $($user.data.id)" -ForegroundColor Green
    Write-Host "  Name    : $($user.data.name)"
    Write-Host "  Email   : $($user.data.email)"
}

# --- Buildings & locations ---
Write-Host "`n=== BUILDINGS AND LOCATIONS ===" -ForegroundColor Yellow
$buildings = Get-Api -Endpoint "/buildings"
if (-not $buildings) { return }

foreach ($building in $buildings.data) {
    Write-Host "`n  Building: $($building.name) (ID: $($building.id))" -ForegroundColor Cyan

    foreach ($location in $building.locations) {
        Write-Host "    Location: $($location.name) (ID: $($location.id))"

        $bookables = Get-Api -Endpoint "/locations/$($location.id)/bookables"
        if (-not $bookables -or $bookables.data.Count -eq 0) { continue }

        foreach ($bookable in $bookables.data) {
            switch ($bookable.type) {
                0 { $type = "Desk" }
                1 { $type = "Parking" }
                2 { $type = "Meeting Room" }
                3 { $type = "Home Office" }
                default { $type = "Unknown" }
            }
            Write-Host "      $type - $($bookable.name) (BookableId: $($bookable.id))" -ForegroundColor Gray
        }
    }
}

Write-Host "`n=== DONE ===" -ForegroundColor Yellow
Write-Host "Copy the IDs above into config.json`n"
