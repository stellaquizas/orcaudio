"""On-device speech recognition shared by the Orcaudio worker and regression tests."""
import math
import os
from pathlib import Path
import resource
import sys
import time

ROOT = Path(os.environ.get('ORCAUDIO_DATA_ROOT', Path(__file__).resolve().parent))
MODEL = ROOT / 'models' / 'Qwen3-ASR-1.7B-8bit'
os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1',
                  HF_HOME=str(ROOT / '.hf'), TOKENIZERS_PARALLELISM='false')
os.umask(0o077)


def load_model():
    if not (MODEL / 'download.json').exists():
        raise RuntimeError('Model missing/incomplete. Download a model in Orcaudio Settings; no automatic download.')
    start = time.perf_counter()
    from mlx_audio.stt import load
    import mlx.core as mx
    print('Loading local model…', file=sys.stderr)
    model = load(str(MODEL))
    mx.eval(model.parameters())
    elapsed = time.perf_counter() - start
    print(f'Load (including imports): {elapsed:.2f}s', file=sys.stderr)
    return model, elapsed


def audio(path):
    import numpy as np
    from scipy.io import wavfile
    from scipy.signal import resample_poly
    sr, data = wavfile.read(path)
    if data.dtype.kind == 'i':
        data = data.astype(np.float32) / (2 ** (data.dtype.itemsize * 8 - 1))
    elif data.dtype == np.uint8:
        data = (data.astype(np.float32) - 128) / 128
    else:
        data = data.astype(np.float32)
    if data.ndim == 2:
        data = data.mean(axis=1)
    if not 1 <= len(data) / sr <= 120:
        raise ValueError('Recording must be 1–120 seconds')
    if not np.isfinite(data).all():
        raise ValueError('Invalid audio samples')
    if sr != 16000:
        gcd = math.gcd(sr, 16000)
        data = resample_poly(data, 16000 // gcd, sr // gcd)
    if float(np.sqrt(np.mean(data ** 2))) < 0.001:
        raise ValueError('Silence / signal too quiet; no transcription')
    return data


def transcribe(model, path, language):
    start = time.perf_counter()
    import mlx.core as mx
    from opencc import OpenCC
    samples = audio(path)
    mx.reset_peak_memory()
    result = model.generate(samples, language=None if language == 'auto' else 'Cantonese',
                            max_tokens=2048, verbose=False)
    mx.synchronize()
    raw = result.text.strip()
    if not raw:
        raise ValueError('Empty recognition result')
    if result.generation_tokens >= 2048:
        raise ValueError('Token limit reached; possible incomplete transcript')
    text = OpenCC('s2t').convert(raw)
    return {'raw': raw, 'text': text, 'language': language, 'seconds': time.perf_counter() - start,
            'audio_seconds': len(samples) / 16000,
            'rss_peak_bytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            'mlx_peak_bytes': mx.get_peak_memory()}
