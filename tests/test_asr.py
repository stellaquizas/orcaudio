import tempfile
import unittest
from pathlib import Path
import numpy as np
from scipy.io import wavfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from asr import audio

class AudioTests(unittest.TestCase):
    def test_silence_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'silence.wav'
            wavfile.write(p, 16000, np.zeros(32000, dtype=np.int16))
            with self.assertRaisesRegex(ValueError, 'Silence'):
                audio(p)

    def test_int16_scaling_and_resampling(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'sound.wav'
            x = (np.sin(np.arange(48000) * 2 * np.pi * 440 / 48000) * 16384).astype(np.int16)
            wavfile.write(p, 48000, x)
            y = audio(p)
            self.assertEqual(len(y), 16000)
            self.assertAlmostEqual(float(np.sqrt(np.mean(y*y))), 0.3535, places=2)

if __name__ == '__main__': unittest.main()
