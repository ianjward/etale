// The playground: edit Sheaf's Gleam source, compile it with the wasm Gleam
// compiler (in worker.js), and run the workspace that source builds.
const $ = (id) => document.getElementById(id);
const TEMPLATE = "tools/ide.html";
const STORE = "sheaf-playground-edits";

let base = null;          // sources.json
let current = "";         // the file in the editor
let edits = {};           // path -> edited text
let busy = false;
let lastErrors = [];      // [{path, line}]
const worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
let nextId = 0;
const waiting = new Map();
worker.onmessage = (e) => { const f = waiting.get(e.data.id); waiting.delete(e.data.id); f && f(e.data); };
const build = (edits) => new Promise((res) => { const id = ++nextId; waiting.set(id, res); worker.postMessage({ id, edits }); });

try { edits = JSON.parse(localStorage.getItem(STORE) || "{}") || {}; } catch (e) { edits = {}; }
const save = () => { try { localStorage.setItem(STORE, JSON.stringify(edits)); } catch (e) {} };

// ---- files ----------------------------------------------------------------
const pathOf = (key) => (key.endsWith(".mjs") ? "src/" + key : key === TEMPLATE ? key : "src/" + key + ".gleam");
function original(path) {
  if (path === TEMPLATE) return base.template;
  const rel = path.replace(/^src\//, "");
  if (rel.endsWith(".gleam")) return base.gleam[rel.slice(0, -6)];
  return base.js[rel];
}
const text = (path) => (path in edits ? edits[path] : original(path));
const mine = () => [...base.mine.map((f) => "src/" + f), TEMPLATE];
const editable = (path) => mine().includes(path);
const editsForWorker = () => {
  const out = {};
  for (const [p, t] of Object.entries(edits)) out[p === TEMPLATE ? p : p.replace(/^src\//, "")] = t;
  return out;
};

function fillMenu() {
  const sel = $("file");
  const opt = (p) => `<option value="${p}">${p in edits ? "● " : ""}${p}</option>`;
  const std = Object.keys(base.gleam).filter((k) => !base.mine.includes(k + ".gleam")).sort();
  sel.innerHTML =
    `<optgroup label="Sheaf">${mine().map(opt).join("")}</optgroup>` +
    `<optgroup label="Gleam standard library (read-only)">${std.map((k) => opt("src/" + k + ".gleam")).join("")}</optgroup>`;
  sel.value = current;
}

function open(path, line) {
  if (current && editable(current)) keep();
  current = path;
  const ta = $("code");
  ta.value = text(path);
  ta.readOnly = !editable(path);
  $("ro").hidden = editable(path);
  fillMenu();
  gutter();
  if (line) goLine(line);
  else ta.scrollTop = 0;
  try { localStorage.setItem(STORE + "-file", path); } catch (e) {}
}

function keep() {
  const t = $("code").value;
  if (t === original(current)) delete edits[current];
  else edits[current] = t;
  save();
}

function gutter() {
  const n = $("code").value.split("\n").length;
  const bad = new Set(lastErrors.filter((e) => e.path === current).map((e) => e.line));
  let s = "";
  for (let i = 1; i <= n; i++) s += bad.has(i) ? `<span class="err">${i}</span>\n` : i + "\n";
  $("gutter").innerHTML = s;
  $("gutter").scrollTop = $("code").scrollTop;
}

function goLine(line) {
  const ta = $("code");
  const lines = ta.value.split("\n");
  let pos = 0;
  for (let i = 0; i < Math.min(line - 1, lines.length); i++) pos += lines[i].length + 1;
  ta.focus({ preventScroll: true });
  ta.setSelectionRange(pos, pos + (lines[line - 1] || "").length);
  ta.scrollTop = Math.max(0, (line - 4) * 19);
  $("gutter").scrollTop = ta.scrollTop;
}

// ---- compile --------------------------------------------------------------
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const LOC = /\/src\/([\w/]+\.gleam):(\d+):(\d+)/g;

function show(kind, msg) {
  const html = esc(msg).replace(LOC, (_, f, l, c) => `<span class="loc" data-path="src/${f}" data-line="${l}">src/${f}:${l}:${c}</span>`);
  return `<div class="msg ${kind}">${html}</div>`;
}

async function compile() {
  if (busy) return;
  if (current && editable(current)) keep();
  fillMenu();
  busy = true;
  $("compile").disabled = true;
  status("Compiling Sheaf and the standard library with the Gleam compiler…", "");
  const t0 = performance.now();
  const r = await build(editsForWorker());
  busy = false;
  $("compile").disabled = false;
  lastErrors = [];
  const out = [];
  if (!r.ok) {
    for (const m of r.error.matchAll(LOC)) lastErrors.push({ path: "src/" + m[1], line: Number(m[2]) });
    out.push(show("error", r.error));
  }
  for (const w of r.warnings) out.push(show("warning", w));
  $("out").innerHTML = out.join("");
  gutter();
  if (!r.ok) {
    status(`Compile failed in ${Math.round(r.ms)} ms — the workspace still runs the last good build`, "bad");
    $("cover").hidden = !!$("ws").srcdoc;
    if (!$("ws").srcdoc) $("cover").querySelector(".box").innerHTML = "<b>No build yet</b><span>Fix the error on the left and compile again.</span>";
    return;
  }
  const changed = Object.keys(edits).length;
  status(`Compiled ${r.modules} modules in ${(r.ms / 1000).toFixed(2)} s, bundled ${r.bundled} in ${Math.round(r.bundle_ms)} ms · ${r.warnings.length} warning${r.warnings.length === 1 ? "" : "s"}`, "ok");
  $("ws").srcdoc = r.html;
  $("cover").hidden = true;
  const b = $("built");
  b.textContent = changed ? `built here from your source · ${changed} file${changed === 1 ? "" : "s"} changed` : "built here from Sheaf's source";
  b.hidden = false;
  void t0;
}

function status(t, cls) {
  const s = $("status");
  s.textContent = t;
  s.className = cls;
}

// ---- suggested edits ------------------------------------------------------
const TRIES = {
  slow: ["src/sheaf/ide.gleam", "const glide_ms = 700.0", "const glide_ms = 2400.0", "Click a type in another file: the canvas now glides for 2.4 s."],
  label: ["src/sheaf/ide.gleam", '    Compiled -> "compiled"\n    Proved', '    Compiled -> "compiled in your browser"\n    Proved', "Each green pane's header now says where it was compiled."],
  title: [TEMPLATE, "<h1>Sheaf</h1>", "<h1>Sheaf · built here</h1>", "The workspace tool bar shows the new title."],
  break: ["src/sheaf/ide.gleam", "const code_w = 820.0", "const code_w = 820", "An Int where a Float belongs: the compiler reports it, and the workspace keeps the last good build."],
};
for (const b of document.querySelectorAll("[data-try]")) {
  b.addEventListener("click", () => {
    const [path, from, to, note] = TRIES[b.dataset.try];
    if (current && editable(current)) keep();
    const t = text(path);
    if (!t.includes(from)) { status(t.includes(to) ? "Already applied." : "That spot has been edited; reset the file to try this.", ""); open(path); return; }
    edits[path] = t.replace(from, to);
    save();
    const line = t.slice(0, t.indexOf(from)).split("\n").length;
    open(path, line);
    compile().then(() => { if ($("status").className === "ok") status($("status").textContent + " — " + note, "ok"); });
  });
}

// ---- wiring ---------------------------------------------------------------
$("file").addEventListener("change", (e) => open(e.target.value));
$("compile").addEventListener("click", compile);
$("reset").addEventListener("click", () => {
  delete edits[current];
  $("code").value = original(current);
  save();
  open(current);
});
$("resetall").addEventListener("click", () => {
  edits = {};
  $("code").value = original(current);
  save();
  open(current);
  compile();
});
$("code").addEventListener("input", () => { gutter(); });
$("code").addEventListener("change", () => { keep(); fillMenu(); });
$("code").addEventListener("scroll", () => { $("gutter").scrollTop = $("code").scrollTop; });
$("code").addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); compile(); return; }
  if (e.key === "Tab" && !e.ctrlKey && !e.metaKey && !e.altKey && !$("code").readOnly) {
    e.preventDefault();
    document.execCommand("insertText", false, "  ");
  }
});
window.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); compile(); }
});
$("out").addEventListener("click", (e) => {
  const l = e.target.closest(".loc");
  if (l) open(l.dataset.path, Number(l.dataset.line));
});

(async () => {
  try {
    base = await (await fetch("sources.json")).json();
  } catch (e) {
    status("Could not load sources.json", "bad");
    return;
  }
  let first = "src/sheaf/ide.gleam";
  try { const f = localStorage.getItem(STORE + "-file"); if (f && (editable(f) || original(f) !== undefined)) first = f; } catch (e) {}
  open(first);
  compile();
})();
