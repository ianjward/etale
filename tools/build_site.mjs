// Builds the demo site into _site/:
//   index.html, workspace.html (prebuilt), playground.html and its scripts,
//   sources.json (Sheaf and standard-library sources, the workspace template,
//   the example files and the Gleam prelude) and compiler/ (the wasm Gleam
//   compiler, copied from the folder given).
//
//   node tools/build_site.mjs <gleam-browser-dir>
// Run tools/build_ide.sh first: it builds dist/workspace.html and the prelude.
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const wasmDir = process.argv[2];
if (!wasmDir) throw new Error("usage: node tools/build_site.mjs <gleam-browser-dir>");
const out = path.join(root, "_site");
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(path.join(out, "compiler"), { recursive: true });

const walk = (d, b = d) =>
  fs.readdirSync(d, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(path.join(d, e.name), b) : [path.relative(b, path.join(d, e.name))]);
const read = (p) => fs.readFileSync(p, "utf8");

const toml = read(path.join(root, "gleam.toml"));
const stdlib = path.resolve(root, toml.match(/gleam_stdlib\s*=\s*\{\s*path\s*=\s*"([^"]+)"/)[1]);
const sources = { entry: "sheaf/ide.mjs", gleam: {}, js: {}, mine: [], files: {} };
for (const [dir, mine] of [[path.join(stdlib, "src"), false], [path.join(root, "src"), true]]) {
  for (const f of walk(dir).sort()) {
    const text = read(path.join(dir, f));
    if (f.endsWith(".gleam")) sources.gleam[f.slice(0, -6)] = text;
    else if (f.endsWith(".mjs")) sources.js[f] = text;
    else continue;
    if (mine) sources.mine.push(f);
  }
}
sources.prelude = read(path.join(root, "build/dev/javascript/prelude.mjs"));
sources.template = read(path.join(root, "tools/ide.html"));
for (const d of ["priv", "examples"])
  for (const f of walk(path.join(root, d)).sort())
    if (f.endsWith(".sheaf") || f.endsWith(".txt")) sources.files["/" + d + "/" + f] = read(path.join(root, d, f));
fs.writeFileSync(path.join(out, "sources.json"), JSON.stringify(sources));

for (const f of fs.readdirSync(path.join(root, "site"))) fs.copyFileSync(path.join(root, "site", f), path.join(out, f));
fs.copyFileSync(path.join(root, "dist/workspace.html"), path.join(out, "workspace.html"));
for (const f of ["gleam_wasm.js", "gleam_wasm_bg.wasm"]) fs.copyFileSync(path.join(wasmDir, f), path.join(out, "compiler", f));
fs.writeFileSync(path.join(out, ".nojekyll"), "");
const kb = (p) => (fs.statSync(path.join(out, p)).size / 1024).toFixed(0) + " KB";
console.log(`_site: sources.json ${kb("sources.json")}, workspace.html ${kb("workspace.html")}, ${sources.mine.length} Sheaf source files`);
