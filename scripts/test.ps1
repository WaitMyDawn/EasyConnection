param([switch]$Native)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$env:DOTNET_CLI_HOME = Join-Path $projectRoot '.tools\dotnet-home'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:PUB_CACHE = Join-Path $projectRoot '.tools\pub-cache'
$dotnetPath = if (Test-Path -LiteralPath '.tools\dotnet\dotnet.exe') { Join-Path $projectRoot '.tools\dotnet\dotnet.exe' } else { 'dotnet' }
$flutterPath = if (Test-Path -LiteralPath '.tools\flutter\bin\flutter.bat') { Join-Path $projectRoot '.tools\flutter\bin\flutter.bat' } else { 'flutter' }
& $dotnetPath run --project 'tests\EasyConnection.Core.Tests'
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed' }
$javacPath = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\javac.exe' } else { (Get-Command javac -ErrorAction SilentlyContinue).Source }
if ($javacPath -and (Test-Path -LiteralPath $javacPath)) {
    $cacheTestClasses = Join-Path $projectRoot '.test-state\java-cache'
    New-Item -ItemType Directory -Force -Path $cacheTestClasses | Out-Null
    & $javacPath -encoding UTF-8 -d $cacheTestClasses 'apps/mobile/android/app/src/main/java/dev/easyconnection/easy_connection/CacheFiles.java' 'tests/android-cache/CacheFilesTest.java'
    if ($LASTEXITCODE -ne 0) { throw 'Android cache test compilation failed' }
    & (Join-Path (Split-Path $javacPath) 'java.exe') -cp $cacheTestClasses dev.easyconnection.easy_connection.CacheFilesTest (Join-Path $projectRoot '.test-state')
    if ($LASTEXITCODE -ne 0) { throw 'Android cache tests failed' }
} else { Write-Output 'SKIP: JDK unavailable for Android cache tests' }
if ($Native) {
    & $dotnetPath run --project 'src\EasyConnection.Host' -- --self-test
    if ($LASTEXITCODE -ne 0) { throw 'Native integration tests failed' }
}
Push-Location 'apps\mobile'
try {
    & $flutterPath analyze
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed' }
    & $flutterPath test
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed' }
} finally { Pop-Location }
