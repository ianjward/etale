// Bundles the ES modules that `gleam build --target javascript` writes into one
// script, so the workspace can ship as a single self-contained HTML file.
// Gleam modules never import each other in a cycle, and their import/export
// statements use a small fixed set of forms, all handled here.
//
//   node tools/bundle.mjs <entry.mjs> <template.html> <out.html> [files.json]
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";

const [entry, template, out, filesJson] = process.argv.slice(2);
const root = resolve(dirname(entry), "..");
const modules = new Map();

function load(path) {
  if (modules.has(path)) return;
  modules.set(path, null);
  let src = readFileSync(path, "utf8");
  const deps = [];
  const exportsList = [];
  const reexports = [];

  src = src.replace(/^import\s+([\s\S]*?)\s+from\s+"([^"]+)";?/gm, (_, what, spec) => {
    if (spec.startsWith("node:")) return `const ${bind(what)} = __node(${JSON.stringify(spec)});`;
    const target = resolve(dirname(path), spec);
    deps.push(target);
    return `const ${bind(what)} = __load(${JSON.stringify(key(target))});`;
  });
  src = src.replace(/^export\s+\*\s+from\s+"([^"]+)";?/gm, (_, spec) => {
    const target = resolve(dirname(path), spec);
    deps.push(target);
    reexports.push(key(target));
    return "";
  });
  src = src.replace(/^export\s+\{([^}]*)\};?/gm, (_, names) => {
    for (const n of names.split(",").map((s) => s.trim()).filter(Boolean)) {
      const m = n.match(/^(\S+)\s+as\s+(\S+)$/);
      exportsList.push(m ? [m[2], m[1]] : [n, n]);
    }
    return "";
  });
  src = src.replace(/^export\s+default\s+(class|function)\s+([A-Za-z0-9_$]+)/gm, (_, kw, name) => {
    exportsList.push(["default", name]);
    exportsList.push([name, name]);
    return `${kw} ${name}`;
  });
  const hoisted = [];
  src = src.replace(/^export\s+(async\s+function|function|const|let|class)\s+([A-Za-z0-9_$]+)/gm, (_, kw, name) => {
    exportsList.push([name, name]);
    if (kw.endsWith("function")) hoisted.push(name);
    return `${kw} ${name}`;
  });
  // Function declarations are hoisted, so they are exported before the module's
  // imports run: a module caught in an import cycle still sees them.
  const body =
    `Object.assign(__exports, {${hoisted.map((n) => `${JSON.stringify(n)}: ${n}`).join(", ")}});\n${src}\n` +
    `Object.assign(__exports, ${reexports.map((r) => `__load(${JSON.stringify(r)})`).join(", ") || "{}"}, {` +
    exportsList.map(([k, v]) => `${JSON.stringify(k)}: ${v}`).join(", ") + `});`;
  modules.set(path, body);
  for (const d of deps) load(d);
}

function key(p) {
  return relative(root, p);
}

function bind(what) {
  what = what.trim();
  const star = what.match(/^\*\s+as\s+(\S+)$/);
  if (star) return star[1];
  const braces = what.match(/^\{([\s\S]*)\}$/);
  if (braces) {
    const parts = braces[1].split(",").map((s) => s.trim()).filter(Boolean).map((n) => {
      const m = n.match(/^(\S+)\s+as\s+(\S+)$/);
      return m ? `${m[1]}: ${m[2]}` : n;
    });
    return `{ ${parts.join(", ")} }`;
  }
  throw new Error("unsupported import form: " + what);
}

load(resolve(entry));
let js = "(function(){\nconst __defs = {}, __cache = {};\n" +
  "function __node(n){ throw new Error('node module ' + n + ' is not available in the browser'); }\n" +
  "function __load(k){ if (k in __cache) return __cache[k]; const f = __defs[k]; if (!f) throw new Error('missing module ' + k); const m = __cache[k] = {}; f(m); return m; }\n";
for (const [path, body] of modules) {
  js += `__defs[${JSON.stringify(key(path))}] = function(__exports){\n${body}\n};\n`;
}
js += `window.__sheaf = __load(${JSON.stringify(key(resolve(entry)))});\n})();\n`;
const files = filesJson ? readFileSync(filesJson, "utf8") : "{}";
let html = readFileSync(template, "utf8");
html = html.replace("/*__FILES__*/", () => `window.SHEAF_FILES = ${files};`);
html = html.replace("/*__BUNDLE__*/", () => js.replace(/<\/script/gi, "<\\/script"));
writeFileSync(out, html);
console.log(`bundled ${modules.size} modules into ${out} (${(html.length / 1024).toFixed(0)} KB)`);
