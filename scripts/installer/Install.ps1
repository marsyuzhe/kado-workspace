param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\Links Toolbox'), [switch]$SkipShortcuts, [switch]$SkipRegistration, [switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$payload = Join-Path $PSScriptRoot 'payload.zip'
$expected = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'payload.sha256') -Raw).Trim()
if ((Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash -ne $expected) { throw 'Installer payload checksum mismatch.' }
$target = [IO.Path]::GetFullPath($Destination)
if ($target -eq [IO.Path]::GetPathRoot($target)) { throw 'Installation cannot target a drive root.' }
if (Test-Path -LiteralPath (Join-Path $target 'links_toolbox.exe')) {
    $identity = Join-Path $target 'links-install.json'
    if (-not (Test-Path -LiteralPath $identity)) { throw 'Existing files have no Links Toolbox install marker. Choose an empty destination.' }
    if ((Get-Content -LiteralPath $identity -Raw | ConvertFrom-Json).appId -ne 'com.linkstam.links_toolbox') { throw 'Installation marker does not match.' }
}
$extractRoot = Join-Path ([IO.Path]::GetTempPath()) ('links-install-' + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($payload, $extractRoot)
    $sourceRoot = Join-Path $extractRoot 'LinksToolbox'
    $versionFile=Join-Path $sourceRoot 'APP_VERSION.txt'
    $appVersion=if(Test-Path -LiteralPath $versionFile){(Get-Content -LiteralPath $versionFile -Raw).Trim()}else{'1.0.0'}
    $brandFile=Join-Path $sourceRoot 'APP_BRAND.json'
    $displayName=if(Test-Path -LiteralPath $brandFile){(Get-Content -LiteralPath $brandFile -Encoding UTF8 -Raw | ConvertFrom-Json).appDisplayName}else{'Links Toolbox'}
    if(-not $displayName -or $displayName.Length -gt 64 -or $displayName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'Invalid display name.'}
    if($appVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid application version.'}
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'links_toolbox.exe'))) { throw 'Incomplete installer payload.' }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $relativeFiles = @()
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1)
        $output = [IO.Path]::GetFullPath((Join-Path $target $relative))
        if (-not $output.StartsWith($target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid payload path.' }
        New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $output -Force
        $relativeFiles += $relative
    }
    @{ appId='com.linkstam.links_toolbox'; version=$appVersion; files=$relativeFiles; installedAt=(Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $target 'links-install.json') -Encoding utf8
    if (-not $SkipShortcuts) {
        $shell = New-Object -ComObject WScript.Shell
        $menu = Join-Path ([Environment]::GetFolderPath('Programs')) "$displayName.lnk"
        $shortcut = $shell.CreateShortcut($menu)
        $shortcut.TargetPath = Join-Path $target 'links_toolbox.exe'
        $shortcut.WorkingDirectory = $target
        $shortcut.Save()
        $legacy=Join-Path ([Environment]::GetFolderPath('Programs')) 'Links Toolbox.lnk'
        if($legacy -ne $menu -and (Test-Path -LiteralPath $legacy)){
            if($shell.CreateShortcut($legacy).TargetPath -eq (Join-Path $target 'links_toolbox.exe')){Remove-Item -LiteralPath $legacy}
        }
    }
    if (-not $SkipRegistration) {
        $registry = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LinksToolbox'
        New-Item -Path $registry -Force | Out-Null
        $values = @{ DisplayName=$displayName; DisplayVersion=$appVersion; Publisher='Links Tam'; InstallLocation=$target; DisplayIcon=(Join-Path $target 'links_toolbox.exe'); UninstallString=('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $target 'Uninstall.ps1') + '"') }
        foreach ($entry in $values.GetEnumerator()) { New-ItemProperty -Path $registry -Name $entry.Key -Value $entry.Value -PropertyType String -Force | Out-Null }
        New-ItemProperty -Path $registry -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $registry -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
    }
    if (-not $NoLaunch) { Start-Process -FilePath (Join-Path $target 'links_toolbox.exe') -WorkingDirectory $target -WindowStyle Normal }
} finally {
    $resolvedExtract = [IO.Path]::GetFullPath($extractRoot)
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedExtract.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedExtract).StartsWith('links-install-')) {
        Remove-Item -LiteralPath $resolvedExtract -Recurse -Force
    }
}
