<#
.SYNOPSIS
    Turns App Store links (or IDs, or bundle IDs) into a ready-to-POST Intune
    Settings Catalog profile that blocks those apps on supervised iOS devices.

.DESCRIPTION
    Paste App Store URLs in, get a deployable Intune profile out.

    Intune's "Blocked App Bundle IDs" setting takes bundle IDs, but everything a
    human actually has - a store link, a search result, a name - is not a bundle
    ID. This script closes that gap end to end: it accepts what you have, uses
    Apple's public iTunes API to resolve it, and emits the exact JSON body the
    Graph configurationPolicies endpoint expects.

    Nothing here touches your tenant. The script only reads Apple's public API
    and writes a file. Creating the profile is a deliberate, separate step
    (see -ShowDeployCommand).

.PARAMETER AppStoreUrl
    One or more App Store links, e.g.
    https://apps.apple.com/us/app/tinder-dating-app/id547702041
    Any URL containing /id<digits> works, including localized storefronts.

.PARAMETER AppId
    One or more App Store numeric IDs, e.g. 547702041.

.PARAMETER BundleId
    One or more bundle IDs you already have. Verified before inclusion unless
    -SkipVerify is set.

.PARAMETER InputFile
    Path to a text file with one URL, ID, or bundle ID per line. Blank lines and
    lines starting with # are ignored, so you can annotate the list.

.PARAMETER Name
    Profile display name. Defaults to 'iOS - Blocked Applications'.

.PARAMETER Description
    Profile description. Defaults to a note about the supervision requirement.

.PARAMETER OutFile
    Where to write the JSON. Defaults to .\iOS-Blocked-Applications.json.

.PARAMETER SkipVerify
    Do not verify bundle IDs against the App Store. Faster, but a typo becomes a
    silent gap in your blocklist. Only use this offline.

.PARAMETER ShowDeployCommand
    Print the Graph command to create the profile, instead of you looking it up.

.EXAMPLE
    .\New-IntuneBlockedAppProfile.ps1 -AppStoreUrl `
        'https://apps.apple.com/us/app/tinder-dating-app/id547702041',
        'https://apps.apple.com/us/app/bumble-dating-app/id930441707'

    The common case: paste links, get a profile.

.EXAMPLE
    .\New-IntuneBlockedAppProfile.ps1 -InputFile .\bundle-ids.txt `
        -Name 'iOS - Blocked Dating Apps' -ShowDeployCommand

    Rebuild the profile from the maintained blocklist and print deploy steps.

.EXAMPLE
    .\Get-AppStoreBundleId.ps1 -Search 'dating' -Limit 100 |
        Select-Object -ExpandProperty BundleId |
        Set-Content .\candidates.txt
    # review candidates.txt by hand, then:
    .\New-IntuneBlockedAppProfile.ps1 -InputFile .\candidates.txt

    Discovery feeding deployment, with a human review step in between. Do not
    automate that middle step away - see README.

.NOTES
    Requires Windows PowerShell 5.1 or later. Pure ASCII, no external modules.
    Blocked app restrictions require SUPERVISED devices. On unsupervised
    devices the profile reports as applied and does nothing.
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

    [string]$Name = 'iOS - Blocked Applications',
    [string]$Description = 'Blocks the listed app bundle IDs. Requires supervised devices; silently no-ops on unsupervised devices.',
    [string]$OutFile,
    [switch]$SkipVerify,
    [switch]$ShowDeployCommand,

    # Graph        - Settings Catalog POST body. Deployed by script (see
    #                -ShowDeployCommand). This is the maintainable path.
    # MobileConfig - Apple .mobileconfig. Uploaded by hand in the Intune portal
    #                under Configuration profiles > Templates > Custom. No
    #                scripting or Graph permissions needed.
    [ValidateSet('Graph', 'MobileConfig')]
    [string]$Format = 'Graph',

    # Reverse-DNS prefix for the .mobileconfig payload identifiers. Set this to
    # your own organization's domain so the profile is identifiable on-device
    # and cannot collide with another vendor's payload.
    [string]$PayloadIdentifierPrefix = 'com.example.restrictions'
)

