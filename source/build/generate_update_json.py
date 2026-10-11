"""Generate manager metadata from the actual release ZIP, not hand-written versions."""
import argparse
import json
from pathlib import Path
import urllib.parse
import zipfile

p = argparse.ArgumentParser()
p.add_argument('zip', type=Path)
p.add_argument('--tag', required=True)
p.add_argument('--out', type=Path, default=Path('update.json'))
a = p.parse_args()
with zipfile.ZipFile(a.zip) as z:
    fields = dict(line.split('=', 1) for line in z.read('module.prop').decode('utf-8-sig').splitlines() if '=' in line and not line.startswith('#'))
if fields.get('id') != 'dcimswitch':
    raise SystemExit('Wrong module id')
base = 'https://github.com/YAWAsau/Mount_plus/releases/download/' + urllib.parse.quote(a.tag, safe='') + '/'
metadata = {
    'version': fields['version'],
    'versionCode': int(fields['versionCode']),
    'zipUrl': base + urllib.parse.quote(a.zip.name),
    'changelog': base + 'changelog.md',
}
a.out.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
print(a.out)
