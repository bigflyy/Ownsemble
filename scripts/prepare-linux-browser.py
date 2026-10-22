"""Fetch a pinned public CEF SDK. Never touches application/browser session data."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import urllib.request

BASE = 'https://cef-builds.spotifycdn.com/'
PIN = Path(__file__).resolve().parent.parent / 'app/linux/browser/cef-runtime.json'


def select_stable(index):
    candidates = []
    for build in index.get('linux64', {}).get('versions', []):
        if build.get('channel') != 'stable':
            continue
        for file in build.get('files', []):
            if file.get('type') == 'minimal':
                candidates.append((tuple(map(int, build['chromium_version'].split('.'))),
                                   {'cef_version': build['cef_version'],
                                    'chromium_version': build['chromium_version'], **file}))
    if not candidates:
        raise ValueError('stable_minimal_missing')
    return max(candidates, key=lambda item: item[0])[1]


def digests(path):
    hashes = [hashlib.sha1(), hashlib.sha256()]
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            for digest in hashes:
                digest.update(block)
    return dict(zip(('sha1', 'sha256'), (h.hexdigest() for h in hashes)))


def verify_archive(path, pin):
    if path.stat().st_size != pin['size']:
        raise ValueError('archive_integrity_size')
    for algorithm, value in digests(path).items():
        if pin.get(algorithm) != value:
            raise ValueError('archive_integrity_' + algorithm)


def extract_archive(path, target, expected_directory):
    with tarfile.open(path) as archive:
        members = archive.getmembers()
        for member in members:
            name = PurePosixPath(member.name)
            if (name.is_absolute() or '..' in name.parts or not name.parts or
                    name.parts[0] != expected_directory or
                    not (member.isfile() or member.isdir())):
                raise ValueError('archive_path')
        # All members were checked before writing anything. No links/devices.
        archive.extractall(target, members=members, filter='data')


def download(name, destination):
    if not re.fullmatch(r'cef_binary_[A-Za-z0-9_+.\-]+_linux64_minimal\.tar\.bz2', name):
        raise ValueError('archive_name')
    partial = destination.with_suffix('.part')
    with urllib.request.urlopen(BASE + name, timeout=90) as response, partial.open('wb') as output:
        while block := response.read(1024 * 1024):
            output.write(block)
    partial.replace(destination)


def prepare(root, pin):
    root.mkdir(parents=True, exist_ok=True)
    archive = root / pin['name']
    if not archive.exists():
        download(pin['name'], archive)
    verify_archive(archive, pin)
    directory = root / pin['name'].removesuffix('.tar.bz2')
    marker = directory / '.ownsemble-sdk-sha256'
    if not marker.exists() or marker.read_text().strip() != pin['sha256']:
        if directory.exists():
            raise ValueError('sdk_destination_exists_without_matching_marker')
        extract_archive(archive, root, directory.name)
        marker.write_text(pin['sha256'] + chr(10))
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--update-pin', action='store_true', help='Explicit maintainer upgrade; review and test before committing')
    args = parser.parse_args()
    if args.update_pin:
        with urllib.request.urlopen(BASE + 'index.json', timeout=60) as response:
            pin = select_stable(json.load(response))
        args.root.mkdir(parents=True, exist_ok=True)
        archive = args.root / pin['name']
        if not archive.exists():
            download(pin['name'], archive)
        measured = digests(archive)
        if archive.stat().st_size != pin['size'] or measured['sha1'] != pin['sha1']:
            raise ValueError('archive_integrity_published')
        pin['sha256'] = measured['sha256']
        pin = {key: pin[key] for key in ('cef_version', 'chromium_version', 'name', 'size', 'sha1', 'sha256')}
        PIN.write_text(json.dumps(pin, indent=2) + chr(10))
    else:
        pin = json.loads(PIN.read_text())
    print(prepare(args.root, pin))


if __name__ == '__main__':
    main()
