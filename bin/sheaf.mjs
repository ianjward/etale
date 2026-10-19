#!/usr/bin/env node
// Launcher: run the compiled Gleam command line from anywhere.
//   node bin/sheaf.mjs check examples/orders.sheaf
//
// The parser and evaluator recurse once per level of nested data, so the work
// runs in a worker thread with a large stack: deeply nested values (a chain of
// thousands of links) parse instead of overflowing the default stack.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker, isMainThread, workerData } from "node:worker_threads";

const home = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const STACK_MB = 512;

if (isMainThread) {
  // a closed pipe (e.g. piping into head) ends output quietly
  for (const s of [process.stdout, process.stderr])
    s.on("error", (e) => { if (e.code === "EPIPE") process.exit(process.exitCode ?? 0); else throw e; });
  const worker = new Worker(fileURLToPath(import.meta.url), {
    argv: process.argv.slice(2),
    workerData: { home },
    resourceLimits: { stackSizeMb: STACK_MB },
    stdout: false,
    stderr: false,
  });
  worker.on("message", (m) => { if (m && typeof m.exit === "number") process.exitCode = m.exit; });
  worker.on("error", (e) => { console.error(e); process.exitCode = 1; });
} else {
  globalThis.SHEAF_HOME = workerData.home;
  const { parentPort } = await import("node:worker_threads");
  const { main } = await import(resolve(workerData.home, "build/dev/javascript/etale/sheaf.mjs"));
  main();
  parentPort.postMessage({ exit: process.exitCode ?? 0 });
}
