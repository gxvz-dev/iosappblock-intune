<#
.SYNOPSIS
    Turns App Store links, IDs, or a list CSV into a deployable Apple app
    policy: block or allow app lists, notification silencing, or single-app
    lock - as an Intune Settings Catalog body or a raw .mobileconfig.

.DESCRIPTION
    Everything a bundle ID can drive, from one input pipeline. Inputs are
    resolved through Apple's public iTunes API; inputs that fail to resolve
    are reported and EXCLUDED, never passed through.

    Payloads (-Payload):

      AppAccess (default)   Block or allow the listed apps (-Mode).
                            Graph Settings Catalog body or .mobileconfig.
      NotificationSilence   Turn notifications off for the listed apps.
                            .mobileconfig only.
      SingleAppLock         Lock the device into exactly one app (kiosk).
                            .mobileconfig only.

    Modes (-Mode, AppAccess only):

      Block   The listed apps are hidden and cannot run.
      Allow   ONLY the listed apps may run - everything not listed,
              including most built-in apps, disappears. This is the stronger
              control, and the wrong place for a category list: feed it your
              approved-apps list, not a list of apps you dislike. Apple
              treats blockedAppBundleIDs and allowedAppBundleIDs as mutually
              exclusive - deploy one or the other, never both.

    ALL of these payloads require SUPERVISED devices (ABM/ASM + ADE). On an
    unsupervised device the profile reports as applied and does nothing.

    Nothing here touches your tenant. The script reads Apple's public API and
    writes a file; deploying is a separate step (Publish-IntuneAppProfile.ps1
    for Graph bodies, a portal upload for .mobileconfig).

.PARAMETER AppStoreUrl
    One or more App Store links. Any URL containing /id<digits> works,
    including localized storefronts.

.PARAMETER AppId
    One or more App Store numeric IDs, e.g. 547702041.

.PARAMETER BundleId
    One or more bundle IDs. Verified before inclusion unless -SkipVerify.

.PARAMETER InputFile
    A list CSV (BundleId column, as written by Get-AppStoreBundleId -SaveTo)
    or a text file with one URL/ID/bundle ID per line. Lines starting with #
    are ignored.

.PARAMETER Payload
    AppAccess (default), NotificationSilence, or SingleAppLock.

.PARAMETER Mode
    Block (default) or Allow. AppAccess payload only.

.PARAMETER Format
    Graph (default, AppAccess only) or MobileConfig. NotificationSilence and
    SingleAppLock are .mobileconfig-only and select it automatically.

.PARAMETER Name
    Profile display name. Defaults per payload and mode.

.PARAMETER Description
    Profile description. Defaults to a supervision note.

.PARAMETER OutFile
    Output path. Defaults per payload, mode and format.

.PARAMETER SkipVerify
    Skip App Store verification of bundle IDs. Offline use only.

.PARAMETER ShowDeployCommand
    Print the matching deploy steps after writing the file.

.PARAMETER PayloadIdentifierPrefix
    Reverse-DNS prefix for .mobileconfig payload identifiers. Set to your
    organization's domain.

.EXAMPLE
    .\New-IntuneAppProfile.ps1 -InputFile .\bundle-ids.csv

    The classic: block the dating list, Graph Settings Catalog body.

.EXAMPLE
    .\New-IntuneAppProfile.ps1 -InputFile .\approved-apps.csv -Mode Allow

    Allowlist twin: only the approved apps may run. Feed it YOUR approved
    list - a category blocklist is the wrong input here.

.EXAMPLE
    .\New-IntuneAppProfile.ps1 -InputFile .\bundle-ids.csv -Payload NotificationSilence

    Softer control: the apps still run, their notifications do not.

.EXAMPLE
    .\New-IntuneAppProfile.ps1 -AppId 361309726 -Payload SingleAppLock

    Kiosk: lock supervised devices into a single app.

.NOTES
    Requires Windows PowerShell 5.1 or later. Pure ASCII, no external modules.
#>
[CmdletBinding(DefaultParameterSetName = 'Url')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Url')]
    [string[]]$AppStoreUrl,

    [Parameter(Mandatory, ParameterSetName = 'AppId')]
    [string[]]$AppId,

    [Parameter(Mandatory, ParameterSetName = 'BundleId')]
    [string[]]$BundleId,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$InputFile,

    [ValidateSet('AppAccess', 'NotificationSilence', 'SingleAppLock')]
    [string]$Payload = 'AppAccess',

    [ValidateSet('Block', 'Allow')]
    [string]$Mode = 'Block',

    [ValidateSet('Graph', 'MobileConfig')]
    [string]$Format,

    [string]$Name,
    [string]$Description = 'Requires supervised devices; silently no-ops on unsupervised devices.',
    [string]$OutFile,
    [switch]$SkipVerify,
    [switch]$ShowDeployCommand,
    [string]$PayloadIdentifierPrefix = 'com.example.apppolicy'
)

