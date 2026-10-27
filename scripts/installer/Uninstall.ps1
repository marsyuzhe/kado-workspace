$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$markerPath = Join-Path $root 'links-install.json'
$marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
if ($marker.appId -ne 'com.linkstam.links_toolbox') { throw 'Invalid install marker. No files removed.' }
$directories = @()
foreach ($relative in $marker.files) {
    $file = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $file.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid manifest path. No further files removed.' }
    if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force }
    $directories += Split-Path -Parent $file
}
foreach ($directory in ($directories | Sort-Object -Unique | Sort-Object Length -Descending)) {
    if ($directory -ne $root -and $directory.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $directory) -and -not (Get-ChildItem -LiteralPath $directory -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $directory }
}
Remove-Item -LiteralPath $markerPath -Force
foreach($name in @('KADO Desk.lnk','Links Toolbox.lnk')) {
    $shortcut=Join-Path ([Environment]::GetFolderPath('Programs')) $name
    if(Test-Path -LiteralPath $shortcut){
        $shell=New-Object -ComObject WScript.Shell
        if($shell.CreateShortcut($shortcut).TargetPath -eq (Join-Path $root 'links_toolbox.exe')){Remove-Item -LiteralPath $shortcut}
    }
}
Write-Output 'Application files removed. User data and backups were preserved.'

$registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LinksToolbox'
if (Test-Path $registry) {
    if ((Get-ItemProperty -Path $registry).InstallLocation -eq $root) { Remove-Item -Path $registry }
}
