import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import { createServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtempSync, readFileSync, rmSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { gzipSync } from 'node:zlib';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
let temporary, server, tls, base, tlsUrl, cert;
let onInterrupt;
const visits = new Map();
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const cleanEnv = () => ({ PATH: '/nonexistent', STIFF_CA_BUNDLE: cert, NO_PROXY: '*' });
const bin = name => path.join(temporary, name);
async function run(name, args = [], env = cleanEnv()) {
  try {
    const result = await exec(bin(name), args, { cwd: temporary, env, timeout: 5000 });
    return { code: 0, ...result };
  } catch (error) {
    if (typeof error.code !== 'number') throw error;
    return { code: error.code, stdout: error.stdout, stderr: error.stderr };
  }
}
const http = (url, method = 'GET', body = '', timeout = '2000', limit = '1048576') =>
  run('http', [url, method, body, timeout, limit]);

before(async () => {
  temporary = mkdtempSync(path.join(tmpdir(), 'stiff-native-'));
  for (const [source, name] of [['examples/get-json.bend', 'get-json'],
    ['test/fixtures/native-http.bend', 'http'], ['test/fixtures/native-json.bend', 'json']]) {
    await exec(process.execPath, ['scripts/build-native.mjs', source, `.cache/native/${name}`], { cwd: root });
    copyFileSync(path.join(root, '.cache/native', name), bin(name));
  }
  cert = path.join(temporary, 'cert.pem');
  const key = path.join(temporary, 'key.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=localhost',
    '-addext', 'subjectAltName=IP:127.0.0.1'], { stdio: 'ignore' });
  const handler = async (request, response) => {
    visits.set(request.url, (visits.get(request.url) ?? 0) + 1);
    if (request.url === '/slow') return;
    if (request.url === '/slow-body') { response.write('{'); return; }
    if (request.url === '/interrupt') { onInterrupt?.(); return; }
    if (request.url === '/redirect') { response.writeHead(302, { location: '/destination' }); return response.end('{}'); }
    if (request.url === '/empty') { response.statusCode = 204; return response.end(); }
    if (request.url === '/bad-json') return response.end('{');
    if (request.url === '/bad-utf8') return response.end(Buffer.from([0xf0, 0x28, 0x8c, 0xbc]));
    if (request.url === '/large') return response.end('x'.repeat(2048));
    if (request.url === '/gzip') { response.setHeader('content-encoding', 'gzip'); return response.end(gzipSync('x'.repeat(2048))); }
    if (request.url === '/unicode') return response.end('🌱');
    if (request.url === '/post') {
      let body = '';
      for await (const part of request) body += part;
      assert.equal(request.headers['content-type'], 'application/json');
      return response.end(body);
    }
    if (request.url === '/status') response.statusCode = 503;
    response.end('{"slideshow":{"title":"Native Bend"}}');
  };
  server = createServer(handler);
  tls = createHttpsServer({ cert: readFileSync(cert), key: readFileSync(key) }, handler);
  await listen(server);
  await listen(tls);
  base = `http://127.0.0.1:${server.address().port}`;
  tlsUrl = `https://127.0.0.1:${tls.address().port}`;
});

after(async () => {
  for (const instance of [server, tls]) {
    if (!instance) continue;
    instance.closeAllConnections();
    await new Promise(resolve => instance.close(resolve));
  }
  if (temporary) rmSync(temporary, { recursive: true, force: true });
});

test('copied native executable fetches HTTPS JSON with no Node or source on PATH', async () => {
  assert.deepEqual(await run('get-json', [tlsUrl]), { code: 0, stdout: 'HTTP 200\nNative Bend\n', stderr: '' });
});

test('native TLS rejects an untrusted certificate', async () => {
  const result = await run('get-json', [tlsUrl], { PATH: '/nonexistent', NO_PROXY: '*' });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /^network:/);
});

test('native response preserves HTTP error status without retries', async () => {
  assert.match((await http(`${base}/status`)).stdout, /^503:/);
  assert.equal(visits.get('/status'), 1);
});

test('native requests do not follow redirects', async () => {
  assert.equal((await http(`${base}/redirect`)).stdout, '302:{}\n');
  assert.equal(visits.get('/destination'), undefined);
});

