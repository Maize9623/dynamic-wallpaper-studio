[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$RuntimeIdentifier = "win-x64",

    [string]$OutputDirectory = "",

    [switch]$CreateZip,

    [switch]$IncludeThirdPartyTools
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$projectFile = Join-Path $projectRoot "DynamicWallpaperStudio.Windows.csproj"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot "artifacts\DynamicWallpaperStudio-Windows-x64-1.1.0-OnlinePortable"
}
$publishRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
$zipPath = $publishRoot + ".zip"
$checksumPath = $zipPath + ".sha256"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw ".NET 10 SDK was not found. Install it from https://dotnet.microsoft.com/download/dotnet/10.0"
}

if ($IncludeThirdPartyTools) {
    & (Join-Path $PSScriptRoot "fetch-dependencies.ps1")
    $requiredTools = @("mpv.exe", "vulkan-1.dll", "ffmpeg.exe", "ffprobe.exe", ".runtime-dependencies.json")
    $missingTools = @($requiredTools | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $projectRoot ("tools\" + $_)) -PathType Leaf)
    })
    if ($missingTools.Count -gt 0) {
        throw "Missing runtime dependencies: $($missingTools -join ', ')."
    }
}

if ((Test-Path -LiteralPath $publishRoot) -and
    @(Get-ChildItem -LiteralPath $publishRoot -Force).Count -gt 0) {
    throw "Output directory is not empty: $publishRoot. Choose a new -OutputDirectory or remove the old build explicitly."
}
if ($CreateZip -and ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $checksumPath))) {
    throw "Release ZIP or checksum already exists: $zipPath. Choose a new -OutputDirectory or remove the old files explicitly."
}

[System.IO.Directory]::CreateDirectory($publishRoot) | Out-Null

Write-Host "Publishing Dynamic Wallpaper Studio to $publishRoot"
& dotnet publish $projectFile `
    --configuration $Configuration `
    --runtime $RuntimeIdentifier `
    --self-contained true `
    -p:IncludeThirdPartyTools=$($IncludeThirdPartyTools.IsPresent.ToString().ToLowerInvariant()) `
    --output $publishRoot

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

# Self-contained .NET redistribution requires the matching Microsoft license and
# third-party notices. Locate them beside the dotnet host and copy them into the
# publish directory instead of relying on machine-specific absolute paths.
$dotnetCommand = Get-Command dotnet
$dotnetRoot = Split-Path -Parent $dotnetCommand.Source
$dotnetLicense = Join-Path $dotnetRoot "LICENSE.txt"
$dotnetNotices = Join-Path $dotnetRoot "ThirdPartyNotices.txt"
if (-not (Test-Path -LiteralPath $dotnetLicense) -or -not (Test-Path -LiteralPath $dotnetNotices)) {
    throw "Could not find the .NET redistribution notices beside $($dotnetCommand.Source)."
}
$licenseOutput = Join-Path $publishRoot "LICENSES"
[System.IO.Directory]::CreateDirectory($licenseOutput) | Out-Null
Copy-Item -LiteralPath $dotnetLicense -Destination (Join-Path $licenseOutput "dotnet-LICENSE.txt")
Copy-Item -LiteralPath $dotnetNotices -Destination (Join-Path $licenseOutput "dotnet-ThirdPartyNotices.txt")

# Keep the release's version-pinned WPF notices and Microsoft's Windows binary
# license mapping alongside the SDK-root runtime notices copied above. Copying
# them explicitly makes the packaging contract independent of MSBuild content
# item behavior and fails closed if a required notice is ever removed.
$versionedDotnetNotices = @(
    "dotnet-wpf-10.0.12-LICENSE.txt",
    "dotnet-wpf-10.0.12-ThirdPartyNotices.txt",
    "dotnet-10.0.12-license-information.md",
    "dotnet-10.0.12-license-information-windows.md",
    "dotnet-10.0.12-SOURCES.md"
)
foreach ($noticeName in $versionedDotnetNotices) {
    $noticeSource = Join-Path $projectRoot ("LICENSES\" + $noticeName)
    if (-not (Test-Path -LiteralPath $noticeSource -PathType Leaf)) {
        throw "Required .NET 10.0.12 notice is missing: $noticeSource"
    }
    Copy-Item -LiteralPath $noticeSource -Destination (Join-Path $licenseOutput $noticeName) -Force
}

if (-not $IncludeThirdPartyTools) {
    $forbiddenRuntimeFiles = @("mpv.exe", "vulkan-1.dll", "ffmpeg.exe", "ffprobe.exe")
    $unexpectedRuntimeFiles = @(Get-ChildItem -LiteralPath $publishRoot -Recurse -File | Where-Object {
        $forbiddenRuntimeFiles -contains $_.Name
    })
    if ($unexpectedRuntimeFiles.Count -gt 0) {
        throw "Public build unexpectedly contains third-party runtime tools: $($unexpectedRuntimeFiles.FullName -join ', ')."
    }
}

if ($CreateZip) {
    Compress-Archive -LiteralPath $publishRoot -DestinationPath $zipPath -CompressionLevel Optimal
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumLine = "$zipHash  $([System.IO.Path]::GetFileName($zipPath))"
    [System.IO.File]::WriteAllText($checksumPath, $checksumLine + [Environment]::NewLine, [System.Text.Encoding]::ASCII)
    Write-Host "Release ZIP: $zipPath"
    Write-Host "SHA-256: $zipHash"
}

Write-Host "Build complete: $publishRoot"
