# Apple Top Dating Apps - iOS Bundle IDs

A verified list of bundle IDs for Apple's top dating apps, plus PowerShell tools
that turn App Store links into a deployable Microsoft Intune profile.

Intune's "Blocked App Bundle IDs" setting takes bundle IDs, but everything you
actually have - a store link, an app name - is not one, and Apple publishes no
mapping. This repo closes that gap: a verified list, and tooling to build your
own for any category.

This project started with one concrete need: blocking dating apps on supervised
corporate iOS devices. The dating list is the worked example it left behind, but
none of the tooling cares what category you point it at - gambling, betting,
social media, anything the App Store sells. Swap in your own search terms or
store links and the same pipeline produces the same deployable profile.

## The list

25 apps, sourced from Apple's own curated App Store collections -
[The Best Dating Apps](https://apps.apple.com/us/story/id1654973266) (US) and
[Top dating apps](https://apps.apple.com/gb/story/id1549697084) (GB) -
deduplicated, with every bundle ID verified against the iTunes Lookup API on
2026-07-21.

| App | Bundle ID | App Store ID |
| --- | --- | --- |
| Badoo Dating: Meet New People | `com.badoo.Badoo` | 351331194 |
| BLK: Black Singles Dating App | `com.affinityapps.blk` | 1253586891 |
| Bumble Dating App: Meet & Date | `com.moxco.bumble` | 930441707 |
| Chispa: Dating App for Latinos | `com.affinityapps.chispa` | 1289684085 |
| Coffee Meets Bagel: Dating App | `io.cmbus.app` | 6502307144 |
| Dil Mil: South Asian Dating | `co.DilMile.DilMile` | 879383901 |
| eharmony: dating & real love | `com.eharmony.singles.SinglesRelease` | 458272450 |
| Feeld: Dating for the Curious | `com.3nder.threender` | 887914690 |
| Grindr - Gay Dating & Chat | `com.grindrguy.grindrx` | 319881193 |
| happn: dating app | `fr.ftw-and-co.whoozer` | 489185828 |
| HER:Lesbian&Queer LGBTQ Dating | `com.dattch.dattch` | 573328837 |
| Hiki: Autism ADHD & ND Dating | `com.hiki.ios` | 1466184914 |
| Hily Dating App: Meet. Date. | `com.hily.ios` | 1250946975 |
| Hinge Dating App: Match & Date | `co.hinge.mobile.ios` | 595287172 |
| Match Dating App : Chat & Meet | `com.match.match.com` | 305939712 |
| Muzz: Where Muslims Marry | `com.muzmatch.muzmatch` | 969997496 |
| OkCupid Dating: Date Singles | `com.okcupid.app` | 338701294 |
| Plenty of Fish : Dating App | `com.pof.mobileapp.iphone` | 389638243 |
| PURE: Open-Minded Dating App | `org.getpure.pure-iphone` | 690661663 |
| Shaadi.com Matrimony App | `com.shaadi.iphone` | 480093204 |
| Stir: Single Parent Dating App | `com.match.stir` | 1576261708 |
| Taimi: LGBTQ+ Dating & Meet Up | `com.taimi.ios` | 1282966364 |
| Thursday Events | `com.thursday.thursdayevents.identifier` | 6503631996 |
| Tinder Dating App: Date & Chat | `com.cardify.tinder` | 547702041 |
| Zoe: Lesbian Dating & Chat | `com.surgeapp.zoe` | 1269081011 |

Machine-readable: [`bundle-ids.csv`](bundle-ids.csv) - the same list, and the
file every tool here reads and writes.

Apple's curation is the scope on purpose: it is an externally-owned definition
of "top dating apps" rather than anyone's personal judgment. It skews toward
large, featured apps - if you need the whole category, extend the list with
`-Search` (below).

**Bundle IDs are not guessable.** Renames and acquisitions leave the immutable
bundle ID behind: happn is `fr.ftw-and-co.whoozer`, Feeld is
`com.3nder.threender`, Coffee Meets Bagel is `io.cmbus.app` (and
`com.coffeemeetsbagel`, which looks perfectly plausible, resolves to nothing).
Verify; never infer.

## Other categories

Two more lists, built with this repo's own `-Search` tooling, 25 apps each:

- [`bundle-ids-gambling.csv`](bundle-ids-gambling.csv) - real-money casino,
  sportsbook and fantasy apps (DraftKings, FanDuel, BetMGM, bet365, Stake, ...)
- [`bundle-ids-vpn.csv`](bundle-ids-vpn.csv) - VPN and proxy clients
  (NordVPN, ExpressVPN, Proton VPN, Surfshark, Psiphon, ...), commonly blocked
  to stop devices bypassing web filtering

Sourcing differs from the dating list and is worth being clear about: Apple
publishes no editorial collection for these categories, so these were built by
sweeping multiple App Store search terms and keeping the apps that surfaced
across the most queries - search-derived, not Apple-curated. Feed either
straight to the profile builder:

```powershell
.\New-IntuneBlockedAppProfile.ps1 -InputFile .\bundle-ids-vpn.csv -Name 'iOS - Blocked VPN Apps'
```

## The tools

Three scripts, separated by what they touch:

| Script | Touches | Purpose |
| --- | --- | --- |
| [`Get-AppStoreBundleId.ps1`](Get-AppStoreBundleId.ps1) | Apple's public API; your list CSV with -SaveTo | Search, resolve, drift-check, and save picks to a list |
| [`New-IntuneBlockedAppProfile.ps1`](New-IntuneBlockedAppProfile.ps1) | A local file | Turn links/IDs/lists into a deployable profile |
| [`Publish-IntuneBlockedAppProfile.ps1`](Publish-IntuneBlockedAppProfile.ps1) | Your Intune tenant | POST the profile, with safety checks |

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
.\New-IntuneBlockedAppProfile.ps1 -InputFile .\bundle-ids-gambling.csv `
    -Name 'iOS - Blocked Gambling Apps'
```

### Dump App Store links, get a profile

```powershell
.\New-IntuneBlockedAppProfile.ps1 -AppStoreUrl `
    'https://apps.apple.com/us/app/tinder-dating-app/id547702041',
    'https://apps.apple.com/us/app/bumble-dating-app/id930441707'
```

Accepts store URLs (any storefront), numeric App Store IDs, bundle IDs, or a
list CSV (`-InputFile .\bundle-ids.csv`). Inputs that fail to resolve are
reported and **excluded** - an unverified entry is a silent gap that still
looks like coverage in the portal.

Nothing here is dating-specific. One tip when searching: do not filter on
genre - the App Store assigns it inconsistently (Tinder is Lifestyle, Plenty
of Fish is Social Networking).

### Drift-check the list

```powershell
.\Get-AppStoreBundleId.ps1 -BundleId (Import-Csv .\bundle-ids.csv).BundleId |
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
(Import-Csv .\bundle-ids.csv).BundleId | Set-Content .\import.csv
```

### Graph POST

[`intune/iOS-Blocked-Applications.json`](intune/iOS-Blocked-Applications.json)
is the ready-to-POST body (setting definition
`com.apple.applicationaccess_blockedappbundleids`, category Restrictions). It
contains no tenant identifiers or assignments.

```powershell
.\Publish-IntuneBlockedAppProfile.ps1 -DryRun                                  # validate offline
.\Publish-IntuneBlockedAppProfile.ps1 -Name 'iOS - Blocked Applications (PILOT)'
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
.\New-IntuneBlockedAppProfile.ps1 -InputFile .\bundle-ids.csv -Format MobileConfig `
    -PayloadIdentifierPrefix 'com.yourorg.restrictions'
```

Tradeoff: the blocked apps are not visible or editable in the portal; changing
the list means regenerate and re-upload.

### Know the limits

- **Supervision is mandatory.** On unsupervised devices the profile reports as
  applied and silently does nothing. Assign with a supervised-device filter.
- **Blocking the app does not block the website.** `tinder.com` stays reachable
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


