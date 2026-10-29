"""Stop only this checkout's own probe before replacing its locked DLLs."""
from pathlib import Path
import argparse
import psutil
parser = argparse.ArgumentParser()
parser.add_argument('--mode', choices=('Debug', 'Release'))
mode = parser.parse_args().mode
root = Path(__file__).resolve().parent.parent
expected = {
    (root / f'spikes/vk-flutter/build/windows/x64/runner/{mode}/ownsemble_flutter_proof.exe').resolve()
    for mode in ((mode,) if mode else ('Debug', 'Release'))
}
for process in psutil.process_iter(['name', 'exe']):
    if process.info['name'] != 'ownsemble_flutter_proof.exe':
        continue
    if Path(process.info['exe']).resolve() not in expected:
        continue
    for child in process.children(recursive=True):
        try:
            child.terminate()
        except psutil.NoSuchProcess:
            pass
    process.terminate()
    try:
        process.wait(5)
    except psutil.NoSuchProcess:
        pass
