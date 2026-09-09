"""Explicit, resumable model download. No imports or inference of MLX required."""
import json
import os
from pathlib import Path
import sys
import threading
import time

os.environ['HF_HUB_OFFLINE'] = '0'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
os.environ['HF_HUB_DISABLE_XET'] = '1'
os.umask(0o077)
ROOT = Path(os.environ.get('ORCAUDIO_DATA_ROOT', Path(__file__).resolve().parent))
MODEL = ROOT / 'models' / 'Qwen3-ASR-1.7B-8bit'
REPO = 'mlx-community/Qwen3-ASR-1.7B-8bit'
REVISION = 'a8379a2e2f9e313c9292cdf1af4055ab56d50d55'


def emit(**message):
    print(json.dumps(message), flush=True)


def main():
    from filelock import FileLock
    from huggingface_hub import HfApi, snapshot_download
    ROOT.mkdir(parents=True, exist_ok=True)
    with FileLock(str(ROOT / 'model-download.lock'), timeout=0):
        if (MODEL / 'download.json').exists():
            emit(type='complete')
            return
        emit(type='status', state='connecting')
        info = HfApi().model_info(REPO, revision=REVISION, files_metadata=True, token=False)
        total = sum(f.size or 0 for f in info.siblings)
        if not 0 < total <= 3_000_000_000:
            raise RuntimeError('Model exceeds the 3 GB limit or has no size information.')
        finished = threading.Event()
        def progress():
            while not finished.wait(0.5):
                try:
                    done = sum(p.stat().st_size for p in MODEL.rglob('*') if p.is_file() and
                               ('.cache' not in p.parts or p.name.endswith('.incomplete')))
                    emit(type='progress', received=min(done, total), total=total)
                except OSError:
                    pass
        thread = threading.Thread(target=progress, daemon=True); thread.start()
        try:
            snapshot_download(REPO, revision=REVISION, local_dir=MODEL, token=False)
            for entry in info.siblings:
                path = MODEL / entry.rfilename
                if not path.is_file() or entry.size is None or path.stat().st_size != entry.size:
                    raise RuntimeError('Downloaded model failed file-size verification.')
            marker = MODEL / 'download.json.tmp'
            marker.write_text(json.dumps({'repo': REPO, 'revision': REVISION, 'remote_bytes': total}))
            marker.replace(MODEL / 'download.json')
        finally:
            finished.set(); thread.join()
        emit(type='complete')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        emit(type='error', message=str(error))
        sys.exit(1)
