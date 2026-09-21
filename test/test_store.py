"""Compiled Bend/SQLite persistence, restart, crash and idempotency checks."""
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent


class StoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="stiff-store-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.binary = cls.directory / "store-cli"
        result = subprocess.run(
            [str(ROOT / "scripts/build-native.sh"), "test/fixtures/store-cli.bend", str(cls.binary)],
            cwd=ROOT, capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        cls.binary.with_suffix(".c").unlink()

    def setUp(self):
        self.database = self.directory / f"{self._testMethodName}.db"

    def run_store(self, *args, check=True, timeout=15):
        result = subprocess.run(
            [str(self.binary), *map(str, args)], capture_output=True, text=True,
            env={"PATH": "/nonexistent"}, timeout=timeout)
        if check and result.returncode:
            self.fail(f"store failed ({result.returncode}): {result.stdout!r} {result.stderr!r}")
        return result

    def write(self, operation, key, expected, value):
        return self.run_store("write", self.database, operation, key, expected, value)

    def test_compare_write_restarts_and_replays_only_identical_operation(self):
        self.assertEqual(self.write("create-1", "account", 0, "one").stdout, "applied:1\n")
        # Every invocation is a fresh native process and connection.
        self.assertEqual(self.write("create-1", "account", 0, "one").stdout, "replayed:1\n")
        self.assertEqual(
            self.run_store("read", self.database, "account").stdout, "found:1:one\n")
        self.assertEqual(
            self.run_store("operation", self.database, "create-1").stdout,
            "operation-applied:account:1\n")

        changed = self.write("create-1", "account", 0, "different")
        self.assertEqual(changed.stdout, "idempotency-conflict\n")
        self.assertEqual(
            self.run_store("read", self.database, "account").stdout, "found:1:one\n")

        self.assertEqual(self.write("update-2", "account", 1, "two").stdout, "applied:2\n")
        self.assertEqual(self.write("update-2", "account", 1, "two").stdout, "replayed:2\n")
        self.assertEqual(
            self.run_store("read", self.database, "account").stdout, "found:2:two\n")

    def test_conflicts_are_durable_idempotent_outcomes(self):
        self.assertEqual(self.write("seed", "item", 0, "v1").stdout, "applied:1\n")
        self.assertEqual(
            self.write("stale", "item", 0, "ignored").stdout, "conflict:1:v1\n")
        self.assertEqual(
            self.write("stale", "item", 0, "ignored").stdout,
            "replayed-conflict:1:v1\n")
        self.assertEqual(
            self.run_store("operation", self.database, "stale").stdout,
            "operation-conflict:item:1\n")

        self.assertEqual(
            self.write("missing", "absent", 4, "ignored").stdout, "missing-conflict\n")
        self.assertEqual(
            self.write("missing", "absent", 4, "ignored").stdout,
            "replayed-missing-conflict\n")
        self.assertEqual(
            self.run_store("operation", self.database, "missing").stdout,
            "operation-missing-conflict:absent\n")

    def test_compare_write_is_atomic_between_competing_processes(self):
        self.assertEqual(
            self.run_store("operation", self.database, "not-started").stdout,
            "operation-unknown\n")
        commands = [
            [str(self.binary), "write", str(self.database), f"race-{index}", "race", "0", value]
            for index, value in enumerate(("left", "right"))
        ]
        processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True, env={"PATH": "/nonexistent"})
                     for command in commands]
        outputs = [process.communicate(timeout=15) for process in processes]
        self.assertEqual([process.returncode for process in processes], [0, 0], outputs)
        lines = sorted(stdout.strip().split(":", 1)[0] for stdout, _ in outputs)
        self.assertEqual(lines, ["applied", "conflict"])
        read = self.run_store("read", self.database, "race").stdout.strip()
        self.assertIn(read, ("found:1:left", "found:1:right"))

    def test_lost_acknowledgement_reconciles_without_blind_replay(self):
        self.assertEqual(
            self.run_store("operation", self.database, "uncertain-1").stdout,
            "operation-unknown\n")
        process = subprocess.Popen(
            [str(self.binary), "uncertain", str(self.database), "uncertain-1",
             "charge-state", "0", "prepared"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={"PATH": "/nonexistent"})
        try:
            deadline = time.monotonic() + 10
            receipt = ""
            while time.monotonic() < deadline:
                lookup = self.run_store("operation", self.database, "uncertain-1")
                receipt = lookup.stdout
                if receipt == "operation-applied:charge-state:1\n":
                    break
                time.sleep(0.02)
            self.assertEqual(receipt, "operation-applied:charge-state:1\n")
            self.assertIsNone(process.poll())  # result is deliberately still unacknowledged
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGKILL)
            process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)

        self.assertEqual(
            self.write("uncertain-1", "charge-state", 0, "prepared").stdout,
            "replayed:1\n")
        self.assertEqual(
            self.run_store("read", self.database, "charge-state").stdout,
            "found:1:prepared\n")

    def test_kill_between_operations_preserves_first_and_does_not_start_second(self):
        process = subprocess.Popen(
            [str(self.binary), "between", str(self.database)], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1, env={"PATH": "/nonexistent"})
        self.assertEqual(process.stdout.readline(), "applied:1\n")
        process.send_signal(signal.SIGKILL)
        process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(
            self.run_store("read", self.database, "between-a").stdout,
            "found:1:first\n")
        self.assertEqual(
            self.run_store("read", self.database, "between-b").stdout, "missing\n")
        with sqlite3.connect(self.database) as database:
            self.assertEqual(database.execute("PRAGMA integrity_check").fetchone()[0], "ok")

    def test_prepared_statements_preserve_sql_text_as_data(self):
        key = "x'; DROP TABLE stiff_kv; --"
        value = "v'); DELETE FROM stiff_operations; --"
        self.assertEqual(self.write("quoted-op", key, 0, value).stdout, "applied:1\n")
        self.assertEqual(
            self.run_store("read", self.database, key).stdout, f"found:1:{value}\n")
        self.assertEqual(self.write("second", "safe", 0, "present").stdout, "applied:1\n")

    def test_invalid_scope_and_incompatible_database_fail_explicitly(self):
        memory = self.run_store("read", ":memory:", "key", check=False)
        self.assertNotEqual(memory.returncode, 0)
        self.assertEqual(memory.stderr, "invalid_store_path\n")

        unrelated = self.directory / f"{self._testMethodName}-unrelated.db"
        with sqlite3.connect(unrelated) as database:
            self.assertEqual(database.execute("PRAGMA journal_mode=DELETE").fetchone()[0], "delete")
            database.execute("CREATE TABLE customer_data(value TEXT NOT NULL)")
            database.execute("INSERT INTO customer_data VALUES('keep me')")
        result = self.run_store("read", unrelated, "key", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "store_schema\n")
        with sqlite3.connect(unrelated) as database:
            self.assertEqual(database.execute("SELECT value FROM customer_data").fetchone()[0], "keep me")
            self.assertEqual(database.execute("PRAGMA application_id").fetchone()[0], 0)
            self.assertEqual(database.execute("PRAGMA user_version").fetchone()[0], 0)
            self.assertEqual(database.execute("PRAGMA journal_mode").fetchone()[0], "delete")
            names = {row[0] for row in database.execute(
                "SELECT name FROM sqlite_schema WHERE name LIKE 'stiff_%'")}
            self.assertEqual(names, set())

        preexisting = self.directory / f"{self._testMethodName}-preexisting.db"
        with sqlite3.connect(preexisting) as database:
            database.execute("CREATE TABLE stiff_kv(not_the_store_schema TEXT)")
        result = self.run_store("read", preexisting, "key", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "store_schema\n")
        with sqlite3.connect(preexisting) as database:
            columns = [row[1] for row in database.execute("PRAGMA table_info(stiff_kv)")]
            self.assertEqual(columns, ["not_the_store_schema"])
            self.assertEqual(database.execute("PRAGMA application_id").fetchone()[0], 0)

        malformed = self.directory / f"{self._testMethodName}-malformed-owned.db"
        with sqlite3.connect(malformed) as database:
            # All columns look plausible, but the private CHECK constraints are
            # absent. Markers alone must not make this Stiff-owned schema valid.
            database.execute(
                "CREATE TABLE stiff_kv(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL,"
                "version INTEGER NOT NULL)")
            database.execute(
                "CREATE TABLE stiff_operations(operation_id TEXT PRIMARY KEY NOT NULL,"
                "key TEXT NOT NULL,expected_version INTEGER NOT NULL,value TEXT NOT NULL,"
                "outcome INTEGER NOT NULL,result_version INTEGER,result_value TEXT)")
            database.execute("PRAGMA application_id=1398031942")
            database.execute("PRAGMA user_version=1")
        result = self.run_store("read", malformed, "key", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "store_schema\n")
        with sqlite3.connect(malformed) as database:
            self.assertEqual(database.execute("PRAGMA journal_mode").fetchone()[0], "delete")
            self.assertEqual(database.execute("PRAGMA application_id").fetchone()[0], 1398031942)
            self.assertEqual([row[1] for row in database.execute("PRAGMA table_info(stiff_kv)")],
                             ["key", "value", "version"])

        too_long = self.run_store("read", self.database, "k" * 256, check=False)
        self.assertNotEqual(too_long.returncode, 0)
        self.assertEqual(too_long.stderr, "store_input_too_large\n")


if __name__ == "__main__":
    unittest.main()
