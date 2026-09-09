#!/usr/bin/env python3
"""Local JSON-lines worker. stdout is protocol only; no transcript persistence."""
import contextlib
import json
import sys
import threading
import gc
from pathlib import Path
import asr


protocol_output = sys.stdout
output_lock = threading.Lock()

def emit(**payload):
    with output_lock:
        protocol_output.write(json.dumps(payload, ensure_ascii=False) + '\n')
        protocol_output.flush()


def main():
    model = None
    memory_ready = threading.Event()
    def memory_samples():
        memory_ready.wait()
        import mlx.core as mx
        while True:
            emit(type='metrics', active_bytes=mx.get_active_memory(), cache_bytes=mx.get_cache_memory())
            threading.Event().wait(1.0)
    threading.Thread(target=memory_samples, daemon=True).start()
    emit(type='ready')
    for line in sys.stdin:
        request = {}
        try:
            request = json.loads(line)
            ident = request.get('id', '')
            op = request['op']
            if op == 'shutdown':
                return
            if op not in ('load', 'transcribe'):
                raise ValueError('Unsupported operation')
            if model is None:
                emit(type='status', id=ident, state='loading')
                with contextlib.redirect_stdout(sys.stderr):
                    import mlx.core as mx
                    mx.set_cache_limit(128 * 1024 * 1024)
                    model, elapsed = asr.load_model()
                    mx.clear_cache()
                memory_ready.set()
                emit(type='status', id=ident, state='loaded', load_seconds=elapsed)
            if op == 'transcribe':
                language = request.get('language', 'auto')
                if language not in ('auto', 'Cantonese'):
                    raise ValueError('Unsupported language')
                emit(type='status', id=ident, state='transcribing')
                with contextlib.redirect_stdout(sys.stderr):
                    result = asr.transcribe(model, Path(request['path']), language)
                gc.collect()
                mx.clear_cache()
                emit(type='result', id=ident, text=result['text'], seconds=result['seconds'])
                del result
        except Exception as exc:
            emit(type='error', id=request.get('id', '') if isinstance(request, dict) else '', code=getattr(exc, 'code', 'worker_failure'))


if __name__ == '__main__':
    main()
