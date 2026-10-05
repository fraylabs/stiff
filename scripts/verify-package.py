#!/usr/bin/env python3
"""Verify an exact release archive's provenance and native application journeys."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    archive = args.archive.resolve()
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    sys.path[:0] = [str(ROOT), str(ROOT / 'test')]
    from test_package import PackageTests
    from test_notes import NotesTests
    os.environ['STIFF_PACKAGE_ARCHIVE'] = str(archive)
    with tempfile.TemporaryDirectory(prefix='stiff-release-verification-') as temporary:
        with tarfile.open(archive) as bundle:
            bundle.extractall(Path(temporary), filter='data')
        stage, = Path(temporary).iterdir()
        manifest = json.loads((stage / 'manifest.json').read_text())
        assert manifest['revision'] == revision, 'archive revision differs from checkout'
        assert manifest['version'] == (ROOT / 'VERSION').read_text().strip()
        assert manifest['platform'] == platform.system().lower() + '-' + platform.machine()
        assert manifest['dirty'] is False, 'release archive came from a dirty tree'

        class PackagedNotesTests(NotesTests):
            @classmethod
            def setUpClass(cls):
                cls.binary = stage / 'notes'

        suite = unittest.TestSuite([
            PackageTests('test_archive_checksums_and_native_journey'),
            unittest.defaultTestLoader.loadTestsFromTestCase(PackagedNotesTests),
        ])
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        if not result.wasSuccessful():
            raise SystemExit('release archive verification failed')
        evidence = {
            'archive': archive.name,
            'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
            'manifest': manifest,
            'checksums': True,
            'outside_checkout': True,
            'no_build_tools_on_path': True,
            'supervised_app_health': True,
            'create_read_restart': True,
            'persistent_application_tests': result.testsRun - 1,
            'exact_archive_tested': True,
        }
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(json.dumps(evidence, indent=2) + '\n')
        print(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    main()
