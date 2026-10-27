param(
 [ValidateSet('analyze','test','windows-release','android-release','android-debug','run')][string]$Action='analyze',
 [string]$FlutterSdk='', [switch]$SplitPerAbi
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$flutter=if($FlutterSdk){Join-Path $FlutterSdk 'bin/flutter.bat'}else{(Get-Command flutter -ErrorAction Stop).Source}
Push-Location (Join-Path $root 'apps/client')
try {
 switch($Action){
  'analyze' { & $flutter analyze --no-pub }
  'test' {
   & python (Join-Path $PSScriptRoot 'prepare-v24-test-fixtures.py')
   if($LASTEXITCODE -ne 0){throw 'Fixture preparation failed'}
   if(-not(Test-Path -LiteralPath (Join-Path $root 'artifacts/qa/v24-tls'))){& (Join-Path $PSScriptRoot 'create-v24-test-fixtures.ps1')}
   & $flutter test --no-pub --concurrency 1 --reporter expanded
  }
  'windows-release' {
   & $flutter build windows --release "--split-debug-info=$root/artifacts/symbols/windows"
   if($LASTEXITCODE -ne 0){throw 'Normal Release tooling preparation failed'}
   & python (Join-Path $PSScriptRoot 'prepare_public_build.py')
   if($LASTEXITCODE -ne 0){throw 'Public build URI preparation failed'}
   & $flutter build windows --release --no-pub "--split-debug-info=$root/artifacts/symbols/windows"
  }
  'android-release' {
   if(-not $env:LINKS_ANDROID_KEYSTORE -or -not $env:LINKS_ANDROID_STORE_PASSWORD -or -not $env:LINKS_ANDROID_KEY_PASSWORD){throw 'Supply your own signing environment variables; see BUILDING.md. Never use the maintainer key.'}
   $options=@('build','apk','--release',"--split-debug-info=$root/artifacts/symbols/android")
   if($SplitPerAbi){$options+='--split-per-abi';$options+='-Pforce-version-code-ignoring-abi=true'}
   & $flutter @options
   if($LASTEXITCODE -ne 0){throw 'Normal Android Release tooling preparation failed'}
   & python (Join-Path $PSScriptRoot 'prepare_public_build.py')
   if($LASTEXITCODE -ne 0){throw 'Public build URI preparation failed'}
   & $flutter @options --no-pub
  }
  'android-debug' { & $flutter build apk --debug --no-pub }
  'run' { & $flutter run }
 }
 if($LASTEXITCODE -ne 0){throw "Flutter failed: $Action ($LASTEXITCODE)"}
} finally {Pop-Location}
