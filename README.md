# FlexopusAutoBook

PowerShell script that automatically books a desk and parking spot via the Flexopus REST API. Designed to run each weekday via Windows Task Scheduler.

## Requirements

- Windows with PowerShell 5.1 or later
- A Flexopus API token (Dashboard > Settings > Integrations > Flexopus API)
- Permission to run scripts. If PowerShell refuses to run them, allow local scripts for your account (and unblock the files if you downloaded a ZIP):

  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  Get-ChildItem *.ps1 | Unblock-File
  ```

## Quick Start

1. **Create your config**, then fill in `Domain`, `ApiToken` and `UserEmail`:

   ```powershell
   Copy-Item config.example.json config.json
   ```

2. **Find your IDs.** This lists your user ID and every building, location and bookable resource with its ID:

   ```powershell
   .\Discover.ps1
   ```

   `.\FlexopusAutoBook.ps1 -Discover` does the same and also shows each resource's status and tags. Copy your `UserId` and the desk and parking IDs you want into `config.json` (see [Config Reference](#config-reference)).

3. **Run it once.** This makes a **real booking** for the next target dates:

   ```powershell
   .\FlexopusAutoBook.ps1
   ```

   Add `-Date "yyyy-MM-dd"` to book both desk and parking for that date instead. Weekends aren't skipped, but annual leave is.

4. **Schedule it (optional).** In PowerShell as admin, this runs it just after midnight each weekday:

   ```powershell
   $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\FlexopusAutoBook\FlexopusAutoBook.ps1"'
   $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At 00:00:05
   $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -WakeToRun
   Register-ScheduledTask -TaskName 'FlexopusAutoBook' -Action $action -Trigger $trigger -Settings $settings -Description 'Auto-book desk and parking in Flexopus on weekdays'
   ```

## Config Reference

| Field | Description |
|-------|-------------|
| `Domain` | Your Flexopus tenant, e.g. `"yourcompany"` for yourcompany.flexopus.com |
| `ApiToken` | Your Flexopus API token |
| `UserEmail` | Your Flexopus login email, used to find your user ID during discovery |
| `UserId` | Your Flexopus user ID |
| `Timezone` | Windows timezone ID, e.g. `"GMT Standard Time"`. Defaults to the PC's timezone |
| `Desk`, `Parking` | Your preferred desk and parking spot: `BookableId`, `LocationId`, and `FromTime` / `ToTime` as `"HH:mm"` local time in `Timezone` |
| `DeskFallbacks`, `ParkingFallbacks` | Alternatives tried in order when the preferred one is taken: `{ BookableId, LocationId }` objects, booked for the same times |
| `DeskDaysAhead`, `ParkingDaysAhead` | How many days ahead to book (0 = today). Dates that land on a weekend move to Monday. With the weekday schedule above, use a multiple of 7 or one more (0, 1, 7, 8, 14, 15, …), or some weekdays never get booked. Your Flexopus admin settings set the maximum |
| `BookableNames` | Optional friendly names for notifications, keyed by bookable ID as a string, e.g. `"32": "Table 6"` |
| `AnnualLeave` | Dates not to book. See [Annual Leave](#annual-leave) |
| `Ntfy` | `Enabled`, `Topic` and `Server` (default `https://ntfy.sh`). See [Push Notifications](#push-notifications) |

## Annual Leave

Nothing is booked for dates in `AnnualLeave`; the booking is skipped, not moved to another day. List single dates and date ranges, or use `[]` for none:

```json
"AnnualLeave": [
    "2026-04-10",
    { "From": "2026-12-24", "To": "2026-12-31" }
]
```

### Leave calendar

To pick leave on a calendar instead, double-click `LeaveUI.cmd` or run `.\LeaveUI.ps1`. Click the first and last day of your leave, add it, then save. The booking script reads `config.json` on every run, so nothing else needs updating.

- The page is served only to this PC, at `http://localhost:8765` (use `-Port` to change it, or `-NoBrowser` to skip opening a browser). Click **Close** on the page or press Ctrl+C in its window to stop it.
- Saving rewrites only `AnnualLeave` in `config.json` and keeps the previous file as `config.backup.json`. It doesn't cancel bookings the script has already made; the calendar warns you when your leave falls on dates already booked, so you can cancel those in Flexopus.

## Push Notifications

Uses [ntfy.sh](https://ntfy.sh) for free push notifications, no account required.

1. Install the ntfy app ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) / [iOS](https://apps.apple.com/app/ntfy/id1625396347)).
2. Pick a unique, hard-to-guess topic name and subscribe to it in the app. Anyone who knows the name can read it.
3. In `config.json`, set `Ntfy.Enabled` to `true` and `Ntfy.Topic` to that name.

## Files

- `FlexopusAutoBook.ps1`: the booking script
- `Discover.ps1`: lists the IDs you need for `config.json`
- `LeaveUI.ps1`, `LeaveUI.html`, `LeaveUI.cmd`: the leave calendar's server, page and double-click launcher
- `config.example.json`: the config template

Your `config.json`, the leave calendar's `config.backup.json` and the script's `FlexopusAutoBook.log` stay on your PC: `config*.json` (except the template) and `*.log` are gitignored.
