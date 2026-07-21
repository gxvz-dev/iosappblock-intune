<#
.SYNOPSIS
    Queries Apple's public iTunes API to look up app bundle IDs and to verify
    bundle IDs you already have.

.DESCRIPTION
    Read-only. Three modes:

      -Search   Free-text App Store search. Discover apps in any category -
                this is not limited to the list this repo ships.
      -AppId    Look up App Store numeric IDs (the digits in a store URL) and
                return the bundle ID for each.
      -BundleId Reverse-check bundle IDs you already have. Catches typos,
                delisted apps, and identifiers reassigned to a different app.

    The last mode is the drift check for a maintained list: an entry that no
    longer resolves is a silent gap that still looks like coverage in the
    Intune portal.

    No authentication, no app registration, no Graph permissions. The iTunes
    API is public and read-only.

.PARAMETER Search
    One or more free-text search terms, e.g. 'dating', 'gambling', 'vpn'.

.PARAMETER AppId
    One or more App Store numeric track IDs, e.g. 547702041.

.PARAMETER BundleId
    One or more bundle IDs to verify, e.g. com.cardify.tinder.

.PARAMETER Country
    Two-letter storefront code. Defaults to 'us'. Bundle IDs are global, but an
    app absent from a storefront returns no match there.

.PARAMETER DelayMs
    Pause between requests. Apple throttles at roughly 20 calls/minute from a
    single IP; 350ms is a safe default.

.EXAMPLE
    .\Get-AppStoreBundleId.ps1 -Search 'gambling' -Limit 100 |
        Sort-Object BundleId -Unique | Format-Table Name, BundleId

    Discover apps in any category, then feed the bundle IDs to
    New-IntuneBlockedAppProfile.ps1. Nothing here is dating-specific.

    Do not filter on PrimaryGenre: the App Store assigns it inconsistently
    (Tinder, Hinge and Bumble are all 'Lifestyle' while Plenty of Fish is
    'Social Networking'), so genre filtering silently drops major apps.

.EXAMPLE
    .\Get-AppStoreBundleId.ps1 -AppId 547702041, 930441707

    Resolve store IDs to bundle IDs.

.EXAMPLE
    .\Get-AppStoreBundleId.ps1 -BundleId (Get-Content .\bundle-ids.txt) |
        Where-Object Status -ne 'OK'

    Drift check the maintained list. Empty output means no drift; anything
    returned needs attention.

.NOTES
    Requires Windows PowerShell 5.1 or later. Pure ASCII, no external modules.
#>
[CmdletBinding(DefaultParameterSetName = 'BundleId')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Search')]
    [string[]]$Search,

    [Parameter(Mandatory, ParameterSetName = 'AppId')]
    [string[]]$AppId,

    # AllowEmptyString so a list file with blank or commented lines can be
    # passed straight through Get-Content; the body filters them out. Without
    # this, binding fails before the body ever runs.
    [Parameter(Mandatory, ParameterSetName = 'BundleId')]
    [AllowEmptyString()]
    [string[]]$BundleId,

    [string]$Country = 'us',

    # Max results per search term. Apple's cap is 200.
    [ValidateRange(1, 200)]
    [int]$Limit = 50,

    [int]$DelayMs = 350
)

begin {
    # TLS 1.2 is not the default on stock 5.1; itunes.apple.com refuses anything less.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # App Store metadata contains smart quotes, trademark signs and en-dashes.
    # Map them by code point rather than pasting the characters in, so this file
    # stays pure ASCII and 5.1 cannot mis-decode it.
    $script:CharMap = @{
        ([char]0x2018) = "'"; ([char]0x2019) = "'"; ([char]0x02BC) = "'"
        ([char]0x201C) = '"'; ([char]0x201D) = '"'
        ([char]0x2010) = '-'; ([char]0x2011) = '-'
        ([char]0x2013) = '-'; ([char]0x2014) = '-'
    }

    function ConvertTo-AsciiText {
        param([string]$Text)
        if (-not $Text) { return '' }
        $t = $Text
        foreach ($key in $script:CharMap.Keys) { $t = $t.Replace($key, $script:CharMap[$key]) }
        $t = $t -replace '[^\x20-\x7E]', ''
        ($t -replace '\s{2,}', ' ').Trim()
    }

    function Invoke-ITunesApi {
        param([string]$Uri)
        try {
            Invoke-RestMethod -Uri $Uri -TimeoutSec 20 -ErrorAction Stop
        } catch {
            Write-Warning "Request failed: $Uri -- $($_.Exception.Message)"
            $null
        }
    }

    function ConvertTo-Result {
        param($Item)
        [pscustomobject]@{
            BundleId     = $Item.bundleId
            TrackId      = $Item.trackId
            Name         = ConvertTo-AsciiText $Item.trackName
            Seller       = ConvertTo-AsciiText $Item.sellerName
            PrimaryGenre = $Item.primaryGenreName
            Rating       = $Item.contentAdvisoryRating
            Status       = 'OK'
        }
    }

    $baseUri = 'https://itunes.apple.com'
    $first   = $true
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'Search') {
        foreach ($term in $Search) {
            if (-not $first) { Start-Sleep -Milliseconds $DelayMs }
            $first = $false

            $encoded = [uri]::EscapeDataString($term)
            $resp = Invoke-ITunesApi `
                "$baseUri/search?term=$encoded&country=$Country&entity=software&limit=$Limit"
            if (-not $resp) { continue }

            Write-Verbose "Search '$term' returned $($resp.resultCount) result(s)."
            foreach ($r in $resp.results) { ConvertTo-Result $r }
        }
        return
    }

    if ($PSCmdlet.ParameterSetName -eq 'AppId') {
        foreach ($id in $AppId) {
            if (-not $first) { Start-Sleep -Milliseconds $DelayMs }
            $first = $false

            $resp = Invoke-ITunesApi "$baseUri/lookup?id=$id&country=$Country"
            if ($resp -and $resp.resultCount -gt 0) {
                ConvertTo-Result $resp.results[0]
            } else {
                [pscustomobject]@{
                    BundleId = ''; TrackId = $id; Name = ''
                    Seller = ''; Status = 'NOT FOUND'
                }
            }
        }
        return
    }

    foreach ($bundle in $BundleId) {
        $bundle = $bundle.Trim()
        # Tolerate comment and blank lines so a plain .txt list can be piped in.
        if (-not $bundle -or $bundle.StartsWith('#')) { continue }

        if (-not $first) { Start-Sleep -Milliseconds $DelayMs }
        $first = $false

        $resp = Invoke-ITunesApi "$baseUri/lookup?bundleId=$bundle&country=$Country"

        if ($resp -and $resp.resultCount -gt 0) {
            $out = ConvertTo-Result $resp.results[0]
            # Apple echoes the queried bundle ID back; a mismatch would mean the
            # store reassigned it. Surface that rather than reporting OK.
            if ($out.BundleId -ne $bundle) {
                $out.Status = "REASSIGNED (now $($out.BundleId))"
            }
            $out
        } else {
            [pscustomobject]@{
                BundleId = $bundle; TrackId = ''; Name = ''
                Seller = ''; Status = 'NO MATCH'
            }
        }
    }
}