if (-not $OutFile) {
    $OutFile = if ($Format -eq 'MobileConfig') { '.\iOS-Blocked-Applications.mobileconfig' }
               else                            { '.\iOS-Blocked-Applications.json' }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Resolve-AppStoreId {
    # Store URLs vary by storefront and slug, but the numeric ID is always
    # preceded by '/id'. Match that rather than trying to parse the whole path.
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

# --- Normalize every input shape into a list of raw tokens -------------------

$tokens = switch ($PSCmdlet.ParameterSetName) {
    'Url'      { $AppStoreUrl }
    'AppId'    { $AppId }
    'BundleId' { $BundleId }
    'File'     {
        if ([IO.Path]::GetExtension($InputFile) -eq '.csv') {
            # A list maintained by Save-BundleIdList.ps1 - take its BundleId
            # column so the CSV feeds this script with no conversion step.
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

# --- Resolve tokens to bundle IDs -------------------------------------------

$resolved = New-Object System.Collections.Generic.List[object]
$failed   = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($tok in $tokens) {
    $i++
    Write-Progress -Activity 'Resolving apps' -Status $tok `
        -PercentComplete (100 * $i / $tokens.Count)
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

    # Not a URL and not numeric, so treat it as a bundle ID.
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

# Duplicates are harmless in Intune but make the profile hard to audit.
$unique = $resolved | Sort-Object BundleId -Unique
if (-not $unique) { throw "Nothing resolved; refusing to write an empty profile." }

# --- MobileConfig branch -----------------------------------------------------

if ($Format -eq 'MobileConfig') {

    function ConvertTo-PlistText {
        # Bundle IDs are safe, but display names and descriptions are free text
        # and XML will not forgive an unescaped ampersand.
        param([string]$Text)
        $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
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
    [void]$sb.AppendLine('            <string>com.apple.applicationaccess</string>')
    [void]$sb.AppendLine('            <key>PayloadVersion</key>')
    [void]$sb.AppendLine('            <integer>1</integer>')
    [void]$sb.AppendLine('            <key>PayloadIdentifier</key>')
    [void]$sb.AppendLine("            <string>$PayloadIdentifierPrefix.blockedapps</string>")
    [void]$sb.AppendLine('            <key>PayloadUUID</key>')
    [void]$sb.AppendLine("            <string>$([guid]::NewGuid().ToString().ToUpper())</string>")
    [void]$sb.AppendLine('            <key>PayloadDisplayName</key>')
    [void]$sb.AppendLine('            <string>Restrictions</string>')
    [void]$sb.AppendLine('            <key>blockedAppBundleIDs</key>')
    [void]$sb.AppendLine('            <array>')
    foreach ($b in ($unique.BundleId | Sort-Object)) {
        [void]$sb.AppendLine("                <string>$(ConvertTo-PlistText $b)</string>")
    }
    [void]$sb.AppendLine('            </array>')
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

    Write-Host ""
    Write-Host "Profile : $Name  (.mobileconfig)"
    Write-Host "Apps    : $($unique.Count) bundle ID(s)"
    Write-Host "Written : $((Resolve-Path $OutFile).Path)"

    if ($failed.Count) {
        Write-Host ""
        Write-Warning "$($failed.Count) input(s) did not resolve and were EXCLUDED:"
        $failed | Format-Table -AutoSize | Out-String | Write-Host
    }

    if ($ShowDeployCommand) {
        Write-Host ""
        Write-Host "To import into Intune (no scripting, no Graph permissions):" -ForegroundColor Cyan
        Write-Host @"

    Devices > iOS/iPadOS > Configuration > Create > New policy
      Profile type : Templates > Custom
      Custom configuration profile name : $Name
      Deployment channel                : Device channel
      Configuration profile file        : $OutFile

  Then assign it, scoped to supervised devices with an assignment filter.
"@
    }

    return $unique
}

# --- Build the Settings Catalog payload -------------------------------------
# Shape matters: 'settings', 'groupSettingCollectionValue', 'children' and
# 'simpleSettingCollectionValue' must all be ARRAYS even with one element, or
# Graph rejects the POST. ConvertTo-Json collapses single-element arrays, so
# the @() wrappers below are load-bearing, not stylistic.

$values = @(
    foreach ($b in ($unique.BundleId | Sort-Object)) {
        [ordered]@{
            '@odata.type' = '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
            value         = $b
        }
    }
)

$payload = [ordered]@{
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
                                settingDefinitionId          = 'com.apple.applicationaccess_blockedappbundleids'
                                simpleSettingCollectionValue = $values
                            }
                        )
                    }
                )
            }
        }
    )
}

$json = $payload | ConvertTo-Json -Depth 20
Set-Content -LiteralPath $OutFile -Value $json -Encoding ASCII

# --- Report ------------------------------------------------------------------

Write-Host ""
Write-Host "Profile : $Name"
Write-Host "Apps    : $($unique.Count) bundle ID(s)"
Write-Host "Written : $((Resolve-Path $OutFile).Path)"

if ($failed.Count) {
    Write-Host ""
    Write-Warning "$($failed.Count) input(s) did not resolve and were EXCLUDED:"
    $failed | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "An unresolved entry is a gap in the blocklist, not a warning you can ignore."
}

if ($ShowDeployCommand) {
    Write-Host ""
    Write-Host "To create this profile in Intune:" -ForegroundColor Cyan
    Write-Host @"

    Connect-MgGraph -Scopes 'DeviceManagementConfiguration.ReadWrite.All' -UseDeviceCode

    Invoke-MgGraphRequest -Method POST ``
        -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' ``
        -Body (Get-Content '$OutFile' -Raw) ``
        -ContentType 'application/json'

  Then assign it, scoped to supervised devices with an assignment filter.
"@
}

$unique


