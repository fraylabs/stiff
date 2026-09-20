import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { createServer } from 'node:http';
import { createServer as createTlsServer } from 'node:https';
import { execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Http, send, sendJson, StiffError } from '../src/node.mjs';
import '../src/PROOF.bend';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
const loader = path.join(root, '.cache/bend/bend2/main.ts');
let server, secure, base, tlsUrl, temporary, cert;
const visits = new Map();
const listen = (server) => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const code = (expected) => error => error instanceof StiffError && error.code === expected;

before(async () => {
  server = createServer(async (request, response) => {
    visits.set(request.url, (visits.get(request.url) ?? 0) + 1);
    response.setHeader('content-type', 'application/json');
    if (request.url === '/slow') return;
    if (request.url === '/slow-body') { response.write('{'); return; }
    if (request.url === '/redirect') {
      response.writeHead(302, { location: '/destination' });
      return response.end('{}');
    }
    if (request.url === '/large') return response.end('x'.repeat(100));
    if (request.url === '/bad-json') return response.end('{');
    if (request.url === '/bad-utf8') return response.end(Buffer.from([0xff]));
    if (request.url === '/unicode') {
      const body = Buffer.from('"🌱"');
      response.write(body.subarray(0, 3));
      return setImmediate(() => response.end(body.subarray(3)));
    }
    if (request.url === '/status') response.statusCode = 503;
    let body = '';
    for await (const chunk of request) body += chunk;
    response.end(JSON.stringify({ method: request.method, body,
      contentType: request.headers['content-type'] ?? null }));
  });
  await listen(server);
  base = `http://127.0.0.1:${server.address().port}`;
  temporary = mkdtempSync(path.join(tmpdir(), 'stiff-test-'));
  cert = path.join(temporary, 'cert.pem');
  const key = path.join(temporary, 'key.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=IP:127.0.0.1'], { stdio: 'ignore' });
  secure = createTlsServer({ key: readFileSync(key), cert: readFileSync(cert) },
    (_request, response) => response.end('{"secure":true}'));
  await listen(secure);
  tlsUrl = `https://127.0.0.1:${secure.address().port}`;
});

after(async () => {
  for (const instance of [server, secure]) {
    if (!instance) continue;
    instance.closeAllConnections();
    await new Promise(resolve => instance.close(resolve));
  }
  if (temporary) rmSync(temporary, { recursive: true, force: true });
});

test('Bend constructors cross the actual loader boundary', () => {
  assert.deepEqual(Http.get('https://example.com'), {
    $: 'Request', method: 'GET', url: 'https://example.com', body: '',
    timeout_ms: 10000, max_bytes: 1048576,
  });
  for (const status of [199, 200, 201, 299, 300, 400, 503]) {
    assert.equal(Http.is_success(status), status >= 200 && status < 300);
  }
});

test('GET decodes JSON and preserves status', async () => {
  const response = await sendJson(Http.get(base));
  assert.equal(response.status, 200);
  assert.equal(response.ok, true);
  assert.equal(response.data.method, 'GET');
});

test('POST transmits JSON once', async () => {
  const response = await sendJson(Http.post_json(`${base}/post`, '{"hello":"bend"}'));
  assert.equal(response.data.method, 'POST');
  assert.deepEqual(JSON.parse(response.data.body), { hello: 'bend' });
  assert.equal(response.data.contentType, 'application/json');
  assert.equal(visits.get('/post'), 1);
});

test('HTTP failures remain responses and are not retried', async () => {
  const response = await sendJson(Http.get(`${base}/status`));
  assert.equal(response.status, 503);
  assert.equal(response.ok, false);
  assert.equal(visits.get('/status'), 1);
});

test('redirects are returned without following them', async () => {
  const response = await send(Http.get(`${base}/redirect`));
  assert.equal(response.status, 302);
  assert.equal(visits.get('/destination'), undefined);
});

test('invalid JSON request is rejected before sending', async () => {
  await assert.rejects(send(Http.post_json(`${base}/invalid`, '{')), code('invalid_json_request'));
  assert.equal(visits.get('/invalid'), undefined);
});

test('malformed JSON response has a distinct error', async () => {
  await assert.rejects(sendJson(Http.get(`${base}/bad-json`)), code('invalid_json_response'));
});

test('body size counts received bytes', async () => {
  await assert.rejects(send(Http.with_max_bytes(10, Http.get(`${base}/large`))), code('body_too_large'));
});

test('UTF-8 split across chunks is decoded intact', async () => {
  assert.equal((await sendJson(Http.get(`${base}/unicode`))).data, '🌱');
});

test('invalid UTF-8 is rejected rather than silently replaced', async () => {
  await assert.rejects(send(Http.get(`${base}/bad-utf8`)), code('invalid_utf8'));
});

test('deadline covers response headers', async () => {
  await assert.rejects(send(Http.with_timeout(80, Http.get(`${base}/slow`))), code('timeout'));
});

test('deadline covers a stalled response body', async () => {
  await assert.rejects(send(Http.with_timeout(80, Http.get(`${base}/slow-body`))), code('timeout'));
});

test('caller cancellation aborts an in-flight request', async () => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 50);
  try {
    await assert.rejects(send(Http.get(`${base}/slow`), { signal: controller.signal }), code('cancelled'));
  } finally { clearTimeout(timer); }
});

test('pre-cancelled requests never reach the server', async () => {
  await assert.rejects(send(Http.get(`${base}/cancelled`), { signal: AbortSignal.abort() }), code('cancelled'));
  assert.equal(visits.get('/cancelled'), undefined);
});

test('untrusted HTTPS certificate fails verification', async () => {
  await assert.rejects(send(Http.get(tlsUrl)), code('network'));
});

test('HTTPS succeeds with an explicitly trusted test CA', async () => {
  const { stdout } = await exec(process.execPath, ['--import', loader,
    '--input-type=module', '-e',
    'import { Http, sendJson } from "./src/node.mjs"; console.log(JSON.stringify((await sendJson(Http.get(process.argv[1]))).data));', tlsUrl],
  { cwd: root, env: { ...process.env, NODE_EXTRA_CA_CERTS: cert } });
  assert.deepEqual(JSON.parse(stdout), { secure: true });
});

test('invalid host inputs cannot bypass request validation', async () => {
  for (const url of ['file:///tmp/example', 'ftp://example.com', 'https://user:pass@example.com', 'invalid']) {
    await assert.rejects(send(Http.get(url)), code('invalid_request'));
  }
  for (const value of [0, -1, 1.5, 2 ** 32]) {
    await assert.rejects(send({ ...Http.get(base), timeout_ms: value }), code('invalid_request'));
  }
});

test('proof checking rejects an intentionally false claim', async () => {
  const bad = path.join(root, '.cache/broken-proof.bend');
  writeFileSync(bad, 'import Base\nimport ../src/http.bend as Http\n\ndef false_claim() -> {Http.timeout(Http.get("https://example.com")) == 1 : U32}:\n  {==}\n');
  try {
    await assert.rejects(exec(process.execPath, ['--import', loader, '--input-type=module',
      '-e', 'await import("./.cache/broken-proof.bend");'], { cwd: root }),
    error => error.code !== 0 && /expected\s*:\s*10000/.test(error.stderr)
      && /observed\s*:\s*1\b/.test(error.stderr));
  } finally { rmSync(bad, { force: true }); }
});
