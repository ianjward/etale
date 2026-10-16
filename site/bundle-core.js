// Bundles Gleam's compiled ES modules into one classic script, the same way
// tools/bundle.mjs does on disk, but over an in-memory map of files so it can
// run in the browser right after the wasm Gleam compiler has compiled Sheaf.
//
//   bundle(files, entry) -> { js, count }
//   files: Map of "dir/module.mjs" -> source, every key relative to one root
//
// Gleam modules use a small fixed set of import/export forms, all handled here.

function norm(parts) {
  const out = [];
  for (const p of parts) {
    if (p === "" || p === ".") continue;
    if (p === "..") out.pop();
    else out.push(p);
  }
  return out.join("/");
}
function dir(key) {
  const i = key.lastIndexOf("/");
  return i < 0 ? "" : key.slice(0, i);
}
function resolve(from, spec) {
  return norm([...dir(from).split("/"), ...spec.split("/")]);
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

export function bundle(files, entry) {
  const modules = new Map();
  const load = (key) => {
    if (modules.has(key)) return;
    modules.set(key, null);
    let src = files.get(key);
    if (src === undefined) throw new Error("missing module " + key);
    const deps = [], exportsList = [], reexports = [];
    src = src.replace(/^import\s+([\s\S]*?)\s+from\s+"([^"]+)";?/gm, (_, what, spec) => {
      if (spec.startsWith("node:")) return `const ${bind(what)} = __node(${JSON.stringify(spec)});`;
      const t = resolve(key, spec);
      deps.push(t);
      return `const ${bind(what)} = __load(${JSON.stringify(t)});`;
    });
    src = src.replace(/^export\s+\*\s+from\s+"([^"]+)";?/gm, (_, spec) => {
      const t = resolve(key, spec);
      deps.push(t);
      reexports.push(t);
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
      exportsList.push(["default", name], [name, name]);
      return `${kw} ${name}`;
    });
    const hoisted = [];
    src = src.replace(/^export\s+(async\s+function|function|const|let|class)\s+([A-Za-z0-9_$]+)/gm, (_, kw, name) => {
      exportsList.push([name, name]);
      if (kw.endsWith("function")) hoisted.push(name);
      return `${kw} ${name}`;
    });
    const body =
      `Object.assign(__exports, {${hoisted.map((n) => `${JSON.stringify(n)}: ${n}`).join(", ")}});\n${src}\n` +
      `Object.assign(__exports, ${reexports.map((r) => `__load(${JSON.stringify(r)})`).join(", ") || "{}"}, {` +
      exportsList.map(([k, v]) => `${JSON.stringify(k)}: ${v}`).join(", ") + `});`;
    modules.set(key, body);
    for (const d of deps) load(d);
  };
  load(entry);
  let js = "(function(){\nconst __defs = {}, __cache = {};\n" +
    "function __node(n){ throw new Error('node module ' + n + ' is not available in the browser'); }\n" +
    "function __load(k){ if (k in __cache) return __cache[k]; const f = __defs[k]; if (!f) throw new Error('missing module ' + k); const m = __cache[k] = {}; f(m); return m; }\n";
  for (const [key, body] of modules) js += `__defs[${JSON.stringify(key)}] = function(__exports){\n${body}\n};\n`;
  js += `window.__sheaf = __load(${JSON.stringify(entry)});\n})();\n`;
  return { js, count: modules.size };
}

// The workspace page: the template with the example files and the bundle in.
export function workspace_html(template, filesJson, js) {
  return template
    .replace("/*__FILES__*/", () => `window.SHEAF_FILES = ${filesJson};`)
    .replace("/*__BUNDLE__*/", () => js.replace(/<\/script/gi, "<\\/script"));
}
