"""Run only generated catalog/queue fixtures and close their own child window."""
import ctypes
from ctypes import wintypes as w
import json
from pathlib import Path
import sqlite3
import subprocess
import time

root = Path(__file__).resolve().parent.parent
exe = (root / 'app/build/windows/x64/runner/Release/ownsemble.exe').resolve()
started = time.time()
parent = subprocess.Popen([str(exe), '--smoke-test'], cwd=root,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(json.dumps({'fixture_pid': parent.pid}), flush=True)
parent_code = parent.wait(timeout=45)
report_file = root / '.local/ownsemble-smoke/smoke.json'
deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    if report_file.is_file() and report_file.stat().st_mtime > started:
        report = json.loads(report_file.read_text(encoding='utf-8'))
        if report.get('resumed') is True:
            break
    time.sleep(.2)
else:
    raise SystemExit('Generated cold-restart report did not arrive.')

# Identify only the known fixture's own direct child, with no command-line,
# browser, profile, title, field, or credential inspection.
k = ctypes.WinDLL('kernel32', use_last_error=True)
k.CreateToolhelp32Snapshot.restype = w.HANDLE
k.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
k.OpenProcess.restype = w.HANDLE
k.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
k.CloseHandle.argtypes = [w.HANDLE]
k.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)]
k.WaitForSingleObject.argtypes = [w.HANDLE, w.DWORD]
k.GetExitCodeProcess.argtypes = [w.HANDLE, ctypes.POINTER(w.DWORD)]

class Entry(ctypes.Structure):
    _fields_ = [('dwSize', w.DWORD), ('cntUsage', w.DWORD),
                ('th32ProcessID', w.DWORD), ('th32DefaultHeapID', ctypes.c_size_t),
                ('th32ModuleID', w.DWORD), ('cntThreads', w.DWORD),
                ('th32ParentProcessID', w.DWORD), ('pcPriClassBase', w.LONG),
                ('dwFlags', w.DWORD), ('szExeFile', w.WCHAR * 260)]

k.Process32FirstW.argtypes = [w.HANDLE, ctypes.POINTER(Entry)]
k.Process32NextW.argtypes = [w.HANDLE, ctypes.POINTER(Entry)]
snapshot = k.CreateToolhelp32Snapshot(2, 0)
entry = Entry()
entry.dwSize = ctypes.sizeof(entry)
children = []
try:
    more = k.Process32FirstW(snapshot, ctypes.byref(entry))
    while more:
        if (entry.th32ParentProcessID == parent.pid and
                entry.szExeFile.lower() == 'ownsemble.exe'):
            children.append(entry.th32ProcessID)
        more = k.Process32NextW(snapshot, ctypes.byref(entry))
finally:
    k.CloseHandle(snapshot)
if len(children) != 1:
    raise SystemExit('Could not uniquely identify the generated restart child.')
child = children[0]
handle = k.OpenProcess(0x1000 | 0x100000, False, child)
if not handle:
    raise SystemExit('Could not observe generated child cleanup.')
try:
    path = ctypes.create_unicode_buffer(32768)
    size = w.DWORD(len(path))
    assert k.QueryFullProcessImageNameW(handle, 0, path, ctypes.byref(size))
    assert Path(path.value).resolve() == exe
    u = ctypes.WinDLL('user32')
    u.GetWindowThreadProcessId.argtypes = [w.HWND, ctypes.POINTER(w.DWORD)]
    u.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, ctypes.c_int]
    u.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]

    @ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    def close_fixture(hwnd, _):
        owner = w.DWORD()
        u.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == child:
            name = ctypes.create_unicode_buffer(256)
            u.GetClassNameW(hwnd, name, 256)
            if name.value == 'FLUTTER_RUNNER_WIN32_WINDOW':
                u.PostMessageW(hwnd, 0x10, 0, 0)
        return True

    u.EnumWindows(close_fixture, 0)
    assert k.WaitForSingleObject(handle, 15000) == 0
    child_code = w.DWORD()
    assert k.GetExitCodeProcess(handle, ctypes.byref(child_code))
finally:
    k.CloseHandle(handle)
db_path = (root / '.local/ownsemble-smoke/library.sqlite').resolve()
with sqlite3.connect(db_path.as_uri() + '?mode=ro', uri=True) as db:
    integrity = db.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
    count = db.execute('SELECT COUNT(*) FROM tracks').fetchone()[0]
result = {'parent_exit': parent_code, 'child_exit': child_code.value,
          'passed': report.get('passed') is True and integrity and
                    count == 1200 and parent_code == 0 and child_code.value == 0,
          'sqlite_quick_check': integrity, 'rows': count, 'resumed': True}
(root / '.local/ownsemble-smoke/native-run.json').write_text(
    json.dumps(result), encoding='utf-8')
print(json.dumps(result), flush=True)
if not result['passed']:
    raise SystemExit(1)
