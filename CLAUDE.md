# FlexopusAutoBook

## Overview
PowerShell script that automatically books a desk and parking spot via the Flexopus REST API. Runs daily on weekdays via Windows Task Scheduler.

## Key Files
- `FlexopusAutoBook.ps1` — Main script (booking logic, discovery mode, fallback support)
- `Discover.ps1` — Standalone discovery script for finding IDs
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
