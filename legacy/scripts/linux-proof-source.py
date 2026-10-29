"""Archive allowlisted app source/assets, never application runtime state."""
import argparse
from pathlib import Path
import tarfile

DIRECTORIES = ('app/lib', 'app/assets', 'app/test', 'app/tool', 'app/linux')
FILES = ('AGENTS.md', 'app/pubspec.yaml', 'app/pubspec.lock')

def create_source_archive(repository: Path, output: Path) -> int:
    root = repository.resolve()
    candidates = [root / name for name in FILES]
    for name in DIRECTORIES:
        directory = root / name
        if directory.is_symlink():
            raise ValueError('source_symlink')
        if directory.exists():
            candidates.extend(directory.rglob('*'))
    selected = []
    for file in sorted(set(candidates)):
        relative = file.relative_to(root)
        if relative.parts[:4] == ('app', 'linux', 'flutter', 'ephemeral'):
            continue
        if any(part.startswith('.') for part in relative.parts):
            continue
        if file.is_symlink():
            raise ValueError('source_symlink')
        if file.is_file():
            selected.append((file, relative.as_posix()))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, 'w') as archive:
        for file, relative in selected:
            archive.add(file, arcname=relative, recursive=False)
    return len(selected)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    count = create_source_archive(Path(__file__).resolve().parent.parent, args.output)
    print(f'Archived {count} allowlisted source/resource files; no runtime data.')
