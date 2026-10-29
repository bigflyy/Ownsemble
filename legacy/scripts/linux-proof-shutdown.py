"""Generated streaming smoke must publish its report and close its own window."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('workspace', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--mode', choices=('streaming', 'window'), default='streaming')
parser.add_argument('--build-mode', choices=('debug', 'release'), default='debug')
args = parser.parse_args()
root = args.workspace.resolve()
binary = root / f'app/build/linux/x64/{args.build_mode}/bundle/ownsemble'
report = root / '.local/ownsemble-streaming-smoke/streaming-smoke.json'
args.output.mkdir(parents=True, exist_ok=True)
started = time.time()
with (args.output / 'streaming-console.log').open('w') as log:
    flags = ['--streaming-smoke'] if args.mode == 'streaming' else ['--demo', '--lifecycle-smoke']
    process = subprocess.Popen([str(binary), *flags], cwd=root,
                               stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    try:
        process.wait(timeout=40 if args.mode == 'streaming' else 12)
        closed = True
    except subprocess.TimeoutExpired:
        closed = False
        process.terminate()
        process.wait(timeout=5)
result = {'closed': closed, 'exit_code': process.returncode, 'fresh_report': False}
if args.mode == 'streaming' and report.exists() and report.stat().st_mtime >= started:
    result['fresh_report'] = True
    result['streaming'] = json.loads(report.read_text())
result['shutdown_acknowledged'] = 'shutdown_acknowledged' in (args.output / 'streaming-console.log').read_text()
result['passed'] = closed and process.returncode == 0 and (result.get('streaming', {}).get('passed') is True if args.mode == 'streaming' else result['shutdown_acknowledged'])
(args.output / 'shutdown-check.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result))
raise SystemExit(0 if result['passed'] else 1)
