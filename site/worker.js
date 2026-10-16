// Runs the wasm Gleam compiler off the main thread: compiles Sheaf's sources
// (with any edits), bundles the result into a workspace page, and posts it back.
import init, * as gleam from "./compiler/gleam_wasm.js";
import { compile } from "./compile-core.js";
import { bundle, workspace_html } from "./bundle-core.js";

let ready = null;
let base = null;

async function setup() {
  const [, res] = await Promise.all([
    init({ module_or_path: new URL("./compiler/gleam_wasm_bg.wasm", import.meta.url) }),
    fetch(new URL("./sources.json", import.meta.url)),
  ]);
  gleam.initialise_panic_hook(false);
  base = await res.json();
}

self.onmessage = async (e) => {
  const { id, edits } = e.data;
  try {
    ready ??= setup();
    await ready;
    const sources = { gleam: { ...base.gleam }, js: { ...base.js }, prelude: base.prelude };
    let template = base.template;
    for (const [path, code] of Object.entries(edits || {})) {
      if (path === "tools/ide.html") template = code;
      else if (path.endsWith(".gleam")) sources.gleam[path.slice(0, -6)] = code;
      else sources.js[path] = code;
    }
    const r = compile(gleam, sources);
    if (!r.ok) {
      self.postMessage({ id, ok: false, error: r.error, warnings: r.warnings, ms: r.ms });
      return;
    }
    const t = performance.now();
    const { js, count } = bundle(r.files, base.entry);
    const html = workspace_html(template, JSON.stringify(base.files), js);
    self.postMessage({ id, ok: true, html, warnings: r.warnings, ms: r.ms, bundle_ms: performance.now() - t, modules: r.modules, bundled: count });
  } catch (err) {
    self.postMessage({ id, ok: false, error: String(err && err.stack ? err.stack : err), warnings: [], ms: 0 });
  }
};
