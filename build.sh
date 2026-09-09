#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build
export ORCAUDIO_PORTABLE="${1:-}"
export ORCAUDIO_OUTPUT="dist/Orcaudio.app"
if [[ "$ORCAUDIO_PORTABLE" == "--portable" ]]; then
    export ORCAUDIO_OUTPUT="release/Orcaudio.app"
fi
xcrun swiftc -O Helpers/OrcaWatcher.swift -o build/OrcaWatcher
codesign --force --sign - build/OrcaWatcher
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/*.swift -o build/Orcaudio
.venv/bin/python - <<'PY'
import plistlib
import os
from pathlib import Path
import shutil
root = Path.cwd()
app = root / os.environ['ORCAUDIO_OUTPUT']
(app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
binary = app/'Contents/MacOS/Orcaudio'
shutil.copy2(root/'build/Orcaudio', binary.with_suffix('.new'))
binary.with_suffix('.new').replace(binary)
info = {'CFBundleName':'Orcaudio', 'CFBundleDisplayName':'Orcaudio',
        'CFBundleIdentifier':'local.stellacheng.orca-dictation', 'CFBundleExecutable':'Orcaudio',
        'CFBundleIconFile':'AppIcon.icns', 'CFBundlePackageType':'APPL', 'CFBundleVersion':'1', 'CFBundleShortVersionString':os.environ.get('ORCAUDIO_VERSION', '0.3.0'),
        'LSMinimumSystemVersion':'14.0', 'LSUIElement':True, 'LSArchitecturePriority':['arm64'], 'LSRequiresNativeExecution':True,
        'CFBundleDevelopmentRegion':'en', 'CFBundleLocalizations':['en', 'zh-Hant'],
        'NSMicrophoneUsageDescription':'Record speech for on-device Cantonese and English dictation. Audio is deleted after processing.',
        'NSHighResolutionCapable':True, 'DictationProjectRoot':str(root)}
resources = app/'Contents/Resources'
resources.mkdir(exist_ok=True)
for name in ('AppIcon.icns', 'MenuBarTemplate.png', 'MenuBarTemplate@2x.png'):
    shutil.copy2(root/'Assets'/name, resources/name)
shutil.copy2(root/'build/OrcaWatcher', resources/'OrcaWatcher')
if os.environ.get('ORCAUDIO_PORTABLE') == '--portable':
    import subprocess
    info.pop('DictationProjectRoot', None)
    runtime = resources/'Runtime'
    if runtime.exists(): shutil.rmtree(runtime)
    base = Path(subprocess.check_output([str(root/'.venv/bin/python'), '-c', 'import sys; print(sys.base_prefix)'], text=True).strip())
    shutil.copytree(base, runtime, symlinks=True, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    site = runtime/'lib/python3.11/site-packages'
    shutil.copytree(root/'.venv/lib/python3.11/site-packages', site, dirs_exist_ok=True, symlinks=True, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    # No venv launcher or developer paths: bundled standalone Python uses its own prefix.
    scripts = resources/'Scripts'; scripts.mkdir(exist_ok=True)
    for name in ('worker.py', 'asr.py', 'download_model.py'):
        shutil.copy2(root/name, scripts/name)
    # Sign nested Mach-O libraries and executables before the outer bundle.
    for path in runtime.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as source: magic = source.read(4)
            if magic in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf'):
                subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
else:
    for name in ('Runtime', 'Scripts'):
        if (resources/name).exists(): shutil.rmtree(resources/name)
with (app/'Contents/Info.plist').open('wb') as f: plistlib.dump(info, f)
PY
codesign --force --sign - --identifier local.stellacheng.orca-dictation "$ORCAUDIO_OUTPUT"
codesign --verify --strict --verbose=2 "$ORCAUDIO_OUTPUT"
touch "$ORCAUDIO_OUTPUT"
print "Built: $ORCAUDIO_OUTPUT"
