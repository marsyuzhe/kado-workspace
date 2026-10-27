"""Assemble complete local Windows distributions. No upload or VCS operations."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import zipfile

ROOT=Path(__file__).resolve().parents[1]


def zip_tree(folder, target):
    with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for file in sorted(folder.rglob('*')):
            if file.is_file():z.write(file,Path('LinksToolbox')/file.relative_to(folder))


def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--vc-runtime',type=Path,required=True,help='Installed Microsoft.VC143.CRT x64 directory; review Microsoft redistribution terms')
    parser.add_argument('--out',type=Path,default=ROOT/'artifacts/public-distribution')
    args=parser.parse_args()
    brand=json.loads((ROOT/'config/brand.json').read_text('utf-8'))
    version=brand['version']
    out=args.out.resolve()
    if not out.is_relative_to(ROOT/'artifacts'):raise ValueError('Output must be inside this source workspace artifacts directory')
    app=out/'windows/LinksToolbox'
    if app.exists():raise ValueError('Preserve existing distribution; select a fresh output')
    build=ROOT/'apps/client/build/windows/x64/runner/Release'
    for name in ['links_toolbox.exe','flutter_windows.dll','sqlite3.dll','data/app.so']:
        if not (build/name).is_file():raise ValueError('Missing Release component: '+name)
    for name in ['msvcp140.dll','vcruntime140.dll']:
        if not (args.vc_runtime/name).is_file():raise ValueError('Missing x64 VC runtime: '+name)
    shutil.copytree(build,app,ignore=shutil.ignore_patterns('*.pdb','native_assets.json','user-data','portable.flag','*.db','*.sqlite*','instance.lock'))
    for path in args.vc_runtime.glob('*.dll'):shutil.copyfile(path,app/path.name)
    for name in ['LICENSE','THIRD_PARTY_NOTICES.md','KNOWN_ISSUES.md']:shutil.copyfile(ROOT/name,app/name)
    shutil.copytree(ROOT/'licenses',app/'licenses')
    docs=app/'docs';docs.mkdir()
    for name in ['USER_GUIDE.md','BACKUP_RESTORE.md','V24_TOOLS_GUIDE.md','DOWNLOADS.md']:
        shutil.copyfile(ROOT/'docs'/name,docs/name)
    shutil.copyfile(ROOT/'scripts/installer/Uninstall.ps1',app/'Uninstall.ps1')
    (app/'APP_VERSION.txt').write_text(version,'ascii')
    (app/'APP_BRAND.json').write_text(json.dumps(brand,ensure_ascii=False,indent=2),'utf-8')
    (app/'START-HERE.txt').write_text('KADO Desk '+version+'\nRun links_toolbox.exe; keep DLLs and data together. Portable mode uses user-data beside the EXE. Installed mode retains the Links Toolbox system data identity. Windows build is locally unsigned. See LICENSE and THIRD_PARTY_NOTICES.md.\n','utf-8')
    (app/'VC_RUNTIME.md').write_text('App-local Microsoft VC143 x64 CRT DLLs are redistributed from Visual Studio Build Tools. They retain Microsoft signatures and applicable Microsoft terms; not MIT. https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files\n','utf-8')
    installer=out/'windows/installer-files';installer.mkdir()
    payload=installer/'payload.zip';zip_tree(app,payload)
    (installer/'payload.sha256').write_text(digest(payload),'ascii')
    shutil.copyfile(ROOT/'scripts/installer/Install.ps1',installer/'Install.ps1')
    (app/'portable.flag').write_text('Store data in user-data beside this executable.\n','utf-8')
    zip_tree(app,out/f'windows/KADO-Desk-v{version}-Windows-Portable.zip')
    (out/'VERSION.json').write_text(json.dumps({'version':version,'artifactPrefix':'KADO-Desk','buildNumber':brand['buildNumber']},indent=2),'utf-8')
    print('Complete Windows folder, portable ZIP and installer payload prepared.')


if __name__=='__main__':main()
