import Http from './http.bend';
export { Http };

export class StiffError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = 'StiffError';
    this.code = code;
  }
}

function validate(request) {
  if (!request || request.$ !== 'Request' || !['GET', 'POST'].includes(request.method)
    || typeof request.url !== 'string' || typeof request.body !== 'string') {
    throw new StiffError('invalid_request', 'Expected a Stiff GET or POST request.');
  }
  for (const key of ['timeout_ms', 'max_bytes']) {
    if (!Number.isInteger(request[key]) || request[key] < 1 || request[key] > 0x7fffffff) {
      throw new StiffError('invalid_request', `${key} must be between 1 and 2147483647.`);
    }
  }
  let url;
  try { url = new URL(request.url); }
  catch { throw new StiffError('invalid_request', 'Expected an absolute HTTP(S) URL.'); }
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) {
    throw new StiffError('invalid_request', 'Use HTTP(S) without credentials in the URL.');
  }
  if (request.method === 'GET' && request.body !== '') {
    throw new StiffError('invalid_request', 'GET requests cannot have a body.');
  }
  if (request.method === 'POST') {
    try { JSON.parse(request.body); }
    catch { throw new StiffError('invalid_json_request', 'POST body must be valid JSON.'); }
  }
  return url;
}

/** One request, no redirects or retries. Deadline covers headers and body. */
export async function send(request, { signal, headers = {} } = {}) {
  request = { ...request };
  const url = validate(request);
  if (signal !== undefined && !(signal instanceof AbortSignal)) {
    throw new StiffError('invalid_request', 'signal must be an AbortSignal.');
  }
  let outgoing;
  try { outgoing = new Headers(headers); }
  catch { throw new StiffError('invalid_request', 'Invalid HTTP headers.'); }
  if (!outgoing.has('accept')) outgoing.set('accept', 'application/json');
  if (request.method === 'POST') outgoing.set('content-type', 'application/json');
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), request.timeout_ms);
  const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
  let reader;
  try {
    const response = await fetch(url, {
      method: request.method,
      body: request.method === 'POST' ? request.body : undefined,
      headers: outgoing,
      redirect: 'manual',
      signal: combined,
    });
    const chunks = [];
    let bytes = 0;
    reader = response.body?.getReader();
    if (reader) {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > request.max_bytes) {
          await reader.cancel();
          throw new StiffError('body_too_large', 'Response exceeds max_bytes.');
        }
        chunks.push(value);
      }
    }
    let body;
    try { body = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)); }
    catch { throw new StiffError('invalid_utf8', 'Response is not valid UTF-8.'); }
    return {
      status: response.status,
      ok: Http.is_success(response.status),
      headers: Object.fromEntries(response.headers),
      body,
    };
  } catch (error) {
    if (error instanceof StiffError) throw error;
    if (signal?.aborted) throw new StiffError('cancelled', 'Request cancelled.', { cause: error });
    if (controller.signal.aborted) throw new StiffError('timeout', 'Request deadline exceeded.', { cause: error });
    throw new StiffError('network', 'HTTP transport failed.', { cause: error });
  } finally {
    clearTimeout(deadline);
    reader?.releaseLock();
  }
}

/** Preserve HTTP status (including 4xx/5xx) alongside decoded JSON. */
export async function sendJson(request, options) {
  const response = await send(request, options);
  try { return { ...response, data: JSON.parse(response.body) }; }
  catch (error) {
    throw new StiffError('invalid_json_response', 'Response is not valid JSON.', { cause: error });
  }
}