test('native JSON POST sends exactly one request', async () => {
  assert.equal((await http(`${base}/post`, 'POST', '[1,2,3]')).stdout, '200:[1,2,3]\n');
  assert.equal(visits.get('/post'), 1);
});

test('native invalid requests and malformed POST bodies fail before sending', async () => {
  for (const url of ['file:///tmp/anything', 'ftp://example.com', 'http://user:pass@127.0.0.1']) {
    assert.equal((await http(url)).stderr, 'invalid_request\n');
  }
  assert.equal((await http(`${base}/invalid`, 'GET', 'body')).stderr, 'invalid_request\n');
  assert.equal((await http(`${base}/invalid`, 'GET', '', '0')).stderr, 'invalid_request\n');
  for (const body of ['{', 'NaN', '{} garbage', '/*comment*/{}']) {
    assert.equal((await http(`${base}/invalid`, 'POST', body)).stderr, 'invalid_json_request\n');
  }
  assert.equal(visits.get('/invalid'), undefined);
});

test('native deadline covers headers and stalled bodies', async () => {
  for (const route of ['/slow', '/slow-body']) {
    assert.equal((await http(base + route, 'GET', '', '80')).stderr, 'timeout\n');
  }
});

test('native body limit applies after decompression', async () => {
  for (const route of ['/large', '/gzip']) {
    assert.equal((await http(base + route, 'GET', '', '2000', '10')).stderr, 'body_too_large\n');
  }
});

test('native UTF-8 preserves Unicode and rejects malformed sequences', async () => {
  assert.equal((await http(`${base}/unicode`)).stdout, '200:🌱\n');
  assert.equal((await http(`${base}/bad-utf8`)).stderr, 'invalid_utf8\n');
});

test('native handles empty bodies and malformed JSON', async () => {
  assert.equal((await http(`${base}/empty`)).stdout, '204:\n');
  const result = await run('get-json', [`${base}/bad-json`]);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /^invalid_json_response:/);
});

test('native JSON ABI preserves booleans, numbers, strings, containers and null', async () => {
  for (const [value, expected] of [[true, 'true'], [false, 'false'], [null, 'null'],
    [1.25, '1.25'], ['🌱', '🌱'], ['\u0000', '\u0000'], [[1, true, null], 'array'], [{ nested: true }, 'object']]) {
    const result = await run('json', [JSON.stringify({ key: value })]);
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stdout, `object:${expected}\n`);
  }
  assert.equal((await run('json', ['null'])).stdout, 'null:missing\n');
  assert.equal((await run('json', ['"\\ud83c\\udf31"'])).stdout, '🌱:missing\n');
  assert.equal((await run('json', ['{"key":1,"key":2}'])).stdout, 'object:2\n');
});

test('native JSON rejects malformed data, nonfinite numbers and oversized integers', async () => {
  for (const value of ['{', '{} {}', '/*x*/{}', '[1,]', '01', '{"key\\u0000suffix":1}', '"\\ud800"', '"\\udc00"']) {
    assert.equal((await run('json', [value])).stderr, 'invalid_json_response\n');
  }
  for (const value of ['1e999', '9007199254740993']) {
    assert.equal((await run('json', [value])).stderr, 'json_number_range\n');
  }
  assert.equal((await run('json', ['['.repeat(140) + '0' + ']'.repeat(140)])).stderr, 'json_too_deep\n');
});

test('SIGINT terminates native in-flight work without replay or continuation output', { timeout: 10000 }, async () => {
  const received = new Promise(resolve => { onInterrupt = resolve; });
  const child = spawn(bin('http'), [`${base}/interrupt`, 'GET', '', '10000', '1048576'],
    { cwd: temporary, env: cleanEnv() });
  let output = '';
  child.stdout.on('data', part => { output += part; });
  child.stderr.resume();
  const exited = once(child, 'exit');
  try {
    await Promise.race([received, exited.then(() => { throw new Error('Native process exited before request'); })]);
    child.kill('SIGINT');
    const [code, signal] = await exited;
    assert.equal(code, null);
    assert.equal(signal, 'SIGINT');
    assert.equal(output, '');
    assert.equal(visits.get('/interrupt'), 1);
  } finally {
    onInterrupt = undefined;
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
});
