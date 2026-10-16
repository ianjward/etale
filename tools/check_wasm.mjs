// Compiles Sheaf with the WebAssembly build of the Gleam compiler, exactly as
// the playground does, and bundles the result: CI fails if the playground's
// compiler could not build this source.
//
//   node tools/check_wasm.mjs <gleam-browser-dir>     (after tools/build_site.mjs)
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const dir = path.resolve(process.argv[2]);
const gleam = await import(path.join(dir, "gleam_wasm.js"));
gleam.initSync({ module: fs.readFileSync(path.join(dir, "gleam_wasm_bg.wasm")) });
gleam.initialise_panic_hook(false);
const { compile } = await import(path.join(root, "site/compile-core.js"));
const { bundle, workspace_html } = await import(path.join(root, "site/bundle-core.js"));
const base = JSON.parse(fs.readFileSync(path.join(root, "_site/sources.json"), "utf8"));
const r = compile(gleam, base);
if (!r.ok) {
  console.error(r.error);
  process.exit(1);
}
const { js, count } = bundle(r.files, base.entry);
const html = workspace_html(base.template, JSON.stringify(base.files), js);
console.log(`wasm compiler: ${r.modules} modules in ${Math.round(r.ms)} ms, ${count} bundled, ${(html.length / 1024).toFixed(0)} KB, ${r.warnings.length} warnings`);
