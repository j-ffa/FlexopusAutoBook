# FlexopusAutoBook

PowerShell script that automatically books a desk and parking spot via the Flexopus REST API. Designed to run daily on weekdays via Windows Task Scheduler.

## Quick Start

### 1. Create your config

```powershell
Copy-Item config.example.json config.json
```

Edit `config.json` and fill in at minimum:
- `Domain` — your Flexopus tenant (e.g. `"yourcompany"` for yourcompany.flexopus.com)
- `ApiToken` — from Dashboard > Settings > Integrations > Flexopus API
- `UserEmail` — your Flexopus login email

### 2. Discover your IDs

```powershell
.\Discover.ps1
```

This lists all buildings, locations, and bookable resources with their IDs. Copy the relevant IDs into `config.json`:
- `UserId` — your user ID
- `Desk.BookableId` / `Desk.LocationId` — your preferred desk
- `Parking.BookableId` / `Parking.LocationId` — your preferred parking spot
- `ParkingFallbacks` / `DeskFallbacks` — optional alternatives

### 3. Test a booking

```powershell
.\FlexopusAutoBook.ps1
```

Or book for a specific date:

```powershell
.\FlexopusAutoBook.ps1 -Date "2026-03-20"
```

### 4. Schedule it (optional)

Run in PowerShell as admin:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\FlexopusAutoBook\FlexopusAutoBook.ps1"'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At 00:00:05
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -WakeToRun
Register-ScheduledTask -TaskName 'FlexopusAutoBook' -Action $action -Trigger $trigger -Settings $settings -Description 'Auto-book desk and parking in Flexopus on weekdays'
```

## Config Reference

| Field | Description |
|-------|-------------|
| `Domain` | Flexopus tenant subdomain |
| `ApiToken` | Bearer token for the API |
| `UserId` | Your Flexopus user ID |
| `UserEmail` | Your email (used by Discover.ps1) |
| `Desk` | Primary desk: `BookableId`, `LocationId`, `FromTime`, `ToTime` |
| `Parking` | Primary parking: same fields as Desk |
| `BookableNames` | Map of bookable ID (as string) to friendly name, e.g. `"32": "Table 6"` |
| `DeskFallbacks` | Array of `{ BookableId, LocationId }` alternatives |
| `ParkingFallbacks` | Array of `{ BookableId, LocationId }` alternatives |
| `DeskDaysAhead` | Days ahead to book desk (default: 14) |
| `ParkingDaysAhead` | Days ahead to book parking (default: 7) |
| `Ntfy.Enabled` | `true` to send push notifications via ntfy.sh |
| `Ntfy.Topic` | Your ntfy.sh topic (pick something unique/random) |
| `Ntfy.Server` | ntfy server URL (default: `https://ntfy.sh`) |

## Push Notifications

Uses [ntfy.sh](https://ntfy.sh) for free push notifications — no account required.

1. Install the [ntfy Android app](https://play.google.com/store/apps/details?id=io.heckel.ntfy)
2. Set `Ntfy.Enabled` to `true` in `config.json`
3. Pick a unique topic string and subscribe to it in the app
4. Set `Ntfy.Topic` to that same string

## Files

| File | Committed | Purpose |
|------|-----------|---------|
| `FlexopusAutoBook.ps1` | Yes | Main booking script |
| `Discover.ps1` | Yes | ID discovery helper |
| `config.example.json` | Yes | Config template with placeholders |
| `config.json` | **No** | Your real config (gitignored) |
| `*.log` | **No** | Runtime logs (gitignored) |
