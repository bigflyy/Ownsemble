"""Package only the Windows runtime; never include local data or browser sessions."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import re
import zipfile

root = Path(__file__).resolve().parent.parent
bundle = root / 'app/build/windows/x64/runner/Release'
version = re.search(r'^version:\s*([^+\s]+)', (root / 'app/pubspec.yaml').read_text(encoding='utf-8'), re.M).group(1)
if not (bundle / 'ownsemble.exe').is_file():
    raise SystemExit('Build the Windows Release target first.')
files = [p for p in bundle.iterdir() if p.is_file() and
         (p.name == 'ownsemble.exe' or p.suffix.lower() == '.dll')]
files += [p for p in (bundle / 'data').rglob('*') if p.is_file()]
for item in files:
    if item.is_symlink() or bundle.resolve() not in item.resolve().parents:
        raise SystemExit('A runtime input leaves the expected bundle.')
output = root / '.local/releases'
output.mkdir(parents=True, exist_ok=True)
stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
target = output / f'Ownsemble-{version}-{stamp}-windows.zip'
with zipfile.ZipFile(target, 'x', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for item in sorted(files):
        archive.write(item, 'Ownsemble/' + item.relative_to(bundle).as_posix())
    archive.writestr('Ownsemble/START_HERE.txt',
        'Extract the complete Ownsemble folder, then double-click ownsemble.exe.\n'
        'Windows x64, WebView2 Runtime and the Microsoft Visual C++ x64 runtime are required.\n'
        'Connect VK once to enable automatic refresh; complete sign-in privately.\n'
        'Library data is stored separately from the runtime bundle.\n'
        'This is an initial candidate; VK playlist support is awaiting verification.\n')
digest = hashlib.sha256(target.read_bytes()).hexdigest()
target.with_suffix('.zip.sha256').write_text(digest + '  ' + target.name + '\n', encoding='utf-8')
report = {'artifact': target.name, 'bytes': target.stat().st_size,
          'sha256': digest, 'runtime_files': len(files), 'user_data_included': False}
(output / 'latest.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
