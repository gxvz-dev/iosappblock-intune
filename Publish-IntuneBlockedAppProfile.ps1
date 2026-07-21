<#
.SYNOPSIS
    Creates the blocked-apps Settings Catalog profile in Intune from the JSON
    body, deliberately UNASSIGNED so it affects no devices until you assign it.

.DESCRIPTION
    Intune has no portal import for Settings Catalog profiles, so the JSON has
    to be POSTed to Graph. This does that, with the checks worth having:

      - validates the JSON body locally before touching the tenant
      - warns if a profile with the same name already exists, so you do not
        silently end up with two competing policies
      - creates the profile with NO assignments, so nothing reaches a device
        until you deliberately assign it
      - prints the new policy ID and how to verify or remove it

    Run with -DryRun first. That validates everything and shows exactly what
    would be sent, without connecting or creating anything.

.PARAMETER JsonPath
    Path to the Settings Catalog body. Defaults to the repo's prebuilt profile.

.PARAMETER DryRun
    Validate and print the request, then stop. No connection, no changes.

.PARAMETER Name
    Override the profile name from the JSON. Useful for pilots, e.g.
    'iOS - Blocked Applications (PILOT)'.

.PARAMETER Force
    Create even if a profile with the same name already exists.

.EXAMPLE
    .\Publish-IntuneBlockedAppProfile.ps1 -DryRun

    Validate the payload and see what would be sent. Always start here.

.EXAMPLE
    .\Publish-IntuneBlockedAppProfile.ps1 -Name 'iOS - Blocked Applications (PILOT)'

    Create an unassigned pilot profile. Assign it to a test group in the portal.

.NOTES
    Requires Microsoft.Graph.Authentication and the
    DeviceManagementConfiguration.ReadWrite.All scope.

    Uses device-code auth: browser pop-ups do not surface reliably over RDP or
    with a redirected profile.
#>
[CmdletBinding()]
param(
    [string]$JsonPath = '.\intune\iOS-Blocked-Applications.json',
    [switch]$DryRun,
    [string]$Name,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- 1. Validate the payload locally ----------------------------------------
# Everything here runs offline. If the body is malformed we want to know before
# authenticating, not from a 400 halfway through.

if (-not (Test-Path $JsonPath)) { throw "JSON not found: $JsonPath" }

$raw = Get-Content -LiteralPath $JsonPath -Raw
try   { $obj = $raw | ConvertFrom-Json }
catch { throw "JSON does not parse: $($_.Exception.Message)" }

foreach ($p in 'name','platforms','technologies','settings') {
    if (-not $obj.PSObject.Properties.Name.Contains($p)) {
        throw "Payload is missing required property '$p'."
    }
}

# These four must be JSON arrays even with a single element. PowerShell's
# ConvertTo-Json collapses single-element arrays, and Graph rejects the POST
# with an unhelpful error when it happens.
$si  = $obj.settings[0].settingInstance
$gsc = $si.groupSettingCollectionValue
$kids = $gsc[0].children
$vals = $kids[0].simpleSettingCollectionValue

if ($obj.settings -isnot [array]) { throw "'settings' is not an array." }
if ($gsc  -isnot [array])         { throw "'groupSettingCollectionValue' is not an array." }
if ($kids -isnot [array])         { throw "'children' is not an array." }
if ($vals -isnot [array])         { throw "'simpleSettingCollectionValue' is not an array." }

if ($kids[0].settingDefinitionId -ne 'com.apple.applicationaccess_blockedappbundleids') {
    throw "Unexpected settingDefinitionId: $($kids[0].settingDefinitionId)"
}

if ($Name) {
    $obj.name = $Name
    $raw = $obj | ConvertTo-Json -Depth 20
}

Write-Host ""
Write-Host "Payload validated." -ForegroundColor Green
Write-Host "  Name      : $($obj.name)"
Write-Host "  Platform  : $($obj.platforms)  ($($obj.technologies))"
Write-Host "  Blocked   : $($vals.Count) bundle ID(s)"
Write-Host "  Body size : $($raw.Length) bytes"
Write-Host "  Endpoint  : POST https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN - nothing was sent and no connection was made." -ForegroundColor Yellow
    Write-Host "First 5 blocked bundle IDs:"
    $vals.value | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
    return
}

# --- 2. Connect --------------------------------------------------------------

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$ctx = Get-MgContext
if (-not $ctx) {
    Write-Host ""
    Write-Host "Connecting (device code - a code will be shown below)..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes 'DeviceManagementConfiguration.ReadWrite.All' -UseDeviceCode
    $ctx = Get-MgContext
}
Write-Host "Connected as $($ctx.Account) [$($ctx.TenantId)]"

# --- 3. Collision check ------------------------------------------------------
# Creating a second profile with the same name is legal in Intune and a good way
# to end up with two policies fighting over the same setting.

$escaped = $obj.name.Replace("'","''")
$existing = Invoke-MgGraphRequest -Method GET -Uri (
    "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies" +
    "?`$filter=name eq '$escaped'"
)

if ($existing.value.Count -gt 0 -and -not $Force) {
    Write-Host ""
    Write-Warning "A profile named '$($obj.name)' already exists:"
    $existing.value | ForEach-Object {
        Write-Host "  id=$($_.id)  modified=$($_.lastModifiedDateTime)"
    }
    Write-Host ""
    Write-Host "Refusing to create a duplicate. Options:" -ForegroundColor Yellow
    Write-Host "  - Deploy under a different name:  -Name 'iOS - Blocked Applications (PILOT)'"
    Write-Host "  - Update the existing profile instead (see README)"
    Write-Host "  - Create the duplicate anyway:     -Force"
    return
}

# --- 4. Create, unassigned ---------------------------------------------------

Write-Host ""
Write-Host "Creating profile (no assignments)..." -ForegroundColor Cyan
$new = Invoke-MgGraphRequest -Method POST `
    -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' `
    -Body $raw -ContentType 'application/json'

Write-Host ""
Write-Host "Created." -ForegroundColor Green
Write-Host "  id   : $($new.id)"
Write-Host "  name : $($new.name)"
Write-Host ""
Write-Host "It is assigned to nothing, so no device is affected yet." -ForegroundColor Yellow
Write-Host ""
Write-Host "Verify the settings landed correctly:"
Write-Host "  Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($new.id)/settings' |"
Write-Host "      ConvertTo-Json -Depth 20"
Write-Host ""
Write-Host "Remove it if this was a test:"
Write-Host "  Invoke-MgGraphRequest -Method DELETE -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($new.id)'"
Write-Host ""
Write-Host "When you are ready, assign it in the portal to a pilot group first," -ForegroundColor Cyan
Write-Host "scoped with a supervised-device filter."

$new

