<#
.SYNOPSIS
    Finds iOS apps and their bundle IDs via Apple's public iTunes API, and can
    save what you choose straight into a list CSV.

.DESCRIPTION
    Read-only against Apple; optionally writes your list file. Three modes:

      -Search   Free-text App Store search, any category.
      -AppId    Look up App Store numeric IDs (the digits in a store URL).
      -BundleId Reverse-check bundle IDs you already have - the drift check
                for a maintained list. Catches typos, delisted apps, and
                reassigned identifiers.

    Two switches turn a search into a saved list with no copy-pasting:

      -Pick     Show results in a grid (filter box, Ctrl/Shift-click rows,
                OK). Only your selections continue.
      -SaveTo   Merge results into a CSV (BundleId,TrackId,Name). Existing
                entries are never duplicated or overwritten; re-running is a
                no-op. The CSV feeds New-IntuneBlockedAppProfile.ps1 directly.

    No authentication, no app registration, no Graph permissions.

.PARAMETER Search
    One or more free-text search terms, e.g. 'dating', 'gambling', 'vpn'.

.PARAMETER AppId
    One or more App Store numeric track IDs, e.g. 547702041.

.PARAMETER BundleId
    One or more bundle IDs to verify, e.g. com.cardify.tinder.

.PARAMETER Pick
    Choose interactively from the results in an Out-GridView grid before
    anything is emitted or saved.

.PARAMETER SaveTo
    CSV list file to merge results (or your -Pick selections) into. Created if
    missing.

.PARAMETER Country
    Two-letter storefront code. Defaults to 'us'.

.PARAMETER Limit
    Max results per search term. Apple's cap is 200.

.PARAMETER DelayMs
    Pause between requests. Apple throttles at roughly 20 calls/minute per IP.

.EXAMPLE
    .\Get-AppStoreBundleId.ps1 -Search 'gambling' -Limit 100 -Pick -SaveTo .\bundle-ids-gambling.csv

    The whole workflow in one command: search, tick the apps you want in the
    grid, and they land in the list. Run it again with new search terms to
    grow the same file.

.EXAMPLE
    .\Get-AppStoreBundleId.ps1 -AppId 547702041 -SaveTo .\bundle-ids.csv

    Add one known app to a list, no grid.

.EXAMPLE
    .\Get-AppStoreBundleId.ps1 -BundleId (Import-Csv .\bundle-ids.csv).BundleId |
        Where-Object Status -ne 'OK'

    Drift-check a list. Empty output means every entry still resolves.

.NOTES
    Requires Windows PowerShell 5.1 or later. Pure ASCII, no external modules.
    -Pick needs an interactive desktop session (Out-GridView).
#>
[CmdletBinding(DefaultParameterSetName = 'BundleId')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Search')]
    [string[]]$Search,

    [Parameter(Mandatory, ParameterSetName = 'AppId')]
    [string[]]$AppId,

    # AllowEmptyString so a list with blank entries survives parameter binding;
    # the body filters them out.
    [Parameter(Mandatory, ParameterSetName = 'BundleId')]
    [AllowEmptyString()]
    [string[]]$BundleId,

    [switch]$Pick,

    [ValidatePattern('\.csv$')]
    [string]$SaveTo,

    [string]$Country = 'us',

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

    $baseUri   = 'https://itunes.apple.com'
    $first     = $true
    # Buffered rather than streamed so -Pick and -SaveTo can act on the whole
    # result set in the end block.
    $collected = New-Object System.Collections.Generic.List[object]
}

process {
    switch ($PSCmdlet.ParameterSetName) {

        'Search' {
            foreach ($term in $Search) {
                if (-not $first) { Start-Sleep -Milliseconds $DelayMs }
                $first = $false

                $encoded = [uri]::EscapeDataString($term)
                $resp = Invoke-ITunesApi `
                    "$baseUri/search?term=$encoded&country=$Country&entity=software&limit=$Limit"
                if (-not $resp) { continue }

                Write-Verbose "Search '$term' returned $($resp.resultCount) result(s)."
                foreach ($r in $resp.results) { $collected.Add((ConvertTo-Result $r)) }
            }
        }

        'AppId' {
            foreach ($id in $AppId) {
                if (-not $first) { Start-Sleep -Milliseconds $DelayMs }
                $first = $false

                $resp = Invoke-ITunesApi "$baseUri/lookup?id=$id&country=$Country"
                if ($resp -and $resp.resultCount -gt 0) {
                    $collected.Add((ConvertTo-Result $resp.results[0]))
                } else {
                    $collected.Add([pscustomobject]@{
                        BundleId = ''; TrackId = $id; Name = ''; Seller = ''
                        PrimaryGenre = ''; Rating = ''; Status = 'NOT FOUND'
                    })
                }
            }
        }

        'BundleId' {
            foreach ($bundle in $BundleId) {
                $bundle = $bundle.Trim()
                if (-not $bundle -or $bundle.StartsWith('#')) { continue }

                if (-not $first) { Start-Sleep -Milliseconds $DelayMs }
                $first = $false

                $resp = Invoke-ITunesApi "$baseUri/lookup?bundleId=$bundle&country=$Country"
                if ($resp -and $resp.resultCount -gt 0) {
                    $out = ConvertTo-Result $resp.results[0]
                    # Apple echoes the queried bundle ID back; a mismatch means
                    # the store reassigned it. Surface that, not OK.
                    if ($out.BundleId -ne $bundle) {
                        $out.Status = "REASSIGNED (now $($out.BundleId))"
                    }
                    $collected.Add($out)
                } else {
                    $collected.Add([pscustomobject]@{
                        BundleId = $bundle; TrackId = ''; Name = ''; Seller = ''
                        PrimaryGenre = ''; Rating = ''; Status = 'NO MATCH'
                    })
                }
            }
        }
    }
}

end {
    # De-dupe across search terms before anyone sees the results.
    # ToArray(), not @(...): wrapping the generic List directly trips an
    # "Argument types do not match" error under PowerShell 7.5.
    if ($PSCmdlet.ParameterSetName -eq 'Search') {
        $results = @($collected.ToArray() | Sort-Object BundleId -Unique)
    } else {
        $results = $collected.ToArray()
    }

    if ($Pick) {
        $results = @($results |
            Out-GridView -PassThru -Title 'Select apps (Ctrl/Shift-click, then OK)')
        if (-not $results) {
            Write-Warning 'Nothing selected; nothing saved or emitted.'
            return
        }
    }

    if ($SaveTo) {
        # Merge into the list. Existing entries win, so a re-run never
        # duplicates or mutates what is already recorded.
        $list = @{}
        if (Test-Path $SaveTo) {
            foreach ($row in (Import-Csv -LiteralPath $SaveTo)) {
                if ($row.BundleId) { $list[$row.BundleId] = $row }
            }
        }
        $before = $list.Count

        foreach ($r in $results) {
            $id = "$($r.BundleId)".Trim()
            if (-not $id -or $r.Status -notmatch '^OK') { continue }
            if (-not $list.ContainsKey($id)) {
                $list[$id] = [pscustomobject]@{
                    BundleId = $id; TrackId = "$($r.TrackId)"; Name = "$($r.Name)"
                }
            }
        }

        $merged = @($list.Values | Sort-Object BundleId |
            Select-Object BundleId, TrackId, Name)
        $merged | Export-Csv -LiteralPath $SaveTo -NoTypeInformation -Encoding ASCII
        Write-Host "Saved: $SaveTo ($($merged.Count) total, $($merged.Count - $before) new)"
    }

    $results
}
