import { runFile } from '../src/runner.mjs';

const [file, ...args] = process.argv.slice(2);
if (!file || file === '--help') {
  console.error('Usage: npm run bend -- program.bend [arguments...]');
  process.exitCode = file === '--help' ? 0 : 2;
} else {
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.on('SIGINT', interrupt);
  try {
    process.exitCode = await runFile(file, { args, signal: controller.signal });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    process.off('SIGINT', interrupt);
  }
}
