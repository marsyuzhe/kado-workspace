"""Give Flutter's generated registrant a package URI, avoiding absolute paths.

Only edits local generated package_config.json; never edits SDK or app sources.
Flutter 3.47.7 maps additional source files through package URIs during compile.
Run after normal Release tooling regeneration, then build with --no-pub.
"""
from pathlib import Path
import json

ROOT=Path(__file__).resolve().parents[1]
config=ROOT/'apps/client/.dart_tool/package_config.json'
data=json.loads(config.read_text('utf-8'))
name='kado_generated_registrant'
alias={'name':name,'rootUri':'flutter_build/','packageUri':'./','languageVersion':'3.13'}
existing=[p for p in data['packages'] if p['name']==name]
if existing and existing != [alias]:
    raise ValueError('Reserved generated-build alias already has different settings')
if not existing:
    data['packages'].append(alias)
    config.write_text(json.dumps(data,indent=2)+'\n','utf-8')
print('Generated registrant package URI prepared; no source/dependency lock change.')
