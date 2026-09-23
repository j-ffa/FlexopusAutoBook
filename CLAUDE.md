# FlexopusAutoBook

## Overview
PowerShell script that automatically books a desk and parking spot via the Flexopus REST API. Runs daily on weekdays via Windows Task Scheduler.

## Key Files
- `FlexopusAutoBook.ps1` — Main script (booking logic, discovery mode, fallback support)
- `Discover.ps1` — Standalone discovery script for finding IDs
- `LeaveUI.ps1` / `LeaveUI.html` / `LeaveUI.cmd` — Browser calendar for editing `AnnualLeave` (see below)
- `config.json` — User config (gitignored, contains secrets)
- `config.example.json` — Template with placeholders (committed)
- `FlexopusAutoBook.log` — Run log next to the script (gitignored, never rotated)

## How It Works
- Loads all configuration from `config.json` (domain, token, IDs, times, fallbacks, ntfy settings)
- Books a desk N days ahead and parking M days ahead (configurable)
- Weekend targets move to Monday. On the weekday-only schedule, `DaysAhead` values where N mod 7 isn't 0 or 1 leave some weekdays never booked (documented in the README)
- Skips if the user already has a booking that day: their bookings are filtered by `bookable.type` (0 = desk, 1 = parking)
- Checks availability before booking; tries fallbacks if primary is taken. Any booking on the bookable that day counts as taken (times aren't compared)
- Fallbacks only have `BookableId` / `LocationId` and are booked with the primary's `FromTime` / `ToTime`
- `Invoke-FlexopusApi` logs failures and returns `$null` instead of throwing, so an API error during the availability check reads as "unavailable" and the script moves on to fallbacks
- Sends one ntfy notification per run covering parking and desk; resources skipped for leave are left out. `Ntfy.Server` defaults to `https://ntfy.sh`; `Ntfy.Topic` has no default
- API: `https://{domain}.flexopus.com/api/v1`
- Auth: Bearer token from config

## Timezone Handling
- Config times (FromTime/ToTime) are **local times** in the configured timezone
- `Timezone` in config uses Windows timezone IDs (e.g. `GMT Standard Time`); falls back to system local if unset
- `New-Booking` converts local times to UTC before sending to the API, using the **target booking date's** DST offset (not today's)
- Nothing else converts: the availability and existing-booking checks query the **UTC** calendar day (`yyyy-MM-ddT00:00:00Z` to the next midnight UTC), not the local day. Fine for GMT/BST; may miss or misattribute bookings in zones far from UTC

## Annual Leave
- `AnnualLeave` in config accepts individual date strings (`"2026-04-10"`) and date ranges (`{ "From": "2026-12-22", "To": "2026-12-31" }`)
- Ranges are expanded to individual dates at config load time
- If a target booking date falls on annual leave, that resource is skipped (no booking, no notification)
- If both desk and parking dates are on leave, the script exits early
- Annual leave does NOT advance the target date — it simply skips (avoids double-bookings from subsequent runs)
- Weekend skipping happens in `Get-NextTargetDate`; annual leave is checked separately after date calculation

## Leave Calendar (LeaveUI)
- `LeaveUI.ps1` runs a `System.Net.HttpListener` on `http://localhost:8765/` (tries the next 9 ports if taken) and serves `LeaveUI.html`; `localhost` prefixes work without admin
- API: `GET /` (the page), `GET /api/leave` (`leave`, `version`, `today`, `bookedUntil { desk, parking }`, `configPath`), `PUT /api/leave` (`{ leave: [{from,to}], version }`), `POST /api/close`. Never return `ApiToken` or the ntfy topic — this is a public repo
- Saving edits the config **text**: it finds the top-level `AnnualLeave` array and replaces just that span, so the rest of the file keeps its formatting, BOM and line endings. If `AnnualLeave` is missing it's added as the last top-level key. Non-UTF-8 configs are refused
- It then re-parses and checks no other setting changed, writes `<config>.saving.json`, and swaps it in with `[IO.File]::Replace`, keeping `<config>.backup.json` (both named after the config file). If `Replace` fails it falls back to copying the config to the backup and then overwriting it
- Ranges are sorted and merged (overlapping/adjacent) on both client and server; single days are written as strings, longer leave as one-line `{ "From", "To" }` objects
- `version` is the canonical leave list; a mismatch on PUT returns 409 so an outside edit to `config.json` isn't overwritten
- PUT/POST with a different `Origin` get 403; requests with no `Origin` header pass, which is how `Invoke-WebRequest` tests get through. A PUT that isn't `application/json` gets 415
- No change to `FlexopusAutoBook.ps1` or the scheduled task is needed: the script reads `config.json` fresh every run
- `-ConfigPath` points the server at a different config — use a copy of `config.example.json` named `config.<name>.json` (e.g. `config.test.json`) so it and its backup match the `config*.json` gitignore rule; never the live config
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
- They're separate implementations that have drifted: `-Discover` (`Invoke-Discovery`) also prints building address, location code, bookable status and tags. Change both when changing discovery output

## Manual Booking for a Specific Date
Run `.\FlexopusAutoBook.ps1 -Date "yyyy-MM-dd"` to book for a specific date. It sets both the desk and parking target to that date, doesn't skip weekends, and still skips annual leave.

## Keep in Sync
- `Get-BookedUntil` (`LeaveUI.ps1`) mirrors `Get-NextTargetDate` (`FlexopusAutoBook.ps1`)
- `normalise()` (`LeaveUI.html`) mirrors `Get-MergedRanges` (`LeaveUI.ps1`)
- `Invoke-Discovery` (`FlexopusAutoBook.ps1`) and `Discover.ps1`

## Important
- `config.json` is gitignored — never commit it
- `config.example.json` is the shareable template
- `FlexopusAutoBook.ps1` has no `-ConfigPath` or dry run: any run reads the live `config.json` and makes real bookings. To check a change, parse it (`[System.Management.Automation.Language.Parser]::ParseFile`) or run the changed code in isolation
