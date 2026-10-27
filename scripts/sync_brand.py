"""Sync visible brand fields only. Stable OS/data identities are deliberately excluded."""
from pathlib import Path
import argparse,json,re
from xml.sax.saxutils import escape
ROOT=Path(__file__).resolve().parents[1]
def main(check=False):
 b=json.loads((ROOT/'config/brand.json').read_text(encoding='utf-8'))
 if b.get('compatibility')!={'windowsCompanyName':'Links Tam','windowsProductName':'Links Toolbox'}:raise ValueError('Stable Windows data/vault identity must not follow the visible brand.')
 for key in ['appDisplayName','appShortName','authorName']:
  if not b[key] or any(ord(c)<32 for c in b[key]):raise ValueError('Invalid visible brand field')
 def literal(value):return "'"+value.replace('\\','\\\\').replace("'","\\'")+"'"
 changes={}
 path=ROOT/'apps/client/lib/app/brand_config.dart';text=path.read_text(encoding='utf-8')
 for name,value in {'displayName':b['appDisplayName'],'shortName':b['appShortName'],'description':b['appDescription'],'author':b['authorName'],'credit':'Created by '+b['authorName'],'legal':b['copyrightText'],'iconAsset':b['brandAssetPath']}.items():
  text,count=re.subn(r'\b'+name+r"(\s*=\s*)'[^']*'",lambda m:name+m[1]+literal(value),text)
  if count!=1:raise ValueError('Missing or ambiguous Dart field '+name)
 changes[path]=text
 changes[ROOT/'apps/client/lib/app/version.dart']="const appVersion = "+literal(b['version'])+";\n"
 path=ROOT/'apps/client/pubspec.yaml';text=path.read_text(encoding='utf-8');changes[path]=re.sub(r'^version: .+$',f"version: {b['version']}+{b['buildNumber']}",text,flags=re.M)
 path=ROOT/'apps/client/windows/runner/main.cpp';text=path.read_text(encoding='utf-8');changes[path]=re.sub(r'window.Create\(L"[^"]+"',lambda m:'window.Create(L"'+b['appDisplayName']+'"',text)
 path=ROOT/'apps/client/windows/runner/Runner.rc';text=path.read_text(encoding='utf-8')
 for key,value in {'FileDescription':b['appDisplayName'],'ProductName':b['compatibility']['windowsProductName'],'CompanyName':b['compatibility']['windowsCompanyName']}.items():text=re.sub(r'(VALUE "'+key+r'", ")[^"]+"',lambda m:m[1]+value+'"',text)
 changes[path]=text
 path=ROOT/'apps/client/android/app/src/main/AndroidManifest.xml';text=path.read_text(encoding='utf-8');changes[path]=re.sub(r'android:label="[^"]+"',lambda m:'android:label="'+escape(b['appDisplayName'],{'"':'&quot;'})+'"',text)
 path=ROOT/'apps/client/ios/Runner/Info.plist';text=path.read_text(encoding='utf-8');changes[path]=re.sub(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]+',lambda m:m[1]+escape(b['appDisplayName']),text)
 dirty=[]
 for path,value in changes.items():
  if path.read_text(encoding='utf-8')!=value:
   dirty.append(str(path.relative_to(ROOT)))
   if not check:path.write_text(value,encoding='utf-8')
 if check and dirty:raise ValueError('Visible brand files out of sync: '+', '.join(dirty))
 assert 'applicationId = "com.linkstam.links_toolbox"' in (ROOT/'apps/client/android/app/build.gradle.kts').read_text(encoding='utf-8')
 assert 'com.linkstam.linksToolbox' in (ROOT/'apps/client/ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
 assert 'Programs\\Links Toolbox' in (ROOT/'scripts/installer/Install.ps1').read_text(encoding='utf-8-sig')
 assert 'Uninstall\\LinksToolbox' in (ROOT/'scripts/installer/Install.ps1').read_text(encoding='utf-8-sig')
 print('Brand synchronized; package IDs, installer identity and data path unchanged. Files updated:',len(dirty))
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');main(parser.parse_args().check)
