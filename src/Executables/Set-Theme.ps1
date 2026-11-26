[CmdletBinding(DefaultParameterSetName = 'SetExistingTheme')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'SetExistingTheme')]
    [string]$Path,

    [Parameter(ParameterSetName = 'SetExistingTheme')]
    [ValidateSet('Dark', 'Light')]
    [string]$SystemMode,

    [Parameter(ParameterSetName = 'SetExistingTheme')]
    [ValidateSet('Dark', 'Light')]
    [string]$AppMode,

    [Parameter(Mandatory = $true, ParameterSetName = 'NewCustomTheme')]
    [hashtable]$New
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must be run as Administrator.'
}

function Resolve-RequiredFile {
    param ([Parameter(Mandatory = $true)][string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath) -or
        -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Required file was not found: $FilePath"
    }

    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $FilePath).Path)
}

function Get-LoadedUserSid {
    $profileList = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

    foreach ($hive in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop)) {
        $sid = $hive.PSChildName
        if ($sid -notmatch '^S-\d-\d+-(\d+-)+\d+$' -or $sid -match '^S-1-5-(18|19|20)$') {
            continue
        }

        # ProfileList is a safer user-profile signal than assuming every user
        # SID begins with S-1-5-21 (Microsoft/Azure AD profiles may not).
        $profileKey = Join-Path $profileList $sid
        if (-not (Test-Path -LiteralPath $profileKey)) {
            continue
        }

        try {
            $profile = Get-ItemProperty -LiteralPath $profileKey -Name 'ProfileImagePath' -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$profile.ProfileImagePath)) {
                $hive
            }
        }
        catch {
            Write-Warning "Could not validate loaded user SID '$sid': $($_.Exception.Message)"
        }
    }
}

function Set-ThemeRegistryValue {
    param (
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$ThemePath
    )

    $themeKey = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Themes"
    if (-not (Test-Path -LiteralPath $themeKey)) {
        New-Item -Path $themeKey -Force -ErrorAction Stop | Out-Null
    }

    $currentTheme = Get-ItemProperty -LiteralPath $themeKey -Name 'CurrentTheme' -ErrorAction SilentlyContinue
    if ($null -eq $currentTheme) {
        New-ItemProperty -LiteralPath $themeKey -Name 'CurrentTheme' -Value $ThemePath -PropertyType String -Force -ErrorAction Stop | Out-Null
    }
    else {
        Set-ItemProperty -LiteralPath $themeKey -Name 'CurrentTheme' -Value $ThemePath -ErrorAction Stop
    }
}

function Set-UserModeRegistryValues {
    param (
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][ValidateSet('Dark', 'Light')][string]$SystemMode,
        [Parameter(Mandatory = $true)][ValidateSet('Dark', 'Light')][string]$AppMode
    )

    $personalizeKey = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    if (-not (Test-Path -LiteralPath $personalizeKey)) {
        New-Item -Path $personalizeKey -Force -ErrorAction Stop | Out-Null
    }

    $values = @{
        SystemUsesLightTheme = if ($SystemMode -eq 'Light') { 1 } else { 0 }
        AppsUseLightTheme = if ($AppMode -eq 'Light') { 1 } else { 0 }
    }
    foreach ($entry in $values.GetEnumerator()) {
        $existing = Get-ItemProperty -LiteralPath $personalizeKey -Name $entry.Key -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            New-ItemProperty -LiteralPath $personalizeKey -Name $entry.Key -Value $entry.Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        }
        else {
            Set-ItemProperty -LiteralPath $personalizeKey -Name $entry.Key -Value $entry.Value -ErrorAction Stop
        }
    }
}

function Set-ExistingTheme {
    param (
        [Parameter(Mandatory = $true)][string]$ThemePath,
        [ValidateSet('Dark', 'Light')][string]$SystemMode,
        [ValidateSet('Dark', 'Light')][string]$AppMode
    )

    $resolvedThemePath = Resolve-RequiredFile -FilePath $ThemePath
    Write-Host "Applying existing theme from: $resolvedThemePath"

    $appliedTo = 0
    foreach ($hive in @(Get-LoadedUserSid)) {
        $sid = $hive.PSChildName
        try {
            Set-ThemeRegistryValue -Sid $sid -ThemePath $resolvedThemePath
            if ($SystemMode -and $AppMode) {
                Set-UserModeRegistryValues -Sid $sid -SystemMode $SystemMode -AppMode $AppMode
            }
            $appliedTo++
            Write-Host "Theme assigned for user SID: $sid"
        }
        catch {
            Write-Warning "Could not assign theme for user SID '$sid': $($_.Exception.Message)"
        }
    }

    if ($appliedTo -eq 0) {
        Write-Warning 'No loaded standard user hive could be updated. The theme will still be started for the interactive user.'
    }

    try {
        $themeProcess = Start-Process -FilePath $resolvedThemePath -PassThru -ErrorAction Stop
        if (-not $themeProcess.WaitForExit(30000)) {
            Write-Warning 'The theme process did not exit within 30 seconds; continuing without terminating it.'
        }
        elseif ($themeProcess.ExitCode -ne 0) {
            throw "Theme process exited with code $($themeProcess.ExitCode)."
        }
    }
    catch {
        throw "Could not start the theme '$resolvedThemePath': $($_.Exception.Message)"
    }
}

