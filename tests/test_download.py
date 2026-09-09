import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import download_model as download

class DownloadChecks(unittest.TestCase):
    def run_fixture(self, callback, size=12):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); model = root/'models/model'
            info = SimpleNamespace(siblings=[SimpleNamespace(rfilename='weights.bin', size=size)])
            with patch.object(download, 'ROOT', root), patch.object(download, 'MODEL', model), \
                 patch('huggingface_hub.HfApi') as api, patch('huggingface_hub.snapshot_download') as fetch, contextlib.redirect_stdout(io.StringIO()):
                api.return_value.model_info.return_value = info
                callback(model, fetch)

    def test_explicit_download_and_deleted_model_can_download_again(self):
        def check(model, fetch):
            def write(*args, **kwargs):
                self.assertEqual(kwargs['revision'], download.REVISION)
                self.assertEqual(kwargs['local_dir'], model)
                model.mkdir(parents=True, exist_ok=True)
                (model/'weights.bin').write_bytes(b'x'*12)
            fetch.side_effect = write
            download.main()
            self.assertTrue((model/'download.json').exists())
            download.main(); self.assertEqual(fetch.call_count, 1)
            import shutil
            shutil.rmtree(model)
            download.main(); self.assertEqual(fetch.call_count, 2)
        self.run_fixture(check)

    def test_partial_download_never_becomes_ready(self):
        def check(model, fetch):
            def partial(*args, **kwargs):
                model.mkdir(parents=True)
                (model/'weights.bin').write_bytes(b'x')
            fetch.side_effect = partial
            with self.assertRaisesRegex(RuntimeError, 'verification'): download.main()
            self.assertFalse((model/'download.json').exists())
        self.run_fixture(check)

    def test_budget_checked_before_download(self):
        def check(model, fetch):
            with self.assertRaisesRegex(RuntimeError, '3 GB'): download.main()
            fetch.assert_not_called()
        self.run_fixture(check, 3_000_000_001)

if __name__ == '__main__': unittest.main()
