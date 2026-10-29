# iOS App Bundle IDs for Intune

[![verify-lists](https://github.com/gxvz-dev/iosappblock-intune/actions/workflows/verify-lists.yml/badge.svg)](https://github.com/gxvz-dev/iosappblock-intune/actions/workflows/verify-lists.yml)

Verified iOS bundle ID lists, plus PowerShell tools that turn App Store links
into a deployable Microsoft Intune profile.

Every list here is re-verified against the App Store by a monthly scheduled
check; entries that stop resolving are flagged in an issue, never silently
kept. Last verified: 2026-10-03.

Intune's "Blocked App Bundle IDs" setting takes bundle IDs, but everything you
actually have - a store link, an app name - is not one, and Apple publishes no
mapping. This repo closes that gap: verified lists, and tooling to build your
own for any category.

## The lists

| File | Apps | Contents | Source |
| --- | --- | --- | --- |
| [`bundle-ids-dating.csv`](bundle-ids-dating.csv) | 25 | Dating apps | Apple-curated |
| [`bundle-ids-gambling.csv`](bundle-ids-gambling.csv) | 25 | Real-money casino, sportsbook and fantasy apps (DraftKings, FanDuel, BetMGM, bet365, Stake, ...) | Search-derived |
| [`bundle-ids-vpn.csv`](bundle-ids-vpn.csv) | 25 | VPN and proxy clients (NordVPN, ExpressVPN, Proton VPN, Surfshark, Psiphon, ...), commonly blocked to stop devices bypassing web filtering | Search-derived |

Each CSV has `BundleId`, `TrackId` (App Store ID) and `Name` columns and is
the file every tool here reads and writes.

Sourcing differs by category:

- **Dating** comes from Apple's own curated App Store collections -
  [The Best Dating Apps](https://apps.apple.com/us/story/id1654973266) (US) and
  [Top dating apps](https://apps.apple.com/gb/story/id1549697084) (GB) -
  deduplicated, with every bundle ID verified against the iTunes Lookup API.
  Apple's curation is the scope on purpose: it is an externally-owned
  definition of "top apps" in the category rather than anyone's personal
  judgment. It skews toward large, featured apps; extend it with `-Search`
  (below) if you need the whole category.
- **Gambling and VPN** have no Apple editorial collection, so they were built
  with this repo's own `-Search` tooling by sweeping multiple App Store search
  terms and keeping the apps that surfaced across the most queries -
  search-derived, not Apple-curated.

Feed any list straight to the profile builder:

```powershell
.\New-IntuneAppProfile.ps1 -InputFile .\bundle-ids-vpn.csv -Name 'iOS - Blocked VPN Apps'
```

**Bundle IDs are not guessable.** Renames and acquisitions leave the immutable
bundle ID behind: Proton VPN is `ch.protonmail.vpn`, DraftKings Fantasy Sports
is `com.draftkings.dknativermg`.
Verify; never infer.

## The tools

Three scripts, separated by what they touch:

| Script | Touches | Purpose |
| --- | --- | --- |
| [`Get-AppStoreBundleId.ps1`](Get-AppStoreBundleId.ps1) | Apple's public API; your list CSV with -SaveTo | Search, resolve, drift-check, and save picks to a list |
| [`New-IntuneAppProfile.ps1`](New-IntuneAppProfile.ps1) | A local file | Turn links/IDs/lists into a deployable profile |
| [`Publish-IntuneAppProfile.ps1`](Publish-IntuneAppProfile.ps1) | Your Intune tenant | POST the profile, with safety checks |

Windows PowerShell 5.1+, no modules or auth needed except Graph for the final
publish step.

### Search, pick, save - no copy-pasting

The whole loop from "what's out there" to "in my list" is one command. `-Pick`
opens a grid (type in its filter box to narrow, Ctrl/Shift-click rows, OK);
`-SaveTo` stores your selections:

```powershell
.\Get-AppStoreBundleId.ps1 -Search 'gambling' -Limit 100 -Pick -SaveTo .\bundle-ids-gambling.csv
```

The CSV is the storage - the one file per category, and the one the tools read
and write. Saving merges: nothing already in the list is duplicated or
overwritten, so re-running with new search terms just grows the file, and only
verified entries (`Status OK`) are ever written. The list then feeds the
profile builder directly:

```powershell
.\New-IntuneAppProfile.ps1 -InputFile .\bundle-ids-gambling.csv `
    -Name 'iOS - Blocked Gambling Apps'
```

### Dump App Store links, get a profile

```powershell
.\New-IntuneAppProfile.ps1 -AppStoreUrl `
    'https://apps.apple.com/us/app/nordvpn-vpn-fast-secure/id905953485',
    'https://apps.apple.com/us/app/expressvpn-secure-fast-vpn/id886492891'
```

Accepts store URLs (any storefront), numeric App Store IDs, bundle IDs, or a
list CSV (`-InputFile .\bundle-ids-dating.csv`). Inputs that fail to resolve are
reported and **excluded** - an unverified entry is a silent gap that still
looks like coverage in the portal.

One tip when searching: do not filter on genre - the App Store assigns it
inconsistently, so apps you would group together often sit in different
genres.

### Beyond blocking: everything else a bundle ID can drive

`New-IntuneAppProfile.ps1` builds four policies from the same inputs:

| Policy | Command | Output |
| --- | --- | --- |
| Blocklist (default) | `-Mode Block` | Graph body or `.mobileconfig` |
| **Allowlist** | `-Mode Allow` | Graph body or `.mobileconfig` |
| Silence notifications | `-Payload NotificationSilence` | `.mobileconfig` |
| Single-app kiosk | `-Payload SingleAppLock` | `.mobileconfig` |

```powershell
# Only approved apps may run - feed it YOUR approved list, not a category list
.\New-IntuneAppProfile.ps1 -InputFile .\approved-apps.csv -Mode Allow

# Softer control: the apps still run, their notifications do not
.\New-IntuneAppProfile.ps1 -InputFile .\bundle-ids-dating.csv -Payload NotificationSilence

# Kiosk: lock supervised devices into exactly one app
.\New-IntuneAppProfile.ps1 -AppId 361309726 -Payload SingleAppLock
```

Two warnings that matter:

- **An allowlist is the sharper knife.** Once assigned, *only* the listed apps
  can run - everything else disappears, including most built-in apps. Apple
  treats `blockedAppBundleIDs` and `allowedAppBundleIDs` as mutually
  exclusive: deploy one or the other, never both. Pilot on a test device.
- All of these payloads require **supervised** devices, same as blocking.

`.mobileconfig` outputs upload under `Templates > Custom`; Graph bodies go
through `Publish-IntuneAppProfile.ps1`, which detects which kind it is
shipping and warns loudly on allowlists.

### Drift-check the list

```powershell
.\Get-AppStoreBundleId.ps1 -BundleId (Import-Csv .\bundle-ids-dating.csv).BundleId |
    Where-Object Status -ne 'OK'
```

Empty output means every entry still resolves. Apps get delisted and renamed;
run this before trusting any bundle ID list, this one included.

## Deploying

**Intune has no file import for a whole Settings Catalog profile** - but the
Blocked App Bundle IDs *setting* has one (see the CSV import path below). Three
real paths:

| Path | Effort | Result |
| --- | --- | --- |
| Portal CSV import | Create profile, upload CSV | Real Settings Catalog profile, editable in the UI |
| Graph POST | One command | Same result, fully scripted end to end |
| `.mobileconfig` upload | One file upload | Works immediately, but an opaque blob in the portal |

### Portal CSV import (no scripting)

The Settings Catalog collection editor has an **Import** button that takes a
CSV of values, so the list goes in as one upload instead of one paste per app:

```
Devices > iOS/iPadOS > Configuration > Create > New policy
  Profile type : Settings catalog
  + Add settings > search "Blocked App Bundle IDs"  (category: Restrictions)
  On the setting, choose Import and upload the CSV
```

The import wants bundle IDs only. If the portal rejects the three-column list
file, produce a bare single-column CSV from it first:

```powershell
(Import-Csv .\bundle-ids-dating.csv).BundleId | Set-Content .\import.csv
```

### Graph POST

[`intune/iOS-Blocked-Applications.json`](intune/iOS-Blocked-Applications.json)
is the ready-to-POST body (setting definition
`com.apple.applicationaccess_blockedappbundleids`, category Restrictions). It
contains no tenant identifiers or assignments.

```powershell
.\Publish-IntuneAppProfile.ps1 -DryRun                                  # validate offline
.\Publish-IntuneAppProfile.ps1 -Name 'iOS - Blocked Applications (PILOT)'
```

The script validates the payload before connecting, refuses duplicate profile
names, authenticates by device code, and creates the profile **unassigned** so
nothing reaches a device until you assign it. Pilot on one or two supervised
test devices before widening.

### .mobileconfig upload

[`intune/iOS-Blocked-Applications.mobileconfig`](intune/iOS-Blocked-Applications.mobileconfig)
uploads under `Devices > iOS/iPadOS > Configuration > Templates > Custom`
(Device channel). Regenerate it with your own identifier prefix first:

```powershell
.\New-IntuneAppProfile.ps1 -InputFile .\bundle-ids-dating.csv -Format MobileConfig `
    -PayloadIdentifierPrefix 'com.yourorg.restrictions'
```

Tradeoff: the blocked apps are not visible or editable in the portal; changing
the list means regenerate and re-upload.

### Know the limits

- **Supervision is mandatory.** On unsupervised devices the profile reports as
  applied and silently does nothing. Assign with a supervised-device filter.
- **Blocking the app does not block the website.** The app's website stays reachable
  in Safari. This is one layer, not the control.
- **Blocklist vs allowlist.** `blockedAppBundleIDs` and `allowedAppBundleIDs`
  are mutually exclusive; the allowlist is the stronger control.
- **JSON array shapes are load-bearing.** The nested `settings` collections must
  stay arrays even with one element; `ConvertTo-Json` collapses them and Graph
  rejects the POST. The scripts handle this - hand-edited JSON often does not.

## Notes

- Apple throttles the iTunes API at roughly 20 requests/minute per IP; the
  scripts pace at 350ms. Story URLs (`/story/id...`) are editorial pages and do
  not resolve through the lookup API.
- List reflects the US storefront and is a point-in-time snapshot, not a feed.
- App names are ASCII-normalized; store metadata contains smart quotes that
  break PowerShell 5.1 parsing.

## License

MIT. Bundle IDs are public facts about published apps; app names and trademarks
belong to their respective owners.



