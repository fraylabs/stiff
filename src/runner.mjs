import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import * as Bend from '../.cache/bend/bend2/bend.ts';
import * as Compiler from '../.cache/bend/bend2/comp.ts';
import { createHost } from './bend-host.mjs';

const supported = new Set(['stiff_send', 'stiff_send_json', 'io_print', 'io_write',
  'io_print_err', 'io_args', 'io_sleep']);

/** Compile standard Bend IO and interpret its operations asynchronously in Node.
 * Uses compiler internals pinned to 2.0.20; it does not alter upstream source.
 */
export async function runFile(filename, options = {}) {
  const book = Bend.book_nil();
  try {
    await Bend.book_load(book, path.resolve(filename), '', new Map());
    Bend.book_valid(book);
    Compiler.book_owned(book, Compiler.SYNTH);
    if (book.hols + book.open > 0) throw new Error('Bend program contains unresolved holes.');
    if (Compiler.io_type(book) === null) throw new Error('Expected main() -> IO(...).');
  } catch (error) {
    throw new Error(error?.$ === 'Err' ? Bend.err_show(error) : String(error));
  }
  const host = createHost(options);
  // Compiler symbol spelling and the $FFI continuation shape belong to the pin.
  // Keep this boundary together and covered by real .bend integration tests.
  const factory = new Function('host', Compiler.js_lib(book, ['main'], null) + `
    const cli_args = host.args;
    const io_bytes = text => new TextEncoder().encode(text);
    const io_out = (fd, bytes) => host.write(fd, bytes);
    return { start: () => run_loop($main$())(value => ({ $: 'Emit', value })),
      resume: (continuation, value) => run_loop(continuation(value)) };
  `);
  const program = factory(host);
  let operation = program.start();
  for (;;) {
    if (options.signal?.aborted) return 130;
    if (operation?.$ === 'Emit') return 0;
    if (operation?.$ === 'Halt') {
      host.write(2, `${operation.message}\n`);
      return operation.code;
    }
    if (operation?.$ !== '$FFI' || !supported.has(operation.run?.name)) {
      throw new Error(`Unsupported Bend IO effect: ${operation?.run?.name ?? operation?.$ ?? 'unknown'}`);
    }
    if (operation.run.name === 'io_sleep') {
      try { await sleep(operation.args[0], undefined, { signal: options.signal }); }
      catch (error) { if (options.signal?.aborted) return 130; throw error; }
    }
    const value = await operation.run(...operation.args);
    if (value === undefined) throw new Error('Unsupported parked Bend IO effect.');
    operation = program.resume(operation.kont, value);
  }
}
