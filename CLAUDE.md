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
