[CmdletBinding()]
param(
    [string]$ToolsDirectory = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$MpvVersion = "0.41.0"
$MpvUri = "https://github.com/mpv-player/mpv/releases/download/v0.41.0/mpv-v0.41.0-x86_64-pc-windows-msvc.zip"
$MpvSha256 = "4e197f729f5071c6772f35fffd96e0f36e3e8a044bd9479b136bb09b7c6a80ff"

$FfmpegVersion = "9.0.1"
$FfmpegUri = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.1-essentials_build.zip"
$FfmpegSha256 = "fec81ae03971d9dd4be3ebe02e263bd2ec1d789483f931bdba5f5715e65da2e9"
$BundleId = "mpv-0.41.0+ffmpeg-9.0.1"

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Download-VerifiedArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Write-Host "Downloading $Name ..."
    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing

    $actualSha256 = Get-Sha256 -Path $Destination
    if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$Name checksum mismatch. Expected $ExpectedSha256, got $actualSha256."
    }

    Write-Host "$Name archive SHA-256 verified: $actualSha256"
}

function Expand-VerifiedZip {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null

    $destinationRoot = (Get-FullPath -Path $Destination).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $destinationPrefix = $destinationRoot + [System.IO.Path]::DirectorySeparatorChar
    $archiveHandle = [System.IO.Compression.ZipFile]::OpenRead($Archive)

    try {
        foreach ($entry in $archiveHandle.Entries) {
            $relativePath = $entry.FullName.Replace(
                [System.IO.Path]::AltDirectorySeparatorChar,
                [System.IO.Path]::DirectorySeparatorChar
            )
            $targetPath = Get-FullPath -Path (Join-Path $destinationRoot $relativePath)

            if (-not $targetPath.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe ZIP entry rejected: $($entry.FullName)"
            }

            if ([string]::IsNullOrEmpty($entry.Name)) {
                [System.IO.Directory]::CreateDirectory($targetPath) | Out-Null
                continue
            }

            $targetParent = [System.IO.Path]::GetDirectoryName($targetPath)
            [System.IO.Directory]::CreateDirectory($targetParent) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $false)
        }
    }
    finally {
        $archiveHandle.Dispose()
    }
}

function Find-SingleFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $matches = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
        $_.Name -eq $FileName
    })

    if ($matches.Count -ne 1) {
        throw "Expected exactly one $FileName in the verified archive, found $($matches.Count)."
    }

    return $matches[0].FullName
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

if ([string]::IsNullOrWhiteSpace($ToolsDirectory)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        throw "Unable to resolve the tools directory. Pass -ToolsDirectory explicitly."
    }
    $ToolsDirectory = Join-Path $PSScriptRoot "..\tools"
}

$toolsRoot = Get-FullPath -Path $ToolsDirectory
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "dynamic-wallpaper-studio-dependencies-" + [Guid]::NewGuid().ToString("N")
)

try {
    [System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

    $mpvArchive = Join-Path $temporaryRoot "mpv-$MpvVersion.zip"
    $ffmpegArchive = Join-Path $temporaryRoot "ffmpeg-$FfmpegVersion.zip"
    $mpvExtracted = Join-Path $temporaryRoot "mpv"
    $ffmpegExtracted = Join-Path $temporaryRoot "ffmpeg"

    Download-VerifiedArchive -Name "mpv $MpvVersion" -Uri $MpvUri `
        -ExpectedSha256 $MpvSha256 -Destination $mpvArchive
    Download-VerifiedArchive -Name "FFmpeg $FfmpegVersion essentials" -Uri $FfmpegUri `
        -ExpectedSha256 $FfmpegSha256 -Destination $ffmpegArchive

    Expand-VerifiedZip -Archive $mpvArchive -Destination $mpvExtracted
    Expand-VerifiedZip -Archive $ffmpegArchive -Destination $ffmpegExtracted

    $filesToInstall = [ordered]@{
        "mpv.exe" = Find-SingleFile -Root $mpvExtracted -FileName "mpv.exe"
        "vulkan-1.dll" = Find-SingleFile -Root $mpvExtracted -FileName "vulkan-1.dll"
        "ffmpeg.exe" = Find-SingleFile -Root $ffmpegExtracted -FileName "ffmpeg.exe"
        "ffprobe.exe" = Find-SingleFile -Root $ffmpegExtracted -FileName "ffprobe.exe"
    }

    [System.IO.Directory]::CreateDirectory($toolsRoot) | Out-Null
    foreach ($fileName in $filesToInstall.Keys) {
        $stagedPath = Join-Path $toolsRoot ("." + $fileName + "." + [Guid]::NewGuid().ToString("N") + ".tmp")
        $destinationPath = Join-Path $toolsRoot $fileName

        Copy-Item -LiteralPath $filesToInstall[$fileName] -Destination $stagedPath
        try {
            Move-Item -LiteralPath $stagedPath -Destination $destinationPath -Force
        }
        finally {
            if (Test-Path -LiteralPath $stagedPath) {
                Remove-Item -LiteralPath $stagedPath -Force
            }
        }
        Write-Host "Installed $destinationPath"
    }

    $stampPath = Join-Path $toolsRoot ".runtime-dependencies.json"
    $stamp = [ordered]@{
        bundleId = $BundleId
        installedAtUtc = [DateTimeOffset]::UtcNow
        archives = [ordered]@{
            "mpv $MpvVersion" = $MpvSha256
            "FFmpeg $FfmpegVersion Essentials" = $FfmpegSha256
        }
    } | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($stampPath, $stamp, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Dependency installation complete."
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
