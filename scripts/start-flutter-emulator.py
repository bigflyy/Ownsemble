"""Start only the isolated synthetic test AVD, without accounts or a visible window."""
from pathlib import Path
import os
import runpy
import subprocess
import time
root = Path(__file__).resolve().parent.parent
helpers = runpy.run_path(str(root / 'scripts/flutter-android-proof.py'))
if any(serial == 'emulator-5570' for serial, state in helpers['devices']()):
    print('Ownsemble test emulator already exists.')
else:
    env = os.environ.copy()
    sdk = 'C:/Users/User/AppData/Local/Android/Sdk'
    env.update(ANDROID_HOME=sdk, ANDROID_SDK_ROOT=sdk,
        ANDROID_AVD_HOME=str(root / '.local/android-avd'),
        ANDROID_USER_HOME=str(root / '.local/android-user'),
        ANDROID_EMULATOR_HOME=str(root / '.local/android-user'))
    with (root / '.local/flutter-proof/emulator-launch.log').open('w') as log:
        subprocess.Popen([sdk + '/emulator/emulator.exe', '-avd', 'ownsemble_flutter_proof',
            '-port', '5570', '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot',
            '-gpu', 'swiftshader', '-memory', '1536'], env=env, stdout=log, stderr=log,
            creationflags=subprocess.CREATE_NO_WINDOW)
for attempt in range(90):
    if ['emulator-5570', 'device'] in helpers['devices']():
        print('Ownsemble test emulator ready.')
        break
    time.sleep(2)
else:
    raise RuntimeError('ownsemble_emulator_boot_timeout')
