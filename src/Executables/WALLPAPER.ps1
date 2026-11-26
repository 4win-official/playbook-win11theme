[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Desktop', 'LockScreen')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$ImagePath
)

$ErrorActionPreference = 'Stop'

function Resolve-ImageFile {
    param ([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Image file was not found: $Path"
    }

    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
}

function Get-LoadedUserSid {
    $profileList = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

    foreach ($hive in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction Stop)) {
        $sid = $hive.PSChildName
        if ($sid -notmatch '^S-\d-\d+-(\d+-)+\d+$' -or $sid -match '^S-1-5-(18|19|20)$') {
            continue
        }

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

function Set-DesktopWallpaper {
    param ([Parameter(Mandatory = $true)][string]$Path)

    foreach ($hive in @(Get-LoadedUserSid)) {
        $userKey = "HKEY_USERS\$($hive.PSChildName)\Control Panel\Desktop"
        try {
            [Microsoft.Win32.Registry]::SetValue(
                $userKey, 'Wallpaper', $Path,
                [Microsoft.Win32.RegistryValueKind]::String
            )
        }
        catch {
            Write-Warning "Could not update desktop wallpaper for SID '$($hive.PSChildName)': $($_.Exception.Message)"
        }
    }

    $setWallpaperSource = @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DesktopWallpaper {
    private const int SPI_SETDESKWALLPAPER = 20;
    private const int SPIF_UPDATEINIFILE = 0x01;
    private const int SPIF_SENDWININICHANGE = 0x02;

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SystemParametersInfo(int action, int parameter, string path, int flags);

    public static void SetWallpaper(string path) {
        if (!SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, path, SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@

    if (-not ([System.Management.Automation.PSTypeName]'DesktopWallpaper').Type) {
        Add-Type -TypeDefinition $setWallpaperSource -ErrorAction Stop
    }

    [DesktopWallpaper]::SetWallpaper($Path)
    Write-Host "Desktop wallpaper applied: $Path"
}

function Set-LockScreenWallpaper {
    param ([Parameter(Mandatory = $true)][string]$Path)

    $temporaryImagePath = $null
    try {
        $directory = Split-Path -Parent $Path
        $extension = [System.IO.Path]::GetExtension($Path)
        $temporaryImagePath = Join-Path $directory ('{0}{1}' -f ([guid]::NewGuid().ToString(), $extension))
        Copy-Item -LiteralPath $Path -Destination $temporaryImagePath -Force -ErrorAction Stop

        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime] | Out-Null
        [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null

        # Do not wrap these in @(...): PowerShell 5.1 otherwise keeps a
        # one-element object[] and MakeGenericMethod would fail.
        $asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
                $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            } | Select-Object -First 1
        $asTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and
                $_.GetParameters().Count -eq 1
            } | Select-Object -First 1

        if ($null -eq $asTaskGeneric -or $null -eq $asTaskAction) {
            throw 'Required Windows Runtime AsTask methods are unavailable.'
        }

        $awaitResult = {
            param($operation, $resultType)
            $method = $asTaskGeneric.MakeGenericMethod($resultType)
            $task = $method.Invoke($null, @($operation))
            $task.Wait(-1) | Out-Null
            $task.Result
        }
        $awaitAction = {
            param($operation)
            $task = $asTaskAction.Invoke($null, @($operation))
            $task.Wait(-1) | Out-Null
        }

        $image = & $awaitResult ([Windows.Storage.StorageFile]::GetFileFromPathAsync($temporaryImagePath)) ([Windows.Storage.StorageFile])
        & $awaitAction ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($image))
        Write-Host "Lock screen wallpaper applied: $Path"
    }
    catch {
        Write-Warning "Windows Runtime Lock Screen API could not apply the image: $($_.Exception.Message)"
    }
    finally {
        if ($temporaryImagePath -and (Test-Path -LiteralPath $temporaryImagePath -PathType Leaf)) {
            Remove-Item -LiteralPath $temporaryImagePath -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        [Microsoft.Win32.Registry]::SetValue(
            'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Personalization',
            'LockScreenImage', $Path,
            [Microsoft.Win32.RegistryValueKind]::String
        )
    }
    catch {
        Write-Warning "Could not set the Lock Screen policy value: $($_.Exception.Message)"
    }
}

try {
    $resolvedImagePath = Resolve-ImageFile -Path $ImagePath
    switch ($Mode) {
        'Desktop' { Set-DesktopWallpaper -Path $resolvedImagePath }
        'LockScreen' { Set-LockScreenWallpaper -Path $resolvedImagePath }
    }
}
catch {
    throw $_
}
