param([string]$Version='2.4.0',[string]$ReleaseDirectory='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory=Join-Path $root 'artifacts\public-distribution' }
$windows=Join-Path ([IO.Path]::GetFullPath($ReleaseDirectory)) 'windows'
$source=Join-Path $windows 'installer-files'
$brand=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $root 'config\brand.json') -Raw | ConvertFrom-Json
$artifactPrefix=$brand.artifactPrefix
$displayName=$brand.appDisplayName
$target=Join-Path $windows "$artifactPrefix-v$Version-Windows-Setup.exe"
if(Test-Path -LiteralPath $target){throw 'Installer output already exists; preserve the previous milestone.'}
$work=Join-Path $root "artifacts\qa\installer-build-$Version"
New-Item -ItemType Directory -Path $work -Force | Out-Null
$sed=Join-Path $work 'LinksToolbox.sed'
@"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
InstallPrompt=Install $displayName $Version for the current user?
FinishMessage=$displayName installation completed. User data is kept separately.
TargetName=$target
FriendlyName=$displayName $Version Local Milestone
AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install.ps1
FILE0="Install.ps1"
FILE1="payload.zip"
FILE2="payload.sha256"
[SourceFiles]
SourceFiles0=$source\
[SourceFiles0]
%FILE0%=
%FILE1%=
%FILE2%=
"@ | Set-Content -LiteralPath $sed -Encoding ascii
$builder=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\iexpress.exe') -ArgumentList @('/N','/Q',$sed) -WindowStyle Hidden -PassThru -Wait
if($builder.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $target)){throw 'IExpress installer creation failed.'}
& python (Join-Path $root 'scripts\set_windows_icon.py') $target (Join-Path $root 'design\brand\v23\kado_desk.ico')
if($LASTEXITCODE -ne 0){throw 'Installer icon resource update failed.'}
Get-Item -LiteralPath $target | Select-Object Name,Length