function Convert-ThemeContent {
    param (
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$WallpaperPath,
        [Parameter(Mandatory = $true)][string]$SystemMode,
        [Parameter(Mandatory = $true)][string]$AppMode
    )

    $sectionKeys = @{
        'Control Panel\Desktop' = [ordered]@{ Wallpaper = $WallpaperPath }
        'Personalize' = [ordered]@{ SystemMode = $SystemMode; AppMode = $AppMode }
    }
    $seen = @{ Wallpaper = $false; SystemMode = $false; AppMode = $false }
    $result = New-Object 'System.Collections.Generic.List[string]'
    $currentSection = ''

    foreach ($line in $Lines) {
        if ($line -match '^\s*\[([^]]+)\]\s*$') {
            $currentSection = $Matches[1]
            $result.Add($line)
            continue
        }

        $replaced = $false
        if ($sectionKeys.ContainsKey($currentSection)) {
            foreach ($key in $sectionKeys[$currentSection].Keys) {
                $value = $sectionKeys[$currentSection][$key]
                if ($line -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
                    $result.Add("$key=$value")
                    $seen[$key] = $true
                    $replaced = $true
                    break
                }
            }
        }

        if (-not $replaced) {
            $result.Add($line)
        }
    }

    foreach ($section in @('Control Panel\Desktop', 'Personalize')) {
        $missing = @()
        foreach ($key in $sectionKeys[$section].Keys) {
            if (-not $seen[$key]) { $missing += ,@($key, $sectionKeys[$section][$key]) }
        }
        if ($missing.Count -eq 0) { continue }

        $result.Add('')
        $result.Add("[$section]")
        foreach ($entry in $missing) {
            $result.Add("$($entry[0])=$($entry[1])")
            $seen[$entry[0]] = $true
        }
    }

    return $result.ToArray()
}

function New-CustomTheme {
    param ([Parameter(Mandatory = $true)][hashtable]$Config)

    if (-not $Config.ContainsKey('WallpaperPath')) {
        throw 'WallpaperPath is required in the hashtable.'
    }

    $wallpaperPath = Resolve-RequiredFile -FilePath ([string]$Config['WallpaperPath'])
    $themeExportPath = if ($Config.ContainsKey('ThemeExportPath')) {
        [string]$Config['ThemeExportPath']
    }
    else {
        Join-Path $env:SystemRoot 'Resources\Themes\revi.theme'
    }
    $systemMode = if ($Config.ContainsKey('SystemMode')) { [string]$Config['SystemMode'] } else { 'Dark' }
    $appMode = if ($Config.ContainsKey('AppMode')) { [string]$Config['AppMode'] } else { 'Dark' }

    if ($systemMode -notin @('Dark', 'Light')) { throw "SystemMode must be 'Dark' or 'Light'." }
    if ($appMode -notin @('Dark', 'Light')) { throw "AppMode must be 'Dark' or 'Light'." }

    $themesDir = Join-Path $env:SystemRoot 'Resources\Themes'
    $baseTheme = if ($systemMode -eq 'Dark') { Join-Path $themesDir 'dark.theme' } else { Join-Path $themesDir 'aero.theme' }
    $baseTheme = Resolve-RequiredFile -FilePath $baseTheme

    $exportDirectory = Split-Path -Parent $themeExportPath
    if (-not (Test-Path -LiteralPath $exportDirectory -PathType Container)) {
        New-Item -Path $exportDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $temporaryThemePath = Join-Path $exportDirectory ('.revi-theme-{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
    try {
        Copy-Item -LiteralPath $baseTheme -Destination $temporaryThemePath -Force -ErrorAction Stop
        $lines = @(Get-Content -LiteralPath $temporaryThemePath -ErrorAction Stop)
        $updatedLines = Convert-ThemeContent -Lines $lines -WallpaperPath $wallpaperPath -SystemMode $systemMode -AppMode $appMode
        Set-Content -LiteralPath $temporaryThemePath -Value $updatedLines -Encoding Unicode -ErrorAction Stop
        Move-Item -LiteralPath $temporaryThemePath -Destination $themeExportPath -Force -ErrorAction Stop
        $temporaryThemePath = $null
    }
    finally {
        if ($temporaryThemePath -and (Test-Path -LiteralPath $temporaryThemePath -PathType Leaf)) {
            Remove-Item -LiteralPath $temporaryThemePath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Custom theme created at $themeExportPath"
    Set-ExistingTheme -ThemePath $themeExportPath -SystemMode $systemMode -AppMode $appMode
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'SetExistingTheme' { Set-ExistingTheme -ThemePath $Path -SystemMode $SystemMode -AppMode $AppMode }
        'NewCustomTheme' { New-CustomTheme -Config $New }
        default { throw "Unsupported parameter set: $($PSCmdlet.ParameterSetName)" }
    }
}
catch {
    throw $_
}
