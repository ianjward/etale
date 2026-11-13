// The AI pane: one pane for any model, local or hosted. A connection is a
// kind (OpenAI-compatible or Anthropic), a base URL, a model name, an
// optional key and the context to send. Interim: connections live in this
// file and in browser storage until workspace state is declared as Etale
// types.
//
// Everything above "the pane" runs without a DOM, so tools/ai_test.mjs can
// test the adapters on Node against a mock server.
//
// Keys stay in this browser's storage. They never go into files, bundles,
// exports or the page's URL.

export const KINDS = ["openai", "anthropic"];
export const CONTEXTS = ["full", "digest", "none"];
const STORE = "etale.ai.v1";

export function blank_connection() {
  return {
    id: "c" + Math.random().toString(36).slice(2, 9),
    name: "Local",
    kind: "openai",
    base: "http://localhost:11434/v1",
    model: "",
    key: "",
    context: "digest",
  };
}

// ---------------------------------------------------------------- storage

export function load_connections(storage) {
  try {
    const raw = storage && storage.getItem(STORE);
    if (!raw) return { connections: [], active: "" };
    const v = JSON.parse(raw);
    const connections = Array.isArray(v.connections) ? v.connections.filter(valid) : [];
    const active = connections.some((c) => c.id === v.active) ? v.active : connections[0]?.id ?? "";
    return { connections, active };
  } catch {
    return { connections: [], active: "" };
  }
}

export function save_connections(storage, state) {
  try {
    storage && storage.setItem(STORE, JSON.stringify(state));
    return true;
  } catch {
    return false;
  }
}

function valid(c) {
  return c && typeof c.id === "string" && KINDS.includes(c.kind) && typeof c.base === "string"
    && typeof c.model === "string" && CONTEXTS.includes(c.context);
}

// ---------------------------------------------------------------- messages

// What a message sends: the chosen context, the working file, the history and
// the new message. The context and the working file go in the system text,
// so each message sends their text as it is now.
export function build_prompt(context, spec_text, working_path, working_text) {
  const parts = [
    "You help a person write Etale, a typed language whose files declare types that texts must match.",
    "Answer about the working file below. Write Etale only in the forms the language definition uses; do not guess syntax.",
    "When you propose a change to the working file, give the whole changed file in one fenced block.",
  ];
  if (context === "full") parts.push("The language definition, language.etale:\n```\n" + spec_text + "\n```");
  if (context === "digest")
    parts.push("The language definition, language.etale, with comments and blank lines taken out:\n```\n" + spec_text + "\n```");
  parts.push("The working file, " + working_path + ":\n```\n" + working_text + "\n```");
  return parts.join("\n\n");
}

export function request(conn, system, history) {
  const base = conn.base.replace(/\/+$/, "");
  const headers = { "content-type": "application/json" };
  if (conn.kind === "anthropic") {
    if (conn.key) headers["x-api-key"] = conn.key;
    headers["anthropic-version"] = "2023-06-01";
    headers["anthropic-dangerous-direct-browser-access"] = "true";
    return {
      url: base + "/messages",
      headers,
      body: { model: conn.model, max_tokens: 4096, stream: true, system, messages: history },
    };
  }
  if (conn.key) headers.authorization = "Bearer " + conn.key;
  return {
    url: base + "/chat/completions",
    headers,
    body: { model: conn.model, stream: true, messages: [{ role: "system", content: system }, ...history] },
  };
}

// ---------------------------------------------------------------- errors

export class AiError extends Error {
  constructor(reason, message) {
    super(message);
    this.reason = reason; // unreachable | bad_key | unknown_model | http | stream | setup
  }
}

const UNREACHABLE =
  "could not reach {url}. Either nothing is running there, or it refused calls from this page (CORS). " +
  "A local server must allow this page's origin (Ollama: set OLLAMA_ORIGINS). " +
  "A hosted provider that refuses calls from a browser can be reached through a local proxy: give the proxy's URL as the base URL.";

function http_error(status, body) {
  const said = error_text(body);
  if (status === 401 || status === 403)
    return new AiError("bad_key", "the server refused the key (" + status + ")" + (said ? ": " + said : ""));
  if ((status === 404 || status === 400) && /model/i.test(said))
    return new AiError("unknown_model", "the server does not know this model (" + status + "): " + said);
  if (status === 404) return new AiError("http", "nothing at this URL (404): check the base URL" + (said ? ": " + said : ""));
  return new AiError("http", "the server answered " + status + (said ? ": " + said : ""));
}

function error_text(body) {
  try {
    const v = JSON.parse(body);
    const e = v.error ?? v;
    return String(typeof e === "string" ? e : e.message ?? body).slice(0, 300);
  } catch {
    return String(body || "").slice(0, 300);
  }
}

// ---------------------------------------------------------------- streaming

