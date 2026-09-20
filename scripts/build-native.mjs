import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import * as Bend from '../.cache/bend/bend2/bend.ts';
import * as Compiler from '../.cache/bend/bend2/comp.ts';

const [input, output, option] = process.argv.slice(2);
if (!input || !output || (option && option !== '--emit-only')) {
  throw new Error('Usage: node scripts/build-native.mjs program.bend output [--emit-only]');
}
const book = Bend.book_nil();
const seen = new Map();
try {
  await Bend.book_load(book, path.resolve(input), '', seen);
  Bend.book_valid(book);
  Compiler.book_owned(book, Compiler.SYNTH);
  if (book.hols + book.open > 0) throw new Error('Bend program contains unresolved holes.');
  if (Compiler.io_type(book) === null) throw new Error('Expected main() -> IO(...).');
  const target = path.resolve(output);
  const source = target + '.c';
  const dependencies = new Set([...seen.keys(), ...Object.values(book.tlds).flatMap(t =>
    t.$ === 'Def' && t.i ? t.i.map(file => fs.realpathSync(file)) : [])]);
  for (const file of [target, source]) {
    const resolved = fs.existsSync(file) ? fs.realpathSync(file) : file;
    if (dependencies.has(resolved)) throw new Error('Refusing to overwrite program source.');
  }
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(source, Compiler.compile_book(book));
  if (option !== '--emit-only') {
    const flags = execFileSync('pkg-config', ['--cflags', '--libs', 'libcurl', 'json-c'], { encoding: 'utf8' }).trim().split(/\s+/);
    const instrumentation = process.env.STIFF_NATIVE_SANITIZE === '1'
      ? ['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] : ['-O2'];
    execFileSync(process.env.CC || 'clang', ['-std=c11', ...instrumentation, source, '-lpthread', '-lm',
      ...flags, '-o', target], { stdio: 'inherit' });
    console.log(`Built ${output}. Runtime requires libcurl and json-c; no Node runtime.`);
  }
} catch (error) {
  console.error(error?.$ === 'Err' ? Bend.err_show(error) : error.message ?? String(error));
  process.exitCode = 1;
}