# --- Reconcile payload, mode and format --------------------------------------

if ($Payload -ne 'AppAccess') {
    if ($Format -eq 'Graph') {
        throw "$Payload has no Settings Catalog equivalent; it is .mobileconfig only. Drop -Format Graph."
    }
    $Format = 'MobileConfig'
    if ($PSBoundParameters.ContainsKey('Mode')) {
        Write-Warning "-Mode applies only to the AppAccess payload; ignoring it."
    }
} elseif (-not $Format) {
    $Format = 'Graph'
}

if (-not $Name) {
    $Name = switch ($Payload) {
        'AppAccess'           { if ($Mode -eq 'Allow') { 'iOS - Allowed Applications' } else { 'iOS - Blocked Applications' } }
        'NotificationSilence' { 'iOS - Silenced Notifications' }
        'SingleAppLock'       { 'iOS - Single App Lock' }
    }
}

if (-not $OutFile) {
    $base = switch ($Payload) {
        'AppAccess'           { if ($Mode -eq 'Allow') { 'iOS-Allowed-Applications' } else { 'iOS-Blocked-Applications' } }
        'NotificationSilence' { 'iOS-Silenced-Notifications' }
        'SingleAppLock'       { 'iOS-Single-App-Lock' }
    }
    $ext = if ($Format -eq 'MobileConfig') { 'mobileconfig' } else { 'json' }
    $OutFile = ".\$base.$ext"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Resolve-AppStoreId {
    # The numeric ID is always preceded by '/id', whatever the storefront.
    param([string]$Value)
    if ($Value -match '/id(\d+)') { return $Matches[1] }
    return $null
}

function Get-ITunes {
    param([string]$Query)
    try {
        Invoke-RestMethod "https://itunes.apple.com/lookup?$Query&country=us" `
            -TimeoutSec 20 -ErrorAction Stop
    } catch {
        Write-Warning "Lookup failed ($Query): $($_.Exception.Message)"
        $null
    }
}

# --- Normalize every input shape into raw tokens -----------------------------

$tokens = switch ($PSCmdlet.ParameterSetName) {
    'Url'      { $AppStoreUrl }
    'AppId'    { $AppId }
    'BundleId' { $BundleId }
    'File'     {
        if ([IO.Path]::GetExtension($InputFile) -eq '.csv') {
            # A list maintained by Get-AppStoreBundleId -SaveTo.
            Import-Csv -LiteralPath $InputFile |
                ForEach-Object { "$($_.BundleId)".Trim() } |
                Where-Object { $_ }
        } else {
            Get-Content -LiteralPath $InputFile |
                Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                ForEach-Object { $_.Trim() }
        }
    }
}

if (-not $tokens) { throw "No usable input found." }

# --- Resolve tokens to bundle IDs --------------------------------------------

$resolved = New-Object System.Collections.Generic.List[object]
$failed   = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($tok in $tokens) {
    $i++
    Write-Progress -Activity 'Resolving apps' -Status $tok `
        -PercentComplete (100 * $i / @($tokens).Count)
    if ($i -gt 1) { Start-Sleep -Milliseconds 350 }   # Apple throttles ~20/min

    $storeId = Resolve-AppStoreId $tok
    if (-not $storeId -and $tok -match '^\d+$') { $storeId = $tok }

    if ($storeId) {
        $r = Get-ITunes "id=$storeId"
        if ($r -and $r.resultCount -gt 0 -and $r.results[0].bundleId) {
            $resolved.Add([pscustomobject]@{
                Name = $r.results[0].trackName; BundleId = $r.results[0].bundleId
                TrackId = $r.results[0].trackId; Source = $tok
            })
        } else {
            $failed.Add([pscustomobject]@{ Input = $tok; Reason = 'Store ID not found' })
        }
        continue
    }

    # Not a URL and not numeric: treat as a bundle ID.
    if ($SkipVerify) {
        $resolved.Add([pscustomobject]@{
            Name = '(unverified)'; BundleId = $tok; TrackId = ''; Source = $tok
        })
        continue
    }

    $r = Get-ITunes "bundleId=$tok"
    if ($r -and $r.resultCount -gt 0) {
        $resolved.Add([pscustomobject]@{
            Name = $r.results[0].trackName; BundleId = $r.results[0].bundleId
            TrackId = $r.results[0].trackId; Source = $tok
        })
    } else {
        $failed.Add([pscustomobject]@{ Input = $tok; Reason = 'Bundle ID does not resolve' })
    }
}
Write-Progress -Activity 'Resolving apps' -Completed

$unique = @($resolved | Sort-Object BundleId -Unique)
if (-not $unique) { throw "Nothing resolved; refusing to write an empty profile." }

if ($Payload -eq 'SingleAppLock' -and $unique.Count -ne 1) {
    throw "SingleAppLock locks the device into exactly ONE app; got $($unique.Count). Pass a single app."
}

$ids = @($unique.BundleId | Sort-Object)

# --- Graph Settings Catalog body ---------------------------------------------
# Array shapes are load-bearing: 'settings', 'groupSettingCollectionValue',
# 'children' and 'simpleSettingCollectionValue' must be ARRAYS even with one
# element or Graph rejects the POST. ConvertTo-Json collapses single-element
# arrays, so the @() wrappers below are functional, not stylistic.

if ($Format -eq 'Graph') {

    $settingDefinitionId = if ($Mode -eq 'Allow') {
        'com.apple.applicationaccess_allowedappbundleids'
    } else {
        'com.apple.applicationaccess_blockedappbundleids'
    }

    $values = @(
        foreach ($b in $ids) {
            [ordered]@{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
                value         = $b
            }
        }
    )

    $payloadBody = [ordered]@{
        name            = $Name
        description     = $Description
        platforms       = 'iOS'
        technologies    = 'mdm,appleRemoteManagement'
        roleScopeTagIds = @('0')
        settings        = @(
            [ordered]@{
                '@odata.type'   = '#microsoft.graph.deviceManagementConfigurationSetting'
                settingInstance = [ordered]@{
                    '@odata.type'               = '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
                    settingDefinitionId         = 'com.apple.applicationaccess_com.apple.applicationaccess'
                    groupSettingCollectionValue = @(
                        [ordered]@{
                            children = @(
                                [ordered]@{
                                    '@odata.type'                = '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance'
                                    settingDefinitionId          = $settingDefinitionId
                                    simpleSettingCollectionValue = $values
                                }
                            )
                        }
                    )
                }
            }
        )
    }

    $json = $payloadBody | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $OutFile -Value $json -Encoding ASCII
}

# --- .mobileconfig -----------------------------------------------------------

if ($Format -eq 'MobileConfig') {

    function ConvertTo-PlistText {
        param([string]$Text)
        $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
    }

    # Inner payload dict body, per payload type.
    $innerType  = $null
    $innerLines = New-Object System.Collections.Generic.List[string]

    switch ($Payload) {
        'AppAccess' {
            $innerType = 'com.apple.applicationaccess'
            $key = if ($Mode -eq 'Allow') { 'allowListedAppBundleIDs' } else { 'blockedAppBundleIDs' }
            $innerLines.Add("            <key>$key</key>")
            $innerLines.Add('            <array>')
            foreach ($b in $ids) {
                $innerLines.Add("                <string>$(ConvertTo-PlistText $b)</string>")
            }
            $innerLines.Add('            </array>')
        }
        'NotificationSilence' {
            $innerType = 'com.apple.notificationsettings'
            $innerLines.Add('            <key>NotificationSettings</key>')
            $innerLines.Add('            <array>')
            foreach ($b in $ids) {
                $innerLines.Add('                <dict>')
                $innerLines.Add('                    <key>BundleIdentifier</key>')
                $innerLines.Add("                    <string>$(ConvertTo-PlistText $b)</string>")
                $innerLines.Add('                    <key>NotificationsEnabled</key>')
                $innerLines.Add('                    <false/>')
                $innerLines.Add('                </dict>')
            }
            $innerLines.Add('            </array>')
        }
        'SingleAppLock' {
            $innerType = 'com.apple.app.lock'
            $innerLines.Add('            <key>App</key>')
            $innerLines.Add('            <dict>')
            $innerLines.Add('                <key>Identifier</key>')
            $innerLines.Add("                <string>$(ConvertTo-PlistText $ids[0])</string>")
            $innerLines.Add('            </dict>')
        }
    }

    $suffix = switch ($Payload) {
        'AppAccess'           { if ($Mode -eq 'Allow') { 'allowedapps' } else { 'blockedapps' } }
        'NotificationSilence' { 'notifications' }
        'SingleAppLock'       { 'applock' }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
    [void]$sb.AppendLine('<plist version="1.0">')
    [void]$sb.AppendLine('<dict>')
    [void]$sb.AppendLine('    <key>PayloadContent</key>')
    [void]$sb.AppendLine('    <array>')
    [void]$sb.AppendLine('        <dict>')
    [void]$sb.AppendLine('            <key>PayloadType</key>')
    [void]$sb.AppendLine("            <string>$innerType</string>")
    [void]$sb.AppendLine('            <key>PayloadVersion</key>')
    [void]$sb.AppendLine('            <integer>1</integer>')
    [void]$sb.AppendLine('            <key>PayloadIdentifier</key>')
    [void]$sb.AppendLine("            <string>$PayloadIdentifierPrefix.$suffix</string>")
    [void]$sb.AppendLine('            <key>PayloadUUID</key>')
    [void]$sb.AppendLine("            <string>$([guid]::NewGuid().ToString().ToUpper())</string>")
    [void]$sb.AppendLine('            <key>PayloadDisplayName</key>')
    [void]$sb.AppendLine("            <string>$(ConvertTo-PlistText $Name)</string>")
    foreach ($line in $innerLines) { [void]$sb.AppendLine($line) }
    [void]$sb.AppendLine('        </dict>')
    [void]$sb.AppendLine('    </array>')
    [void]$sb.AppendLine('    <key>PayloadType</key>')
    [void]$sb.AppendLine('    <string>Configuration</string>')
    [void]$sb.AppendLine('    <key>PayloadVersion</key>')
    [void]$sb.AppendLine('    <integer>1</integer>')
    [void]$sb.AppendLine('    <key>PayloadIdentifier</key>')
    [void]$sb.AppendLine("    <string>$PayloadIdentifierPrefix</string>")
    [void]$sb.AppendLine('    <key>PayloadUUID</key>')
    [void]$sb.AppendLine("    <string>$([guid]::NewGuid().ToString().ToUpper())</string>")
    [void]$sb.AppendLine('    <key>PayloadDisplayName</key>')
    [void]$sb.AppendLine("    <string>$(ConvertTo-PlistText $Name)</string>")
    [void]$sb.AppendLine('    <key>PayloadDescription</key>')
    [void]$sb.AppendLine("    <string>$(ConvertTo-PlistText $Description)</string>")
    [void]$sb.AppendLine('    <key>PayloadRemovalDisallowed</key>')
    [void]$sb.AppendLine('    <true/>')
    [void]$sb.AppendLine('</dict>')
    [void]$sb.AppendLine('</plist>')

    Set-Content -LiteralPath $OutFile -Value $sb.ToString() -Encoding ASCII
}

# --- Report ------------------------------------------------------------------

Write-Host ""
Write-Host "Profile : $Name  [$Payload$(if ($Payload -eq 'AppAccess') { "/$Mode" }), $Format]"
Write-Host "Apps    : $($unique.Count) bundle ID(s)"
Write-Host "Written : $((Resolve-Path $OutFile).Path)"

if ($Mode -eq 'Allow' -and $Payload -eq 'AppAccess') {
    Write-Host ""
    Write-Warning ("Allow mode: ONLY these $($unique.Count) app(s) will be able to run on " +
        "targeted supervised devices. Everything not listed disappears, " +
        "including most built-in apps. Pilot on a test device first.")
}

if ($failed.Count) {
    Write-Host ""
    Write-Warning "$($failed.Count) input(s) did not resolve and were EXCLUDED:"
    $failed | Format-Table -AutoSize | Out-String | Write-Host
}

if ($ShowDeployCommand) {
    Write-Host ""
    if ($Format -eq 'Graph') {
        Write-Host "To create this profile in Intune:" -ForegroundColor Cyan
        Write-Host @"

    .\Publish-IntuneAppProfile.ps1 -JsonPath '$OutFile' -DryRun     # validate first
    .\Publish-IntuneAppProfile.ps1 -JsonPath '$OutFile'

  The profile is created unassigned; assign it scoped to supervised devices.
"@
    } else {
        Write-Host "To import into Intune (no scripting, no Graph permissions):" -ForegroundColor Cyan
        Write-Host @"

    Devices > iOS/iPadOS > Configuration > Create > New policy
      Profile type : Templates > Custom
      Deployment channel : Device channel
      Configuration profile file : $OutFile

  Then assign it, scoped to supervised devices with an assignment filter.
"@
    }
}

$unique