// Sends one chat and streams the reply: on_text gets the whole reply so far.
// Gives the whole reply, or throws an AiError.
export async function stream_chat(conn, system, history, { signal, on_text = () => {}, fetch_fn = fetch } = {}) {
  if (!conn.base) throw new AiError("setup", "the connection has no base URL");
  if (!conn.model) throw new AiError("setup", "the connection has no model name");
  const req = request(conn, system, history);
  let res;
  try {
    res = await fetch_fn(req.url, { method: "POST", headers: req.headers, body: JSON.stringify(req.body), signal });
  } catch (e) {
    if (e && e.name === "AbortError") throw e;
    throw new AiError("unreachable", UNREACHABLE.replace("{url}", req.url));
  }
  if (!res.ok) throw http_error(res.status, await res.text().catch(() => ""));
  const type = res.headers.get("content-type") || "";
  // a server that ignores stream: true answers with one JSON body
  if (!type.includes("event-stream")) {
    const text = one_reply(conn.kind, await res.text());
    on_text(text);
    return text;
  }
  let text = "";
  for await (const data of sse(res.body)) {
    if (data === "[DONE]") break;
    let v;
    try { v = JSON.parse(data); } catch { continue; }
    if (v.type === "error" || (v.error && !v.choices))
      throw new AiError("stream", "the server stopped with an error: " + error_text(JSON.stringify(v)));
    const piece = conn.kind === "anthropic"
      ? (v.type === "content_block_delta" && v.delta?.type === "text_delta" ? v.delta.text : "")
      : v.choices?.[0]?.delta?.content ?? "";
    if (piece) { text += piece; on_text(text); }
  }
  return text;
}

function one_reply(kind, body) {
  try {
    const v = JSON.parse(body);
    if (kind === "anthropic") return (v.content || []).filter((b) => b.type === "text").map((b) => b.text).join("");
    return v.choices?.[0]?.message?.content ?? "";
  } catch {
    throw new AiError("stream", "the server's answer was not JSON");
  }
}

// The data lines of a server-sent event stream, one event at a time.
async function* sse(body) {
  const reader = body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    buf += done ? dec.decode() : dec.decode(value, { stream: true });
    let i;
    while ((i = buf.search(/\r?\n\r?\n/)) >= 0) {
      const event = buf.slice(0, i);
      buf = buf.slice(i).replace(/^\r?\n\r?\n/, "");
      const data = event.split(/\r?\n/).filter((l) => l.startsWith("data:")).map((l) => l.slice(5).replace(/^ /, ""));
      if (data.length) yield data.join("\n");
    }
    if (done) {
      if (buf.trim()) {
        const data = buf.split(/\r?\n/).filter((l) => l.startsWith("data:")).map((l) => l.slice(5).replace(/^ /, ""));
        if (data.length) yield data.join("\n");
      }
      return;
    }
  }
}

// ---------------------------------------------------------------- the pane

let pane = null;

