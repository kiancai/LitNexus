[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [switch]$SelfTest,
    [string]$Version
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidate = Join-Path $env:LOCALAPPDATA "LitNexus\dotnet\dotnet.exe"
$dotnet = if (Test-Path $candidate) { $candidate } else { (Get-Command dotnet -ErrorAction Stop).Source }

$buildArguments = @(
    "build",
    (Join-Path $root "LitNexus.sln"),
    "--configuration", $Configuration,
    "--nologo"
)

if (-not [string]::IsNullOrWhiteSpace($Version)) {
    # Release tags can be SemVer (for example 0.2.0-beta6); FileVersion is numeric only.
    $versionPattern = '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<pre>[0-9A-Za-z][0-9A-Za-z.-]*))?(?:\+(?<build>[0-9A-Za-z][0-9A-Za-z.-]*))?$'
    $versionMatch = [regex]::Match($Version, $versionPattern)

    if (-not $versionMatch.Success) {
        throw "-Version must be a semantic version, for example 0.2.0-beta6 or 0.2.0."
    }

    $major = [int64]$versionMatch.Groups['major'].Value
    $minor = [int64]$versionMatch.Groups['minor'].Value
    $patch = [int64]$versionMatch.Groups['patch'].Value
    foreach ($component in @($major, $minor, $patch)) {
        if ($component -gt 65535) {
            throw "-Version numeric components must not exceed 65535 for a Windows FileVersion."
        }
    }

    $numericVersion = "{0}.{1}.{2}.0" -f $major, $minor, $patch

    $buildArguments += @(
        "-p:Version=$Version",
        "-p:InformationalVersion=$Version",
        "-p:AssemblyVersion=$numericVersion",
        "-p:FileVersion=$numericVersion"
    )
}

& $dotnet @buildArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($SelfTest) {
    $selfTestExecutable = Join-Path $root "tests\LitNexus.SelfTest\bin\$Configuration\net48\LitNexus.SelfTest.exe"
    & $selfTestExecutable
    exit $LASTEXITCODE
}
