import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import { createServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { execFileSync, execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { runFile } from '../src/runner.mjs';
import { toBendJson } from '../src/bend-host.mjs';
import Json from '../src/json.bend';

const root = fileURLToPath(new URL('../', import.meta.url));
const exec = promisify(execFile);
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const loader = path.join(root, '.cache/bend/bend2/main.ts');
let server, tls, directory, base, tlsUrl, cert;
let interruptedRequest;
const visits = new Map();
const imports = `import Base
import ../../src/http.bend as Http
import ../../src/io.bend as Net
`;

function fixture(name, source) {
  const file = path.join(directory, `${name}.bend`);
  writeFileSync(file, source);
  return file;
}

async function run(file, options = {}) {
  let out = '', err = '';
  const code = await runFile(file, {
    stdout: { write: text => { out += Buffer.from(text).toString(); } },
    stderr: { write: text => { err += Buffer.from(text).toString(); } },
    ...options,
  });
  return { code, out, err };
}

function raw(request) {
  return imports + `
def show(result: Net.HttpResult) -> IO(Unit):
  match result:
    case Net.HttpOk{Net.Response{status, body}}:
      IO.print(U32.show(status) ++ ":" ++ body)
    case Net.HttpError{code, message}:
      IO.print(code)

def main() -> IO(Unit):
  do IO<Unit>:
    response : Net.HttpResult <- Net.Stiff.send(${request})
    show(response)
`;
}

before(async () => {
  directory = mkdtempSync(path.join(root, '.cache/io-test-'));
  server = createServer(async (request, response) => {
    visits.set(request.url, (visits.get(request.url) ?? 0) + 1);
    if (request.url === '/slow') return;
    if (request.url === '/interrupt') { interruptedRequest?.(); return; }
    if (request.url === '/broken') return response.end('{');
    if (request.url === '/post') {
      let body = '';
      for await (const chunk of request) body += chunk;
      return response.end(body);
    }
    if (request.url === '/unavailable') response.statusCode = 503;
    response.end('{"slideshow":{"title":"Bend can read this"}}');
  });
  await listen(server);
  base = `http://127.0.0.1:${server.address().port}`;
  cert = path.join(directory, 'cert.pem');
  const key = path.join(directory, 'key.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=IP:127.0.0.1'], { stdio: 'ignore' });
  tls = createHttpsServer({ key: readFileSync(key), cert: readFileSync(cert) },
    (_request, response) => response.end('{"slideshow":{"title":"Trusted HTTPS"}}'));
  await listen(tls);
  tlsUrl = `https://127.0.0.1:${tls.address().port}`;
});

after(async () => {
  for (const instance of [server, tls]) {
    if (!instance) continue;
    instance.closeAllConnections();
    await new Promise(resolve => instance.close(resolve));
  }
  rmSync(directory, { recursive: true, force: true });
});

test('a Bend IO entry point reads nested JSON and prints it', async () => {
  const result = await run(path.join(root, 'examples/get-json.bend'), { args: [base] });
  assert.deepEqual(result, { code: 0, out: 'HTTP 200\nBend can read this\n', err: '' });
});

test('Bend JSON lookup handles every JSON kind and missing fields', () => {
  const input = { text: 'hello 🌱', bool: true, nil: null, number: 1.25, list: [false, 'x'] };
  const value = toBendJson(input);
  assert.deepEqual(Json.field('text', value), { $: 'Some', value: { $: 'JsonString', value: 'hello 🌱' } });
  assert.deepEqual(Json.field('bool', value).value, { $: 'JsonBool', value: true });
  assert.deepEqual(Json.field('nil', value).value, { $: 'JsonNull' });
  assert.deepEqual(Json.field('number', value).value, { $: 'JsonNumber', decimal: '1.25' });
  const array = Json.field('list', value).value;
  assert.equal(array.$, 'JsonArray');
  assert.deepEqual(array.items.head, { $: 'JsonBool', value: false });
  assert.deepEqual(Json.field('missing', value), { $: 'None' });
  assert.deepEqual(Json.field('text', toBendJson(null)), { $: 'None' });
  assert.deepEqual(Json.as_string(toBendJson('x')), { $: 'Some', value: 'x' });
});

test('Bend JSON boundary bounds nesting and rejects nonfinite numbers', () => {
  let value = null;
  for (let i = 0; i < 130; i++) value = [value];
  assert.throws(() => toBendJson(value), error => error.code === 'json_too_deep');
  assert.throws(() => toBendJson(JSON.parse('1e999')), error => error.code === 'json_number_range');
});

test('Bend handles HTTP status separately from a transport failure', async () => {
  const file = fixture('status', raw(`Http.get("${base}/unavailable")`));
  assert.match((await run(file)).out, /^503:/);
  assert.equal(visits.get('/unavailable'), 1);
});

test('Bend POST sends its JSON body once', async () => {
  const file = fixture('post', raw(`Http.post_json("${base}/post", "[1,2,3]")`));
  assert.equal((await run(file)).out, '200:[1,2,3]\n');
  assert.equal(visits.get('/post'), 1);
});

test('Bend can match timeout and body-limit errors', async () => {
  const timeout = fixture('timeout', raw(`Http.with_timeout(40, Http.get("${base}/slow"))`));
  assert.equal((await run(timeout)).out, 'timeout\n');
  const size = fixture('size', raw(`Http.with_max_bytes(5, Http.get("${base}"))`));
  assert.equal((await run(size)).out, 'body_too_large\n');
});

test('malformed JSON becomes a Bend error and preserves IO.die exit code', async () => {
  const result = await run(path.join(root, 'examples/get-json.bend'), { args: [`${base}/broken`] });
  assert.equal(result.code, 1);
  assert.equal(result.out, '');
  assert.match(result.err, /^invalid_json_response:/);
});

test('CLI runs a Bend HTTPS program with trusted certificates', async () => {
  const { stdout } = await exec(process.execPath, ['--import', loader, 'scripts/run.mjs',
    'examples/get-json.bend', tlsUrl], { cwd: root, env: { ...process.env, NODE_EXTRA_CA_CERTS: cert } });
  assert.equal(stdout, 'HTTP 200\nTrusted HTTPS\n');
});

test('Bend HTTPS rejects untrusted certificates', async () => {
  const result = await run(path.join(root, 'examples/get-json.bend'), { args: [tlsUrl] });
  assert.equal(result.code, 1);
  assert.match(result.err, /^network:/);
});

test('unsupported effects fail explicitly', async () => {
  const file = fixture('unsupported', `import Base
def main() -> IO(Nat):
  IO.now()
`);
  await assert.rejects(run(file), /Unsupported Bend IO effect: io_now/);
});

test('IO.sleep waits without blocking Node and then resumes once', async () => {
  const file = fixture('sleep', `import Base
def main() -> IO(Unit):
  do IO<Unit>:
    IO.sleep(40)
    IO.print("awake")
`);
  let fired = false;
  const timer = setTimeout(() => { fired = true; }, 10);
  try {
    assert.equal((await run(file)).out, 'awake\n');
    assert.equal(fired, true);
  } finally { clearTimeout(timer); }
});

test('invalid Bend program is rejected before any request', async () => {
  const file = fixture('invalid', 'import Base\ndef main() -> IO(Unit):\n  42\n');
  await assert.rejects(run(file), /expected|observed/);
});

test('SIGINT cancels an active Bend HTTP call and exits 130 without continuation output', { timeout: 10000 }, async () => {
  const file = fixture('interrupt', raw(`Http.get("${base}/interrupt")`));
  const received = new Promise(resolve => { interruptedRequest = resolve; });
  const child = spawn(process.execPath, ['--import', loader, 'scripts/run.mjs', file], { cwd: root });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.resume();
  const exited = once(child, 'exit');
  try {
    await Promise.race([received, exited.then(() => { throw new Error('CLI exited before the request'); })]);
    child.kill('SIGINT');
    const [code, signal] = await exited;
    assert.equal(code, 130);
    assert.equal(signal, null);
    assert.equal(output, '');
    assert.equal(visits.get('/interrupt'), 1);
  } finally {
    interruptedRequest = undefined;
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
});