// Called once by the workspace. get() gives [working path, working text,
// language.etale]; digest(text) gives a Gleam Result with the digest.
export function setup_pane(get, digest) {
  if (typeof document === "undefined") return;
  const store = (() => { try { return window.localStorage; } catch { return null; } })();
  const state = load_connections(store);
  const history = [];
  let busy = null;
  let digest_cache = { spec: null, text: "" };

  const el = document.createElement("aside");
  el.id = "ai";
  el.hidden = true;
  el.setAttribute("aria-label", "AI");
  el.innerHTML = `
    <header><b>AI</b>
      <select id="ai-conn" aria-label="Connection"></select>
      <button type="button" id="ai-edit" title="Add or change connections">Connections</button>
      <button type="button" id="ai-close" aria-label="Close">×</button>
    </header>
    <form id="ai-form" hidden autocomplete="off">
      <label>Name <input id="ai-name" spellcheck="false"></label>
      <label>Kind <select id="ai-kind"><option value="openai">OpenAI-compatible</option><option value="anthropic">Anthropic</option></select></label>
      <label>Base URL <input id="ai-base" spellcheck="false" placeholder="http://localhost:11434/v1"></label>
      <label>Model <input id="ai-model" spellcheck="false" placeholder="e.g. qwen2.5-coder"></label>
      <label>Key <input id="ai-key" type="password" spellcheck="false" placeholder="none for a local server"></label>
      <label>Context <select id="ai-context"></select></label>
      <p class="note">Keys stay in this browser. They are never saved in files, bundles or exports.</p>
      <div class="row"><button type="button" id="ai-save">Save</button><button type="button" id="ai-new">New</button><button type="button" id="ai-del">Delete</button></div>
    </form>
    <div id="ai-log" role="log" aria-live="polite"></div>
    <div id="ai-ask">
      <textarea id="ai-msg" rows="3" placeholder="Ask about the working file  ·  Ctrl+Enter sends" spellcheck="true"></textarea>
      <div class="row"><span id="ai-size"></span><button type="button" id="ai-clear" title="Start a new conversation">Clear</button><button type="button" id="ai-send">Send</button></div>
    </div>`;
  document.body.appendChild(el);
  const $ = (id) => el.querySelector("#" + id);

  const active = () => state.connections.find((c) => c.id === state.active) || null;
  const spec_for = (context, spec) => {
    if (context === "full") return spec;
    if (context === "digest") {
      if (digest_cache.spec !== spec) {
        const r = digest(spec);
        digest_cache = { spec, text: r.isOk() ? r[0] : "", error: r.isOk() ? "" : r[0] };
      }
      return digest_cache.text;
    }
    return "";
  };
  const sizes = () => {
    const [, , spec] = get();
    return { full: spec.length, digest: spec_for("digest", spec).length, none: 0 };
  };
  const fmt = (n) => n.toLocaleString() + " characters";

  function fill_conns() {
    const sel = $("ai-conn");
    sel.innerHTML = "";
    if (!state.connections.length) sel.add(new Option("No connection: add one", ""));
    for (const c of state.connections) sel.add(new Option(c.name || c.model || c.base, c.id, false, c.id === state.active));
    update_size();
  }
  function fill_form(c) {
    const s = sizes();
    $("ai-context").innerHTML = "";
    $("ai-context").add(new Option("language.etale, full (" + fmt(s.full) + ")", "full"));
    $("ai-context").add(new Option("language.etale, digest (" + fmt(s.digest) + ")", "digest"));
    $("ai-context").add(new Option("none: only the working file", "none"));
    $("ai-name").value = c.name; $("ai-kind").value = c.kind; $("ai-base").value = c.base;
    $("ai-model").value = c.model; $("ai-key").value = c.key; $("ai-context").value = c.context;
    $("ai-form").dataset.id = c.id;
  }
  function update_size() {
    const c = active();
    if (!c) { $("ai-size").textContent = ""; return; }
    const [path, text, spec] = get();
    const n = spec_for(c.context, spec).length + text.length;
    $("ai-size").textContent = "sends " + fmt(n) + " of context with " + path;
  }
  function say(role, text, cls) {
    const d = document.createElement("div");
    d.className = "msg " + role + (cls ? " " + cls : "");
    d.textContent = text;
    $("ai-log").appendChild(d);
    $("ai-log").scrollTop = $("ai-log").scrollHeight;
    return d;
  }
  function persist() {
    if (!save_connections(store, state)) say("note", "This browser keeps no storage: connections last until the page closes.", "warn");
  }

  $("ai-close").onclick = () => { el.hidden = true; };
  $("ai-conn").onchange = (e) => { state.active = e.target.value; persist(); update_size(); };
  $("ai-edit").onclick = () => {
    const f = $("ai-form");
    f.hidden = !f.hidden;
    if (!f.hidden) fill_form(active() || blank_connection());
  };
  $("ai-new").onclick = () => fill_form(blank_connection());
  $("ai-save").onclick = () => {
    const c = {
      id: $("ai-form").dataset.id, name: $("ai-name").value.trim(), kind: $("ai-kind").value,
      base: $("ai-base").value.trim(), model: $("ai-model").value.trim(), key: $("ai-key").value,
      context: $("ai-context").value,
    };
    const i = state.connections.findIndex((x) => x.id === c.id);
    if (i >= 0) state.connections[i] = c; else state.connections.push(c);
    state.active = c.id;
    persist(); fill_conns(); $("ai-form").hidden = true;
  };
  $("ai-del").onclick = () => {
    const id = $("ai-form").dataset.id;
    state.connections = state.connections.filter((c) => c.id !== id);
    if (state.active === id) state.active = state.connections[0]?.id ?? "";
    persist(); fill_conns(); $("ai-form").hidden = true;
  };
  $("ai-clear").onclick = () => { history.length = 0; $("ai-log").innerHTML = ""; };
  $("ai-msg").addEventListener("keydown", (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key === "Enter") { e.preventDefault(); send(); }
  });
  $("ai-send").onclick = () => (busy ? busy.abort() : send());

  async function send() {
    const c = active();
    const msg = $("ai-msg").value.trim();
    if (!msg) return;
    if (!c) { say("note", "Add a connection first (Connections).", "warn"); return; }
    const [path, text, spec] = get();
    const spec_text = spec_for(c.context, spec);
    if (c.context === "digest" && !spec_text)
      say("note", "The digest could not be made (" + (digest_cache.error || "language.etale does not read") + "), so it is not sent.", "warn");
    const system = build_prompt(c.context, spec_text, path, text);
    history.push({ role: "user", content: msg });
    say("user", msg);
    $("ai-msg").value = "";
    const out = say("assistant", "…");
    busy = new AbortController();
    $("ai-send").textContent = "Stop";
    try {
      const reply = await stream_chat(c, system, history, { signal: busy.signal, on_text: (t) => { out.textContent = t; } });
      history.push({ role: "assistant", content: reply });
      if (!reply) out.textContent = "(no text in the reply)";
    } catch (e) {
      history.pop();
      if (e && e.name === "AbortError") out.textContent += "\n(stopped)";
      else { out.remove(); say("note", e.message || String(e), "warn"); }
    } finally {
      busy = null;
      $("ai-send").textContent = "Send";
    }
  }

  pane = { el, fill_conns, update_size };
  window.openAI = () => {
    el.hidden = !el.hidden;
    if (!el.hidden) { fill_conns(); if (!state.connections.length) $("ai-edit").click(); $("ai-msg").focus(); }
  };
}
