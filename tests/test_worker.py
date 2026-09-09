import json
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import unittest
import numpy as np
from scipy.io import wavfile

ROOT = Path(__file__).resolve().parents[1]

class WorkerIntegration(unittest.TestCase):
    def test_offline_protocol_reuse_error_and_shutdown(self):
        p = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)',
                              sys.executable, '-u', str(ROOT/'worker.py')],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, bufsize=1)
        metrics = []
        def receive():
            # readline is protected by the subprocess test's outer watchdog below.
            line = p.stdout.readline()
            self.assertTrue(line, 'Worker exited unexpectedly')
            message = json.loads(line)
            while message.get('type') == 'metrics':
                metrics.append(message)
                line = p.stdout.readline(); self.assertTrue(line)
                message = json.loads(line)
            return message
        def send(**request):
            p.stdin.write(json.dumps(request)+'\n'); p.stdin.flush()
        try:
            self.assertEqual(receive()['type'], 'ready')
            send(op='bogus', id='invalid')
            self.assertEqual(receive()['type'], 'error')
            send(op='load', id='warm')
            self.assertEqual(receive()['state'], 'loading')
            self.assertEqual(receive()['state'], 'loaded')
            with tempfile.TemporaryDirectory() as fixture:
                source = Path(fixture)/'speech.wav'
                subprocess.run(['/usr/bin/say', '-v', 'Samantha', '-o', str(source),
                                '--file-format=WAVE', '--data-format=LEI16@16000',
                                'Do not deploy this change.'], check=True)
                for i in range(2):
                    send(op='transcribe', id=str(i), path=str(source), language='auto')
                    self.assertEqual(receive()['state'], 'transcribing') # no second load
                    result = receive()
                    self.assertEqual(result['type'], 'result')
                    self.assertEqual(result['id'], str(i))
                    self.assertIn('not deploy', result['text'].lower())
            with tempfile.TemporaryDirectory() as folder:
                silence = Path(folder)/'silence.wav'
                wavfile.write(silence,16000,np.zeros(32000,dtype=np.int16))
                send(op='transcribe', id='silence', path=str(silence))
                self.assertEqual(receive()['state'], 'transcribing')
                failure = receive()
                self.assertEqual(failure['type'], 'error')
                self.assertEqual(failure['code'], 'silence')
            self.assertTrue(metrics, 'Worker must report actual memory')
            self.assertTrue(all(m['active_bytes'] >= 0 and m['cache_bytes'] >= 0 for m in metrics))
            print('MLX memory samples:', metrics[-2:])
            send(op='shutdown')
            self.assertEqual(p.wait(timeout=5),0)
        finally:
            if p.poll() is None: p.kill(); p.wait()
            p.stdin.close(); p.stdout.close()

if __name__ == '__main__':
    import signal
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError('Worker test timeout')))
    signal.alarm(90)
    unittest.main()
