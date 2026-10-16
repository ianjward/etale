// Small host helpers for the JavaScript target: big integers, mutable caches
// (the parser memo and lazy field caches), fast string access, and Node I/O.
import { Ok, Error, toList } from "../gleam.mjs";

// ---- big integers (Integer is unbounded in the spec)
export const big_from_string = (s) => BigInt(s);
export const big_from_int = (n) => BigInt(n);
export const big_to_string = (a) => a.toString();
export const big_add = (a, b) => a + b;
export const big_sub = (a, b) => a - b;
export const big_mul = (a, b) => a * b;
export const big_neg = (a) => -a;
export const big_compare = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
export const big_pow10 = (n) => 10n ** BigInt(n);
export const big_rem = (a, b) => a % b;
export const big_div = (a, b) => a / b;
export const big_to_int = (a) => Number(a);

// ---- mutable stores
export const store_new = () => new Map();
export const store_get = (m, k) => (m.has(k) ? new Ok(m.get(k)) : new Error(undefined));
export const store_set = (m, k, v) => { m.set(k, v); return undefined; };
export const store_size = (m) => m.size;
export const ref_new = (v) => ({ v });
export const ref_get = (r) => r.v;
export const ref_set = (r, v) => { r.v = v; return undefined; };

// ---- strings (the language's characters are ASCII, so code units are characters)
export const char_at = (s, i) => (i < s.length ? s[i] : "");
export const starts_with_at = (s, lit, i) => s.startsWith(lit, i);
export const slice = (s, a, b) => s.slice(a, b);
export const length = (s) => s.length;
export const index_of_from = (s, sub, i) => s.indexOf(sub, i);
export const last_index_of_before = (s, sub, i) => s.lastIndexOf(sub, i);
export const count_newlines = (s, a, b) => { let n = 0; for (let i = a; i < b; i++) if (s.charCodeAt(i) === 10) n++; return n; };

// ---- clock
export const now_ms = () => (typeof performance !== "undefined" ? performance.now() : Date.now());

// ---- Node I/O (the command line); the browser workspace never calls these
let fs = null, path = null;
function node() {
  if (fs === null) {
    if (typeof process === "undefined") throw new globalThis.Error("not running on Node");
    fs = process.getBuiltinModule("node:fs");
    path = process.getBuiltinModule("node:path");
  }
  return { fs, path };
}
export function read_file(p) {
  try { return new Ok(node().fs.readFileSync(p, "utf8")); } catch { return new Error(undefined); }
}
export function write_file(p, text) {
  try { node().fs.writeFileSync(p, text); return new Ok(undefined); } catch (e) { return new Error(String(e)); }
}
export const argv = () => toList(typeof process === "undefined" ? [] : process.argv.slice(2));
export const cwd = () => (typeof process === "undefined" ? "/" : process.cwd());
export const exit = (code) => { if (typeof process !== "undefined") process.exitCode = code; return undefined; };
// the folder holding priv/ (language.sheaf and the standard library); set by bin/sheaf.mjs
export const home_dir = () => globalThis.SHEAF_HOME ?? (typeof process === "undefined" ? "/" : process.cwd());

// One record per parse node. Parse nodes are shared by every candidate that
// contains them, so a sub-record is evaluated once however many parents read it.
const node_recs = new WeakMap();
export function node_rec_get(node) {
  const r = node_recs.get(node);
  return r === undefined ? new Error(undefined) : new Ok(r);
}
export function node_rec_set(node, rec) { node_recs.set(node, rec); return undefined; }

// ASCII fast paths (language.sheaf text is ASCII by construction).
export const all_digits = (s) => /^[0-9]+$/.test(s);
export const first_is_lower = (s) => { const c = s.charCodeAt(0); return c >= 97 && c <= 122; };
export const first_is_upper = (s) => { const c = s.charCodeAt(0); return c >= 65 && c <= 90; };

// A folder's entries as (name, is folder); empty when it cannot be read.
export function list_dir(dir) {
  try {
    return toList(node().fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => !e.name.startsWith("."))
      .map((e) => [e.name, e.isDirectory()]));
  } catch (e) {
    return toList([]);
  }
}
export function is_dir(p) {
  try { return node().fs.statSync(p).isDirectory(); } catch (e) { return false; }
}

// Reference identity, for telling one record from an equal-looking one.
export function same_ref(a, b) {
  return a === b;
}
