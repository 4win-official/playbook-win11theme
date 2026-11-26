[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $env:SystemRoot 'Web\Wallpaper\MeetRevision\WALLPAPER.ps1'
$desktopPath = Join-Path $env:SystemRoot 'Web\Wallpaper\MeetRevision\v2\desktop.jpg'
$lockScreenPath = Join-Path $env:SystemRoot 'Web\Wallpaper\MeetRevision\v2\lockscreen.jpg'
$failures = 0

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-Error "Wallpaper script was not found: $scriptPath"
    exit 1
}

foreach ($wallpaper in @(
    @{ Mode = 'Desktop'; Path = $desktopPath },
    @{ Mode = 'LockScreen'; Path = $lockScreenPath }
)) {
    try {
        if (-not (Test-Path -LiteralPath $wallpaper.Path -PathType Leaf)) {
            throw "Image file was not found: $($wallpaper.Path)"
        }
        & $scriptPath -Mode $wallpaper.Mode -ImagePath $wallpaper.Path
        if (-not $?) {
            throw "WALLPAPER.ps1 did not complete successfully."
        }
    }
    catch {
        $failures++
        Write-Warning "Could not apply $($wallpaper.Mode) wallpaper: $($_.Exception.Message)"
    }
}

try {
    Get-AppxPackage 'Microsoft.OutlookForWindows*' -ErrorAction SilentlyContinue |
        Remove-AppxPackage -ErrorAction SilentlyContinue
}
catch {
    Write-Warning "Could not remove the optional Outlook package: $($_.Exception.Message)"
}

if ($failures -gt 0) { exit 1 }
exit 0
