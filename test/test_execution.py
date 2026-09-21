"""Actual native process cancellation, kernel limits and blocked/failed logs."""
import json
import os
from pathlib import Path
import platform
import queue
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest
ROOT = Path(__file__).resolve().parent.parent

class ExecutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='stiff-execution-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.runner = str(Path(cls.temp.name)/'stiff-run')
        cls.fault_runner = str(Path(cls.temp.name)/'stiff-run-fault')
        cls.child = str(Path(cls.temp.name)/'child')
        # The deliberate resource-stress child remains uninstrumented.
        for source, binary in [('native/stiff-run.c', cls.runner), ('test/fixtures/runner-child.c', cls.child)]:
            flags = []
            if binary == cls.runner and os.environ.get('STIFF_NATIVE_SANITIZE') in ('1','combined'):
                flags = ['-fsanitize=address,undefined','-fno-sanitize-recover=all','-fno-omit-frame-pointer']
            subprocess.run([os.environ.get('CC','clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-O0',
                            *flags, str(ROOT/source), '-o', binary], check=True, capture_output=True)
        flags = []
        if os.environ.get('STIFF_NATIVE_SANITIZE') in ('1','combined'):
            flags = ['-fsanitize=address,undefined','-fno-sanitize-recover=all','-fno-omit-frame-pointer']
        subprocess.run([
            os.environ.get('CC','clang'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-O0', *flags,
            '-include', str(ROOT/'test/fixtures/runner-fcntl-shim.h'),
            str(ROOT/'native/stiff-run.c'), str(ROOT/'test/fixtures/runner-fcntl-shim.c'),
            '-o', cls.fault_runner,
        ], check=True, capture_output=True)

        cls.http_client = str(Path(cls.temp.name)/'http-client')
        subprocess.run([str(ROOT/'scripts/build-native.sh'), 'examples/get-json.bend', cls.http_client],
                       cwd=ROOT, check=True, capture_output=True, timeout=120)

    def command(self, mode, *limits):
        return [self.runner, '--grace-ms', '50', *limits, '--', self.child, mode]

    def fault_command(self, mode):
        return [self.fault_runner, '--grace-ms', '50', '--', self.child, mode]

    def assert_process_gone(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        self.fail(f'process {pid} survived runner setup failure')

    def test_exit_status_and_complete_json_logs(self):
        p = subprocess.run(self.command('exit'), capture_output=True, text=True, timeout=3)
        self.assertEqual(p.returncode, 7)
        lines = [json.loads(x) for x in p.stderr.splitlines()]
        self.assertEqual(lines[0], {'event':'child'})
        self.assertEqual(lines[-1]['dropped_log_records'], 0)

    def test_wall_limit_kills_uncooperative_work(self):
        start = time.monotonic()
        p = subprocess.run(self.command('wait', '--wall-ms','100'), capture_output=True, timeout=3)
        self.assertEqual(p.returncode, 124)
        self.assertLess(time.monotonic()-start, 2)
        self.assertIn(b'"timed_out":true', p.stderr)

    def test_signal_cancellation_and_descendant_cleanup(self):
        p = subprocess.Popen(self.command('grandchild'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            lines = queue.Queue()
            threading.Thread(target=lambda: lines.put(p.stdout.readline()), daemon=True).start()
            descendant = int(lines.get(timeout=3))
            p.send_signal(signal.SIGTERM)
            _, err = p.communicate(timeout=3)
            self.assertEqual(p.returncode, 143, err)
            # Linux orphan zombies may briefly await init; they cannot run effects.
            for _ in range(100):
                try:
                    os.kill(descendant, 0)
                    stat = Path(f'/proc/{descendant}/stat')
                    if stat.exists() and stat.read_text().split()[2] == 'Z': break
                except ProcessLookupError: break
                time.sleep(.01)
            else: self.fail('descendant survived cancellation')
        finally:
            if p.poll() is None: p.kill(); p.wait()
            p.stdout.close(); p.stderr.close()

    def test_kernel_cpu_limit(self):
        p = subprocess.run(self.command('cpu','--cpu-seconds','1'), capture_output=True, timeout=5)
        self.assertIn(p.returncode, (137, 152))

    def test_hard_address_space_limit_or_explicit_platform_rejection(self):
        p = subprocess.run(self.command('memory','--address-space-mb','64'), capture_output=True, timeout=3)
        if platform.system() == 'Linux': self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertEqual(p.returncode, 125)
            self.assertIn(b'require Linux', p.stderr)

    def test_blocked_log_sink_does_not_block_application_or_shutdown(self):
        read_fd, write_fd = os.pipe()
        try:
            start = time.monotonic()
            p = subprocess.Popen(self.command('logs'), stdout=subprocess.DEVNULL, stderr=write_fd)
            self.assertEqual(p.wait(timeout=5), 0)
            self.assertLess(time.monotonic()-start, 4)
        finally:
            os.close(write_fd); os.close(read_fd)
            if p.poll() is None: p.kill(); p.wait()

    def test_failed_log_sink_does_not_crash_application(self):
        read_fd, write_fd = os.pipe(); os.close(read_fd)
        try:
            p = subprocess.run(self.command('logs'), stdout=subprocess.DEVNULL, stderr=write_fd, timeout=5)
            self.assertEqual(p.returncode, 0)
        finally: os.close(write_fd)

    def test_cancel_actual_running_http_effect_without_replay(self):
        listener = socket.socket()
        listener.bind(('127.0.0.1',0)); listener.listen(2); listener.settimeout(3)
        self.addCleanup(listener.close)
        accepted = threading.Event()
        closed = threading.Event()
        count = []
        def peer():
            connection, _ = listener.accept()
            count.append(1)
            with connection:
                connection.settimeout(3)
                request = connection.recv(8192)
                if b'GET /' in request: accepted.set()
                # Hold the operation in libcurl until the process boundary cancels it.
                while connection.recv(4096): pass
                closed.set()
        worker = threading.Thread(target=peer, daemon=True); worker.start()
        p = subprocess.Popen([self.runner, '--grace-ms','50', '--wall-ms','2000', '--', self.http_client,
                              '--threads','1', f'http://127.0.0.1:{listener.getsockname()[1]}/'],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(accepted.wait(3))
            p.send_signal(signal.SIGTERM)
            out, err = p.communicate(timeout=3)
            self.assertEqual(p.returncode, 143, err)
            self.assertEqual(out, b'')
            self.assertTrue(closed.wait(2))
            self.assertEqual(count, [1])
        finally:
            if p.poll() is None: p.kill(); p.wait()
            p.stdout.close(); p.stderr.close()
            worker.join(timeout=3)

    def test_forwarded_and_dropped_records_account_for_child_output(self):
        p = subprocess.run(self.command('logs'),capture_output=True,text=True,timeout=5)
        self.assertEqual(p.returncode,0,p.stderr[-1000:])
        records = [json.loads(line) for line in p.stderr.splitlines()]
        self.assertEqual(records[-1]['event'],'stiff_runner_exit')
        self.assertEqual(len(records)-1+records[-1]['dropped_log_records'],100000)

    def test_completed_child_status_survives_late_signal_during_log_drain(self):
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd,False)
        try:
            while True: os.write(write_fd,b'x'*4096)
        except BlockingIOError: pass
        os.set_blocking(write_fd,True)
        p = subprocess.Popen([self.runner,'--grace-ms','500','--',self.child,'exit'],
                             stdout=subprocess.PIPE,stderr=write_fd,text=True)
        try:
            lines = queue.Queue()
            threading.Thread(target=lambda:lines.put(p.stdout.readline()),daemon=True).start()
            self.assertEqual(lines.get(timeout=3).strip(),'EXITING')
            time.sleep(.1)
            p.send_signal(signal.SIGTERM)
            self.assertEqual(p.wait(timeout=3),7)
        finally:
            if p.poll() is None: p.kill(); p.wait()
            p.stdout.close(); os.close(write_fd); os.close(read_fd)

    def test_fcntl_eintr_after_child_launch_is_retried(self):
        observed = Path(self.temp.name)/'eintr-children'
        env = os.environ.copy()
        env['STIFF_RUNNER_FCNTL_FAULT'] = 'eintr'
        env['STIFF_RUNNER_CHILDREN_FILE'] = str(observed)
        p = subprocess.run(self.fault_command('exit'), env=env, capture_output=True, text=True, timeout=3)
        self.assertEqual(p.returncode, 7, p.stderr)
        sink_text, child_text, fault = observed.read_text().split()
        self.assertEqual(fault, 'eintr')
        sink, child = int(sink_text), int(child_text)
        self.assert_process_gone(child)
        self.assert_process_gone(sink)

    def test_fcntl_failure_after_child_launch_reaps_child_and_sink(self):
        observed = Path(self.temp.name)/'failed-children'
        env = os.environ.copy()
        env['STIFF_RUNNER_FCNTL_FAULT'] = 'fail'
        env['STIFF_RUNNER_CHILDREN_FILE'] = str(observed)
        p = subprocess.run(self.fault_command('wait'), env=env, capture_output=True, text=True, timeout=3)
        self.assertEqual(p.returncode, 125, p.stderr)
        self.assertIn('fcntl', p.stderr)
        sink_text, child_text, fault = observed.read_text().split()
        self.assertEqual(fault, 'fail')
        sink, child = int(sink_text), int(child_text)
        self.assert_process_gone(child)
        self.assert_process_gone(sink)
