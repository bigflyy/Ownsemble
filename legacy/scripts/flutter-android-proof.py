"""Drive only Ownsemble's test APK through an already authorized local ADB server.

No browser-profile, account, cookie, token, input-field or screenshot access.
The sole app file read is the probe's deliberately sanitized public report.
"""
import json
from pathlib import Path
import socket
import struct
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = 'com.ownsemble.ownsemble_flutter_proof'
ACTIVITY = PACKAGE + '/.MainActivity'


def exact(connection, size):
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise RuntimeError('adb_connection_closed')
        data.extend(chunk)
    return bytes(data)


def request(connection, service):
    data = service.encode()
    connection.sendall(f'{len(data):04x}'.encode() + data)
    if exact(connection, 4) != b'OKAY':
        raise RuntimeError('adb_service_failed')


def devices():
    with socket.create_connection(('127.0.0.1', 5037), 5) as connection:
        request(connection, 'host:devices')
        text = exact(connection, int(exact(connection, 4), 16)).decode()
    return [line.split('\t') for line in text.splitlines() if '\t' in line]


def device_connection():
    available = [serial for serial, state in devices() if state == 'device']
    if 'emulator-5570' not in available:
        raise RuntimeError('ownsemble_test_emulator_required')
    available = ['emulator-5570']
    connection = socket.create_connection(('127.0.0.1', 5037), 5)
    request(connection, 'host:transport:' + available[0])
    return connection


def shell(command):
    with device_connection() as connection:
        request(connection, 'shell:' + command)
        connection.settimeout(120)
        result = bytearray()
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                return result.decode(errors='replace')
            result.extend(chunk)
            if len(result) > 2 * 1024 * 1024:
                raise RuntimeError('adb_output_budget')


def read_public(name):
    assert name in ('status', 'evidence')
    text = shell(f'run-as {PACKAGE} cat files/proof-public/{name}.json')
    try:
        data = json.loads(text)
    except ValueError:
        raise RuntimeError('android_public_report_not_ready') from None
    allowed = {'at', 'event', 'count', 'bytes', 'duration', 'passed', 'phase', 'category',
               'rows', 'candidates', 'offline', 'native_trusted', 'platform', 'requests',
               'complete', 'stage', 'codec', 'attempt', 'updatedAt', 'kind', 'code'}
    if name == 'status':
        return {key: value for key, value in data.items() if key in allowed}
    return [{key: value for key, value in event.items() if key in allowed}
            for event in data.get('events', [])[-16:]]


def install():
    apk = ROOT / 'spikes/vk-flutter/build/app/outputs/flutter-apk/app-debug.apk'
    if not apk.is_file():
        raise RuntimeError('android_apk_missing')
    with device_connection() as connection:
        request(connection, 'sync:')
        destination = b'/data/local/tmp/ownsemble-flutter-proof.apk,33188'
        connection.sendall(b'SEND' + struct.pack('<I', len(destination)) + destination)
        with apk.open('rb') as source:
            while chunk := source.read(65536):
                connection.sendall(b'DATA' + struct.pack('<I', len(chunk)) + chunk)
        connection.sendall(b'DONE' + struct.pack('<I', int(time.time())))
        if exact(connection, 4) != b'OKAY':
            raise RuntimeError('android_apk_push_failed')
        exact(connection, 4)
    result = shell('pm install -r -t /data/local/tmp/ownsemble-flutter-proof.apk')
    if 'Success' not in result:
        raise RuntimeError('android_install_failed_or_user_restricted')
    shell('rm /data/local/tmp/ownsemble-flutter-proof.apk')
    print('Installed only the new Ownsemble Flutter test app.')


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if command == 'devices':
        print(json.dumps([{'device': serial, 'state': state} for serial, state in devices()]))
    elif command == 'install':
        install()
    elif command == 'start':
        shell('am start -n ' + ACTIVITY)
        print('Ownsemble Flutter probe launched.')
    elif command == 'fresh-start':
        # Reset only this synthetic probe's public test checkpoint, never data
        # belonging to WebView, accounts, profiles or another application.
        shell('am force-stop ' + PACKAGE)
        shell(f'run-as {PACKAGE} mkdir -p files/proof-public')
        for name, value in (
            ('resume', {'phase': 'finished'}),
            ('status', {'stage': 'fresh_start_pending', 'passed': False, 'platform': 'android'}),
        ):
            literal = json.dumps(value, separators=(',', ':')).replace('"', '\\"')
            shell(f'''run-as {PACKAGE} sh -c 'printf "%s" "{literal}" > files/proof-public/{name}.json' ''')
        shell('am start -n ' + ACTIVITY)
        print('Fresh synthetic probe launched; only its public checkpoint was reset.')
    elif command == 'offline-restart':
        if read_public('status').get('stage') != 'offline_restart_pending':
            raise RuntimeError('offline_restart_not_ready')
        shell('am force-stop ' + PACKAGE)
        shell('am start -n ' + ACTIVITY)
        print('Restarted only the test app for local offline verification.')
    elif command == 'wait':
        deadline = time.monotonic() + 360
        restarted = False
        while time.monotonic() < deadline:
            try:
                state = read_public('status')
            except RuntimeError:
                time.sleep(2)
                continue
            if state.get('stage') == 'offline_restart_pending' and not restarted:
                shell('am force-stop ' + PACKAGE)
                shell('am start -n ' + ACTIVITY)
                restarted = True
            if state.get('stage') in ('failed', 'technical_checks_finished'):
                report = {'status': state, 'events': read_public('evidence')}
                destination = ROOT / '.local/flutter-proof/android-evidence.json'
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(json.dumps(report, indent=2))
                print(json.dumps(state))
                return
            time.sleep(2)
        raise RuntimeError('android_automation_timeout')
    elif command in ('status', 'evidence'):
        print(json.dumps(read_public(command), indent=2))
    else:
        raise RuntimeError('unsupported_android_proof_command')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Fixed local categories only, never raw device/plugin output.
        category = str(error)
        if not category.replace('_', '').isalnum() or len(category) > 100:
            category = 'android_proof_tool_failed'
        print(json.dumps({'category': category}))
        raise SystemExit(1)
