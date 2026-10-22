"""Fetch only pinned public native build inputs with normal TLS verification."""
from pathlib import Path
import hashlib
import requests
ROOT = Path(__file__).resolve().parent.parent
session = requests.Session()
session.trust_env = False
feed = ROOT / '.local/nuget-source'
feed.mkdir(parents=True, exist_ok=True)
for package, version in [('microsoft.windows.implementationlibrary','1.0.231216.1'),('microsoft.web.webview2','1.0.2792.45'),('nlohmann.json','3.11.2')]:
    target = feed / f'{package}.{version}.nupkg'
    if not target.exists():
        response = session.get(f'https://api.nuget.org/v3-flatcontainer/{package}/{version}/{target.name}', timeout=90)
        response.raise_for_status()
        target.write_bytes(response.content)
    print('Public native package ready:', package, version)
target = ROOT / 'app/build/windows/x64/mpv-dev-x86_64-20230924-git-652a1dd.7z'
if not target.exists() or hashlib.md5(target.read_bytes()).hexdigest() != 'a832ef24b3a6ff97cd2560b5b9d04cd8':
    response = session.get('https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z', timeout=90)
    response.raise_for_status()
    if hashlib.md5(response.content).hexdigest() != 'a832ef24b3a6ff97cd2560b5b9d04cd8':
        raise RuntimeError('vendor_archive_digest_mismatch')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(response.content)
print('Pinned public media library ready.')

angle = ROOT / 'app/build/windows/x64/ANGLE.7z'
if not angle.exists() or hashlib.md5(angle.read_bytes()).hexdigest() != 'e866f13e8d552348058afaafe869b1ed':
    response = session.get('https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z', timeout=90)
    response.raise_for_status()
    if hashlib.md5(response.content).hexdigest() != 'e866f13e8d552348058afaafe869b1ed':
        raise RuntimeError('angle_vendor_digest_mismatch')
    angle.write_bytes(response.content)
print('Pinned public ANGLE library ready.')
