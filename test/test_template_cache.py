"""Published templates must not reuse a newer checkout's compiler ABI."""
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class TemplateCacheTests(unittest.TestCase):
    def test_shared_libevent_does_not_force_an_incompatible_compiler(self):
        spec = importlib.util.spec_from_file_location('template_tasks', ROOT / 'templates/proven-api/tasks.py')
        tasks = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tasks)
        for digest, compatible in (('published-compiler', True), ('newer-compiler', False)):
            with self.subTest(digest=digest), tempfile.TemporaryDirectory(prefix='stiff-template-cache-') as temporary:
                directory = Path(temporary)
                dependency = directory / 'dependency'
                scripts = dependency / 'scripts'
                scripts.mkdir(parents=True)
                (scripts / 'setup-libevent.py').write_text('MANIFEST = {}\n')
                (scripts / 'setup.py').write_text('DIGESTS = {"fixture": "published-compiler"}\n')
                cache = directory / 'shared'
                (cache / 'libevent').mkdir(parents=True)
                (cache / 'libevent/.stiff-pin.json').write_text('{}')
                (cache / 'toolchain').mkdir()
                (cache / 'toolchain/.archive-sha256').write_text(digest)
                with patch.object(tasks, 'DEPENDENCY', dependency), \
                     patch.object(tasks, 'ENV', {'STIFF_CACHE': str(cache)}), \
                     patch.object(tasks, 'dependency'), \
                     patch.object(tasks, 'run', return_value=SimpleNamespace(returncode=0, stdout='', stderr='')) as run:
                    tasks.setup()
                self.assertEqual((dependency / '.cache/libevent').resolve(), (cache / 'libevent').resolve())
                self.assertEqual((dependency / '.cache/toolchain').is_symlink(), compatible)
                run.assert_called_once_with([tasks.sys.executable, dependency / 'scripts/setup.py'])
