import { send, StiffError } from './node.mjs';

function list(values) {
  let result = { $: 'Nil' };
  for (let i = values.length - 1; i >= 0; i--) {
    result = { $: 'Con', head: values[i], tail: result };
  }
  return result;
}

/** JSON uses Node's number semantics; nesting is limited at the Bend boundary. */
export function toBendJson(value, depth = 0) {
  if (depth > 128) throw new StiffError('json_too_deep', 'JSON nesting exceeds 128 levels.');
  if (value === null) return { $: 'JsonNull' };
  if (typeof value === 'string') return { $: 'JsonString', value };
  if (typeof value === 'boolean') return { $: 'JsonBool', value };
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new StiffError('json_number_range', 'JSON number is outside the host finite range.');
    return { $: 'JsonNumber', decimal: String(value) };
  }
  if (Array.isArray(value)) {
    return { $: 'JsonArray', items: list(value.map(item => toBendJson(item, depth + 1))) };
  }
  return { $: 'JsonObject', entries: list(Object.entries(value).map(([key, item]) =>
    ({ $: 'Tuple', fst: key, snd: toBendJson(item, depth + 1) }))) };
}

export function createHost({ signal, args = [], stdout = process.stdout, stderr = process.stderr } = {}) {
  const errorResult = (error, tag) => {
    // Programming/runner errors must fail the process, not masquerade as transport errors.
    if (!(error instanceof StiffError)) throw error;
    return { $: tag, code: error.code, message: error.message };
  };
  return {
    args,
    signal,
    write(fd, data) { (fd === 2 ? stderr : stdout).write(data); },
    parseJson(text) {
      let value;
      try { value = JSON.parse(text); }
      catch { return { $: 'JsonFailure', code: 'invalid_json_response', message: 'Response is not valid JSON.' }; }
      try { return { $: 'JsonDone', value: toBendJson(value) }; }
      catch (error) { return errorResult(error, 'JsonFailure'); }
    },
    async send(request) {
      try {
        const response = await send(request, { signal });
        return { $: 'HttpOk', response: { $: 'Response', status: response.status, body: response.body } };
      } catch (error) { return errorResult(error, 'HttpError'); }
    },
  };
}
