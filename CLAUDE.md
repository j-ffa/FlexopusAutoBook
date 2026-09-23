# FlexopusAutoBook

## Overview
PowerShell script that automatically books a desk and parking spot via the Flexopus REST API. Runs daily on weekdays via Windows Task Scheduler.

## Key Files
- `FlexopusAutoBook.ps1` — Main script (booking logic, discovery mode, fallback support)
- `Discover.ps1` — Standalone discovery script for finding IDs
- `LeaveUI.ps1` / `LeaveUI.html` / `LeaveUI.cmd` — Browser calendar for editing `AnnualLeave` (see below)
- `config.json` — User config (gitignored, contains secrets)
- `config.example.json` — Template with placeholders (committed)

## How It Works
- Loads all configuration from `config.json` (domain, token, IDs, times, fallbacks, ntfy settings)
- Books a desk N days ahead and parking M days ahead (configurable)
- Skips weekends automatically; skips if a booking already exists for the target date
- Checks availability before booking; tries fallbacks if primary is taken
- API: `https://{domain}.flexopus.com/api/v1`
- Auth: Bearer token from config

## Timezone Handling
- Config times (FromTime/ToTime) are **local times** in the configured timezone
- `Timezone` in config uses Windows timezone IDs (e.g. `GMT Standard Time`); falls back to system local if unset
- The script converts local times to UTC before sending to the API, using the **target booking date's** DST offset (not today's)

## Annual Leave
- `AnnualLeave` in config accepts individual date strings (`"2026-04-10"`) and date ranges (`{ "From": "2026-12-22", "To": "2026-12-31" }`)
- Ranges are expanded to individual dates at config load time
- If a target booking date falls on annual leave, that resource is skipped (no booking, no notification)
- If both desk and parking dates are on leave, the script exits early
- Annual leave does NOT advance the target date — it simply skips (avoids double-bookings from subsequent runs)
- Weekend skipping happens in `Get-NextTargetDate`; annual leave is checked separately after date calculation

## Leave Calendar (LeaveUI)
- `LeaveUI.ps1` runs a `System.Net.HttpListener` on `http://localhost:8765/` (tries the next 9 ports if taken) and serves `LeaveUI.html`; `localhost` prefixes work without admin
- API: `GET /api/leave`, `PUT /api/leave` (`{ leave: [{from,to}], version }`), `POST /api/close`. Never return `ApiToken` or the ntfy topic — this is a public repo
- Saving edits the config **text**: it finds the top-level `AnnualLeave` array and replaces just that span, so the rest of the file keeps its formatting, BOM and line endings. It then re-parses and checks no other setting changed before swapping the file in with `[IO.File]::Replace` (backup: `config.backup.json`)
- Ranges are sorted and merged (overlapping/adjacent) on both client and server; single days are written as strings, longer leave as one-line `{ "From", "To" }` objects
- `version` is the canonical leave list; a mismatch on PUT returns 409 so an outside edit to `config.json` isn't overwritten
- PUT/POST from another `Origin` get 403; PUT must be `application/json`
- No change to `FlexopusAutoBook.ps1` or the scheduled task is needed: the script reads `config.json` fresh every run
- `-ConfigPath` points the server at a different config — use a copy of `config.example.json` when testing, never the live config
- Testing from WSL: in NAT networking mode WSL can't reach the Windows-side listener, so drive it via `powershell.exe` (`Invoke-WebRequest http://localhost:PORT/...`)

## Config Loading
- JSON is read and mapped to a `$Config` hashtable at script start
- `BookableNames` keys are converted from strings (JSON limitation) to integers
- Empty fallback arrays are handled (ConvertFrom-Json may return `$null` for `[]`)
- `LogFile` is computed in-script via `$PSScriptRoot`, not stored in JSON

## Discovery Mode
- `.\FlexopusAutoBook.ps1 -Discover` or `.\Discover.ps1`
- Only requires `Domain`, `ApiToken`, and `UserEmail` in config
- Lists all buildings, locations, bookables, and user info

## Manual Booking for a Specific Date
Run `.\FlexopusAutoBook.ps1 -Date "yyyy-MM-dd"` to book for a specific date.

## Important
- `config.json` is gitignored — never commit it
- `config.example.json` is the shareable template
