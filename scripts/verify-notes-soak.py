#!/usr/bin/env python3
"""Finite local persistent-application soak using independent load processes."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--duration', type=int, default=600)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.duration <= 3600:
        parser.error('duration must be 1..3600 seconds')
    args.binary = args.binary.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    payload = {'operation_id':'soak-seed', 'expected_version':0,
               'note':{'title':'Persistent soak', 'done':False, 'tags':['verified']}}
    revision = subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git','status','--porcelain'], cwd=ROOT, text=True))
    started = time.time()
    rss = []
    children = []
    server = None
    with tempfile.TemporaryDirectory(prefix='stiff-notes-soak-') as temp:
        state = Path(temp)
        database = state/'notes.db'
        with (state/'stderr.log').open('w+') as logs:
            def launch():
                process = subprocess.Popen([str(args.binary), '--threads','2',str(database),'0'],
                                           cwd=state, stdout=subprocess.PIPE, stderr=logs, text=True,
                                           env={**os.environ,'PATH':'/nonexistent'})
                lines = queue.Queue()
                threading.Thread(target=lambda:lines.put(process.stdout.readline()), daemon=True).start()
                try:
                    line = lines.get(timeout=10)
                    assert line.startswith('LISTENING '), line
                    return process, int(line.split()[1])
                except BaseException:
                    process.kill(); process.wait(); process.stdout.close()
                    raise

            def request(method, path, body=None):
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
                try:
                    connection.request(method, path, body=json.dumps(body) if body is not None else None,
                                       headers={'Content-Type':'application/json'})
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    connection.close()

            try:
                server, port = launch()
                assert request('PUT','/notes/soak',payload) == (200,{'version':1,'replayed':False})
                jobs = [
                    ('reads', ['--url',f'http://127.0.0.1:{port}/notes/soak','--rate','50',
                               '--expect-json','/version=1','--expect-json','/note/title="Persistent soak"']),
                    ('replays', ['--url',f'http://127.0.0.1:{port}/notes/soak','--rate','25',
                                 '--method','PUT','--json-body',json.dumps(payload),
                                 '--expect-json','/version=1','--expect-json','/replayed=true']),
                ]
                for name, extra in jobs:
                    log = (args.output/(name+'.log')).open('w')
                    process = subprocess.Popen([sys.executable,str(ROOT/'scripts/load.py'),*extra,
                        '--duration',str(args.duration),'--workers','8','--queue','512',
                        '--timeout','5','--drain-timeout','15','--output',str(args.output/(name+'.json'))],
                        cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
                    children.append((name,process,log))
                deadline = time.monotonic()+args.duration+45
                while any(process.poll() is None for _,process,_ in children):
                    assert time.monotonic() < deadline, 'load processes exceeded finite budget'
                    assert server.poll() is None, 'server exited during soak'
                    value = subprocess.check_output(['ps','-o','rss=','-p',str(server.pid)],text=True).strip()
                    rss.append(int(value))
                    time.sleep(1)
                assert all(process.returncode == 0 for _,process,_ in children), 'load failed; inspect reports'
                assert request('GET','/notes/soak') == (200,{'version':1,'note':payload['note']})
                assert request('GET','/operations/soak-seed') == (200,{'state':'applied','key':'soak','version':1})
                # A fresh mutation after load verifies the store is still writable.
                update = {**payload,'operation_id':'after-soak','expected_version':1}
                assert request('PUT','/notes/soak',update) == (200,{'version':2,'replayed':False})
                server.send_signal(signal.SIGTERM); server.wait(timeout=8)
                assert server.returncode == 0
                server.stdout.close()
                server, port = launch()
                assert request('GET','/notes/soak') == (200,{'version':2,'note':payload['note']})
                assert request('PUT','/notes/soak',update) == (200,{'version':2,'replayed':True})
                server.send_signal(signal.SIGTERM); server.wait(timeout=8)
                assert server.returncode == 0
                server.stdout.close(); server = None
                logs.flush(); logs.seek(0)
                diagnostics = logs.read()
                for marker in ('ERROR: AddressSanitizer','ERROR: LeakSanitizer','runtime error:'):
                    assert marker not in diagnostics, marker
                report = {'revision':revision,'dirty':dirty,'platform':platform.platform(),
                          'binary_sha256':hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                          'duration_seconds':args.duration,'elapsed_seconds':time.time()-started,
                          'workloads':['reads.json','replays.json'],'rss_kib':{'samples':len(rss),'first':rss[0],'last':rss[-1],'max':max(rss)},
                          'fresh_write':True,'graceful_shutdown':True,'restart_read':True,'restart_replay':True,
                          'limits':'Shared-host loopback; repeated identical durable writes, not deployment capacity or long-term memory proof.'}
                (args.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
                print(json.dumps(report,indent=2))
            finally:
                for _,process,log in children:
                    if process.poll() is None: process.kill(); process.wait()
                    log.close()
                if server is not None:
                    if server.poll() is None: server.kill(); server.wait()
                    server.stdout.close()


if __name__ == '__main__':
    main()
