import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const revision = 'a5269a6b2c5ccd6752b66df4bc6f60678b4f49bc';
const destination = fileURLToPath(new URL('../.cache/bend', import.meta.url));
const git = (args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
mkdirSync(new URL('../.cache/', import.meta.url), { recursive: true });
if (!existsSync(destination)) {
  git(['clone', '--depth', '1', '--branch', 'v2.0.20',
    'https://github.com/bendlang/bend.git', destination]);
}
const actual = git(['-C', destination, 'rev-parse', 'HEAD']);
if (actual !== revision) throw new Error(`Bend source mismatch: ${actual}`);
if (git(['-C', destination, 'status', '--porcelain'])) {
  throw new Error('Bend source has local changes; use a clean pinned checkout.');
}
console.log(`Bend 2.0.20 source ready (${revision}). No global installation.`);
