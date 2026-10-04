"""Candidate integrity policy; no network or compiler installation required."""
import contextlib
import importlib.util
import io
import json
import hashlib
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('stiff_setup', Path(__file__).resolve().parents[1] / 'scripts/setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class CandidateIntegrityTests(unittest.TestCase):
    def metadata(self, *, digest=None, checksum=None):
        name = 'bend-2.0.99-darwin-arm64.tar.gz'
        release = {'html_url': 'https://github.com/bendlang/bend/releases/tag/v2.0.99',
                   'target_commitish': 'source-sha', 'assets': [
                       {'name': name, 'browser_download_url': 'https://example.invalid/archive', 'digest': digest}]}
        replies = [io.BytesIO(json.dumps(release).encode())]
        if checksum is not None:
            release['assets'].append({'name': 'SHA256SUMS', 'browser_download_url': 'https://example.invalid/checksums'})
            replies = [io.BytesIO(json.dumps(release).encode()), io.BytesIO(checksum.encode())]
        with patch.object(setup.urllib.request, 'urlopen', side_effect=replies):
            return setup.release_metadata('2.0.99', 'darwin-arm64')

    def test_release_checksum_takes_precedence(self):
        _, digest, metadata = self.metadata(digest='sha256:' + 'b' * 64,
            checksum='a' * 64 + '  bend-2.0.99-darwin-arm64.tar.gz\n')
        self.assertEqual(digest, 'a' * 64)
        self.assertEqual(metadata['integrity'], 'release-checksum-asset')

    def test_github_digest(self):
        _, digest, metadata = self.metadata(digest='sha256:' + 'b' * 64)
        self.assertEqual(digest, 'b' * 64)
        self.assertEqual(metadata['integrity'], 'github-release-asset-digest')

    def test_missing_checksum_is_loud_and_recorded(self):
        warning = io.StringIO()
        with contextlib.redirect_stderr(warning):
            _, digest, metadata = self.metadata()
        self.assertIsNone(digest)
        self.assertEqual(metadata['integrity'], 'unpinned')
        self.assertIn('WARNING: UNPINNED Bend 2.0.99', warning.getvalue())

    def test_invalid_published_checksum_never_falls_back(self):
        with self.assertRaisesRegex(RuntimeError, 'No valid checksum'):
            self.metadata(checksum='not a checksum', digest='sha256:' + 'b' * 64)

    def test_unknown_digest_format_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Unexpected release digest'):
            self.metadata(digest='md5:' + 'b' * 32)

    def install_candidate(self, directory, digest):
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w:gz') as bundle:
            content = b'compiler executable fixture'
            member = tarfile.TarInfo('release/bin/bend')
            member.size = len(content)
            member.mode = 0o755
            bundle.addfile(member, io.BytesIO(content))
        data = archive.getvalue()
        cache = Path(directory) / '.cache'
        destination = cache / 'toolchain'
        with contextlib.ExitStack() as stack:
            for name, value in [('ROOT', Path(directory)), ('CACHE', cache), ('DESTINATION', destination)]:
                stack.enter_context(patch.object(setup, name, value))
            stack.enter_context(patch.object(sys, 'argv', ['setup.py', '--release-tracking-version', '2.0.99']))
            stack.enter_context(patch.object(setup.platform, 'machine', return_value='arm64'))
            stack.enter_context(patch.object(setup.platform, 'system', return_value='Darwin'))
            stack.enter_context(patch.object(setup.shutil, 'which', return_value='/fixture/tool'))
            stack.enter_context(patch.object(setup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)))
            stack.enter_context(patch.object(setup, 'verify'))
            stack.enter_context(patch.object(setup, 'release_metadata', return_value=(
                'https://example.invalid/archive', digest, {'integrity': 'unpinned' if digest is None else 'release-checksum-asset'})))
            stack.enter_context(patch.object(setup.urllib.request, 'urlopen', return_value=io.BytesIO(data)))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            setup.main()
        return destination, hashlib.sha256(data).hexdigest()

    def test_unpinned_download_records_actual_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            destination, actual = self.install_candidate(directory, None)
            self.assertEqual((destination / '.archive-sha256').read_text().strip(), actual)
            metadata = json.loads((destination / '.release-metadata.json').read_text())
            self.assertEqual(metadata, {'integrity': 'unpinned', 'archive_sha256': actual})

    def test_archive_mismatch_never_installs(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, 'Bend archive checksum mismatch'):
                self.install_candidate(directory, '0' * 64)
            self.assertFalse((Path(directory) / '.cache/toolchain').exists())
