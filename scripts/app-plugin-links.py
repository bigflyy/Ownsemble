"""Create workspace-only plugin directory junctions when symlinks are unavailable."""
import json
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent.parent
project = root / 'app'
plugins = json.loads((project / '.flutter-plugins-dependencies').read_text())
for platform in ('windows', 'linux'):
    if not (project / platform).is_dir():
        continue
    links = project / platform / 'flutter' / 'ephemeral' / '.plugin_symlinks'
    links.mkdir(parents=True, exist_ok=True)
    for item in plugins['plugins'].get(platform, []):
        name = item['name']
        assert re.fullmatch(r'[a-z0-9_]+', name)
        target = Path(item['path']).resolve()
        link = links / name
        assert root in target.parents and root in link.resolve().parents
        if not os.path.lexists(link):
            subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(link), str(target)],
                           check=True, capture_output=True)
print('Workspace plugin junctions ready; system settings and SDK permissions unchanged.')
