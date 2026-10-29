"""Run only generated loopback fixtures against the isolated compiled CEF helper."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
from fixture import Fixture


def kill_fixture_processes(executable, proc_root=Path('/proc')):
    target = executable.resolve()
    for directory in proc_root.iterdir():
        if not directory.name.isdigit():
            continue
        try:
            if directory.stat().st_uid == os.getuid() and (directory / 'exe').resolve(strict=True) == target:
                os.kill(int(directory.name), signal.SIGKILL)
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass


def run(output, native_window=False):
    subprocess.run(['bash', str(Path(__file__).with_name('build-cef.sh'))],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    root = Path(os.environ.get('OWNSEMBLE_LINUX_PROOF_ROOT', '/opt/ownsemble-linux-proof'))
    selected = json.loads((root / 'cef-probe/selected.json').read_text())
    sdk = Path(selected['directory'])
    executable = root / 'cef-probe/build/ownsemble_cef_probe'
    # This newly generated session is engine-owned. Never inspect its files.
    state = Path(tempfile.mkdtemp(prefix='ownsemble-generated-cef-session-'))
    native_report = output.with_suffix('.native.json')
    native_log = output.with_suffix('.native.log')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    environment = dict(os.environ)
    environment['LD_LIBRARY_PATH'] = str(executable.parent)
    process = None
    category = None
    try:
        process = subprocess.Popen([str(executable), f'http://127.0.0.1:{server.server_port}',
            str(native_report), str(sdk / 'Resources'), str(state), str(native_log)] + (['--native-window'] if native_window else []),
            cwd=executable.parent, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=40)
        except subprocess.TimeoutExpired:
            kill_fixture_processes(executable)
            stdout, stderr = process.communicate(timeout=5)
            category = 'native_timeout'
        if process.returncode and category is None:
            category = 'native_exit_' + str(process.returncode)
        if category is not None:
            # Diagnostics contain generated fixtures only, never an account page.
            print(stderr[-1600:])
        report = json.loads(native_report.read_text()) if native_report.exists() else {'checks': {}}
        report.update(engine='CEF', version=selected['version'], fixture_only=True,
                      fixture_network_asset_requests=Fixture.asset_requests,
                      fixture_network_audio_requests=Fixture.audio_requests,
                      sandbox_requested=True, error_category=category or report.get('error_category'),
                      native_lifecycle=re.findall(r'probe:[a-z_]+[0-9]*', stderr))
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + '\n')
        return 1 if report.get('error_category') else 0
    finally:
        server.shutdown()
        server.server_close()
        worker.join(3)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--native-window', action='store_true')
    args = parser.parse_args()
    raise SystemExit(run(args.output.resolve(), args.native_window))
