param([switch]$SkipAndroid, [switch]$SkipWindows, [string]$ReleaseVersion = '0.4.1')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
if ($ReleaseVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid release version' }
$artifactRoot = Join-Path $projectRoot 'artifacts'
$windowsArtifacts = Join-Path $artifactRoot 'windows'
$androidArtifacts = Join-Path $artifactRoot 'android'
$env:DOTNET_CLI_HOME = Join-Path $projectRoot '.tools\dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:PUB_CACHE = Join-Path $projectRoot '.tools\pub-cache'
$env:GRADLE_USER_HOME = Join-Path $projectRoot '.tools\gradle'
$env:ANDROID_USER_HOME = Join-Path $projectRoot '.tools\android-home'
$env:CI = 'true'
$dependencyProxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy([Uri]'https://downloads.gradle.org')
if ($dependencyProxy.Host -ne 'downloads.gradle.org') {
    $env:GRADLE_OPTS = "-Dhttps.proxyHost=$($dependencyProxy.Host) -Dhttps.proxyPort=$($dependencyProxy.Port) -Dhttp.proxyHost=$($dependencyProxy.Host) -Dhttp.proxyPort=$($dependencyProxy.Port)"
}
if (Test-Path -LiteralPath '.tools\android-sdk') { $env:ANDROID_HOME = Join-Path $projectRoot '.tools\android-sdk' }
$dotnetPath = if (Test-Path -LiteralPath '.tools\dotnet\dotnet.exe') { Join-Path $projectRoot '.tools\dotnet\dotnet.exe' } else { 'dotnet' }
$flutterPath = if (Test-Path -LiteralPath '.tools\flutter\bin\flutter.bat') { Join-Path $projectRoot '.tools\flutter\bin\flutter.bat' } else { 'flutter' }
if (-not $SkipWindows) {
    & $dotnetPath publish 'src\EasyConnection.Host' -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $windowsArtifacts
    if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed' }
    Copy-Item -LiteralPath 'LICENSE' -Destination (Join-Path $windowsArtifacts 'LICENSE.txt')
    Copy-Item -LiteralPath 'third_party\windows\NOTICE.txt' -Destination (Join-Path $windowsArtifacts 'THIRD-PARTY-NOTICES.txt')
}
if (-not $SkipAndroid) {
    Push-Location 'apps\mobile'
    try {
        & $flutterPath pub get
        if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed' }
        $noticeManifest = Get-Content -LiteralPath '..\..\third_party\manifest.json' -Raw | ConvertFrom-Json
        if ((Get-FileHash -LiteralPath 'pubspec.lock' -Algorithm SHA256).Hash.ToLowerInvariant() -ne $noticeManifest.sourceHashes.pubspecLock) {
            throw 'Dependency licenses are out of date; regenerate third-party notices for the current lockfile.'
        }
        Copy-Item -LiteralPath '..\..\LICENSE' -Destination 'assets\licenses\LICENSE'
        & $flutterPath build apk --release
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
        New-Item -ItemType Directory -Force -Path $androidArtifacts | Out-Null
        Copy-Item -LiteralPath 'build\app\outputs\flutter-apk\app-release.apk' -Destination "$androidArtifacts\EasyConnection-$ReleaseVersion.apk"
        Copy-Item -LiteralPath '..\..\LICENSE' -Destination (Join-Path $androidArtifacts 'LICENSE.txt')
        Copy-Item -LiteralPath '..\..\third_party\android\NOTICE.txt' -Destination (Join-Path $androidArtifacts 'THIRD-PARTY-NOTICES.txt')
    } finally { Pop-Location }
}
