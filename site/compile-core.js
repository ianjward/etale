// Compiles Sheaf's Gleam sources with the wasm build of the Gleam compiler and
// returns every compiled module, ready for bundle-core.js.
//
//   compile(gleam, sources) -> { ok, files, warnings, error, ms, modules }
//   gleam:   the initialised gleam_wasm module
//   sources: { gleam: {"sheaf/ide": code, ...}, js: {"sheaf/ide_ffi.mjs": code, ...},
//              prelude: code }
//
// Sheaf and the standard library are compiled as one package, so every module
// sits under one root: "gleam/list.mjs", "sheaf/ide.mjs", and the prelude at
// "gleam.mjs", where the compiled code looks for it.
let project = 0;

export function compile(gleam, sources) {
  const id = ++project;
  const t0 = performance.now();
  gleam.reset_filesystem(id);
  const names = Object.keys(sources.gleam);
  for (const name of names) gleam.write_module(id, name, sources.gleam[name]);
  for (const [path, code] of Object.entries(sources.js)) gleam.write_file(id, "/src/" + path, code);
  const warnings = [];
  try {
    gleam.compile_package(id, "javascript");
  } catch (e) {
    collect(gleam, id, warnings);
    gleam.delete_project(id);
    return { ok: false, error: clean(String(e && e.message ? e.message : e)), warnings, ms: performance.now() - t0 };
  }
  collect(gleam, id, warnings);
  const files = new Map();
  for (const name of names) {
    const js = gleam.read_compiled_javascript(id, name);
    if (js !== undefined) files.set(name + ".mjs", js);
  }
  for (const [path, code] of Object.entries(sources.js)) files.set(path, code);
  files.set("gleam.mjs", sources.prelude);
  gleam.delete_project(id);
  return { ok: true, files, warnings, ms: performance.now() - t0, modules: names.length };
}

function collect(gleam, id, out) {
  let w;
  while ((w = gleam.pop_warning(id)) !== undefined && out.length < 200) out.push(clean(w));
}

// The compiler colours its messages for a terminal; the page shows plain text.
function clean(s) {
  return s.replace(/\u001b\[[0-9;]*m/g, "");
}
