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
.\FlexopusAutoBook.ps1 -Date "yyyy-MM-dd"
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
| `Timezone` | Windows timezone ID (e.g. `"GMT Standard Time"`); falls back to system local if omitted |
| `Desk` | Primary desk: `BookableId`, `LocationId`, `FromTime`, `ToTime` |
| `Parking` | Primary parking: same fields as Desk |
| `BookableNames` | Map of bookable ID (as string) to friendly name, e.g. `"32": "Table 6"` |
| `DeskFallbacks` | Array of `{ BookableId, LocationId }` alternatives |
| `ParkingFallbacks` | Array of `{ BookableId, LocationId }` alternatives |
| `DeskDaysAhead` | Days ahead to book desk (0 = today/next weekday; check your Flexopus admin settings for max) |
| `ParkingDaysAhead` | Days ahead to book parking (0 = today/next weekday; check your Flexopus admin settings for max) |
| `AnnualLeave` | Array of dates (`"2026-01-01"`) and/or ranges (`{ "From": "...", "To": "..." }`) to skip |
| `Ntfy.Enabled` | `true` to send push notifications via ntfy.sh |
| `Ntfy.Topic` | Your ntfy.sh topic (pick something unique/random) |
| `Ntfy.Server` | ntfy server URL (default: `https://ntfy.sh`) |

## Annual Leave

Add dates you won't be working to `AnnualLeave` in `config.json`. Bookings are skipped for those dates (not shifted to the next day).

Supports individual dates and date ranges:

```json
"AnnualLeave": [
    "2026-04-10",
    { "From": "2026-12-24", "To": "2026-12-31" }
]
```

Set to `[]` to disable.

### Leave calendar

Instead of editing `config.json` by hand, you can pick leave on a calendar in your browser. Double-click `LeaveUI.cmd`, or run:

```powershell
.\LeaveUI.ps1
```

Click the first and last day of your leave, add it, then save. The dates are written to `AnnualLeave` in `config.json`, which the booking script reads on every run, so there's nothing else to update. The scheduled task stays as it is.

- The page is served by a small web server that only this PC can reach (`http://localhost:8765`). It runs until you click **Close** on the page or press Ctrl+C in its window.
- Only the `AnnualLeave` section of `config.json` is rewritten; everything else, including formatting, stays as it is. The previous version is kept as `config.backup.json`.
- Adding leave doesn't cancel bookings the script has already made (it books `DeskDaysAhead` / `ParkingDaysAhead` days ahead). The calendar warns you when a selection falls in that window so you can cancel those in Flexopus.
- Use `-Port` to pick a different port, or `-NoBrowser` to start the server without opening a browser.

## Push Notifications

Uses [ntfy.sh](https://ntfy.sh) for free push notifications — no account required.

1. Install the ntfy app ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) / [iOS](https://apps.apple.com/app/ntfy/id1625396347))
2. Set `Ntfy.Enabled` to `true` in `config.json`
3. Pick a unique topic string and subscribe to it in the app
4. Set `Ntfy.Topic` to that same string

## Files

| File | Committed | Purpose |
|------|-----------|---------|
| `FlexopusAutoBook.ps1` | Yes | Main booking script |
| `Discover.ps1` | Yes | ID discovery helper |
| `LeaveUI.ps1` | Yes | Local web server for the leave calendar |
| `LeaveUI.html` | Yes | The leave calendar page |
| `LeaveUI.cmd` | Yes | Double-click launcher for `LeaveUI.ps1` |
| `config.example.json` | Yes | Config template with placeholders |
| `config.json` | **No** | Your real config (gitignored) |
| `config.backup.json` | **No** | Previous config, kept by the leave calendar when it saves (gitignored) |
| `*.log` | **No** | Runtime logs (gitignored) |
