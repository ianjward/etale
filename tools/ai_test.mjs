// Tests the AI pane's adapters against a mock server on localhost: both
// kinds, streaming and not, and each error the pane names. Run by CI:
//   node tools/ai_test.mjs
import http from "node:http";
import assert from "node:assert/strict";
import {
  stream_chat, build_prompt, request, load_connections, save_connections, blank_connection,
} from "../src/etale/ai_ffi.mjs";

const seen = [];
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const json = body ? JSON.parse(body) : {};
    seen.push({ url: req.url, headers: req.headers, body: json });
    const model = json.model;
    const sse = (events) => {
      res.writeHead(200, { "content-type": "text/event-stream" });
      for (const e of events) res.write(e);
      res.end();
    };
    if (model === "bad-key") { res.writeHead(401, { "content-type": "application/json" }); return res.end('{"error":{"message":"invalid api key"}}'); }
    if (model === "missing") { res.writeHead(404, { "content-type": "application/json" }); return res.end('{"error":{"message":"model \\"missing\\" not found"}}'); }
    if (model === "teapot") { res.writeHead(500); return res.end("boom"); }
    if (req.url === "/v1/chat/completions") {
      if (model === "plain") { res.writeHead(200, { "content-type": "application/json" }); return res.end('{"choices":[{"message":{"content":"one body"}}]}'); }
      if (model === "fails") return sse(['data: {"choices":[{"delta":{"content":"par"}}]}\n\n', 'data: {"error":{"message":"overloaded"}}\n\n']);
      return sse([
        'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n',
        // one event split across two writes
        'data: {"choices":[{"delta":{"con', 'tent":"lo"}}]}\r\n\r\n',
        "data: [DONE]\n\n",
      ]);
    }
    if (req.url === "/v1/messages") {
      if (model === "plain") { res.writeHead(200, { "content-type": "application/json" }); return res.end('{"content":[{"type":"text","text":"one body"}]}'); }
      if (model === "fails") return sse(['event: error\ndata: {"type":"error","error":{"message":"overloaded"}}\n\n']);
      return sse([
        'event: message_start\ndata: {"type":"message_start"}\n\n',
        'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}\n\n',
        'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}\n\n',
        'event: message_stop\ndata: {"type":"message_stop"}\n\n',
      ]);
    }
    res.writeHead(404); res.end("no route");
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/v1`;
const conn = (kind, model, key = "") => ({ ...blank_connection(), kind, base, model, key });
const hist = [{ role: "user", content: "hi" }];
let passed = 0;
async function test(name, f) {
  try { await f(); passed++; console.log("ok    " + name); }
  catch (e) { console.log("FAIL  " + name + "\n      " + (e.stack || e)); process.exitCode = 1; }
}
async function reason(p) {
  try { await p; return "none"; } catch (e) { return e.reason || e.name; }
}

for (const kind of ["openai", "anthropic"]) {
  await test(kind + ": streams the reply", async () => {
    const parts = [];
    const text = await stream_chat(conn(kind, "m", "k1"), "SYS", hist, { on_text: (t) => parts.push(t) });
    assert.equal(text, "Hello");
    assert.deepEqual(parts, ["Hel", "Hello"]);
  });
  await test(kind + ": sends the system text, history and key", async () => {
    const got = seen.at(-1);
    if (kind === "openai") {
      assert.equal(got.url, "/v1/chat/completions");
      assert.equal(got.headers.authorization, "Bearer k1");
      assert.deepEqual(got.body.messages, [{ role: "system", content: "SYS" }, ...hist]);
    } else {
      assert.equal(got.url, "/v1/messages");
      assert.equal(got.headers["x-api-key"], "k1");
      assert.equal(got.headers["anthropic-dangerous-direct-browser-access"], "true");
      assert.equal(got.body.system, "SYS");
      assert.deepEqual(got.body.messages, hist);
    }
    assert.equal(got.body.stream, true);
  });
  await test(kind + ": a reply that is not streamed", async () => {
    assert.equal(await stream_chat(conn(kind, "plain"), "S", hist), "one body");
  });
  await test(kind + ": bad key", async () => assert.equal(await reason(stream_chat(conn(kind, "bad-key"), "S", hist)), "bad_key"));
  await test(kind + ": unknown model", async () => assert.equal(await reason(stream_chat(conn(kind, "missing"), "S", hist)), "unknown_model"));
  await test(kind + ": other server error", async () => assert.equal(await reason(stream_chat(conn(kind, "teapot"), "S", hist)), "http"));
  await test(kind + ": error in the stream", async () => assert.equal(await reason(stream_chat(conn(kind, "fails"), "S", hist)), "stream"));
}

await test("no key: no key header", async () => {
  await stream_chat(conn("openai", "m"), "S", hist);
  assert.equal(seen.at(-1).headers.authorization, undefined);
  assert.equal(request(conn("anthropic", "m"), "S", hist).headers["x-api-key"], undefined);
});
await test("a trailing slash on the base URL", async () => {
  assert.equal(request({ ...conn("openai", "m"), base: base + "/" }, "S", hist).url, base + "/chat/completions");
});
await test("unreachable: names CORS and a local proxy", async () => {
  const c = { ...conn("openai", "m"), base: "http://127.0.0.1:9/v1" };
  try { await stream_chat(c, "S", hist); assert.fail("no error"); }
  catch (e) { assert.equal(e.reason, "unreachable"); assert.match(e.message, /CORS/); assert.match(e.message, /proxy/); }
});
await test("no model name", async () => assert.equal(await reason(stream_chat(conn("openai", ""), "S", hist)), "setup"));
await test("stop: a send can be aborted", async () => {
  const a = new AbortController();
  a.abort();
  assert.equal(await reason(stream_chat(conn("openai", "m"), "S", hist, { signal: a.signal })), "AbortError");
});
await test("the prompt holds what the context setting says", () => {
  const full = build_prompt("full", "SPEC", "a.etale", "FILE");
  assert.match(full, /SPEC/); assert.match(full, /a\.etale/); assert.match(full, /FILE/);
  assert.doesNotMatch(build_prompt("none", "SPEC", "a.etale", "FILE"), /SPEC/);
  assert.match(build_prompt("digest", "DIG", "a.etale", "FILE"), /comments and blank lines taken out/);
});
await test("connections: saved and read back; bad entries dropped", () => {
  const mem = new Map();
  const storage = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) };
  const c = conn("anthropic", "m", "secret");
  assert.ok(save_connections(storage, { connections: [c, { id: 3 }], active: c.id }));
  const back = load_connections(storage);
  assert.deepEqual(back.connections, [c]);
  assert.equal(back.active, c.id);
  assert.deepEqual(load_connections({ getItem: () => "{not json" }), { connections: [], active: "" });
  assert.equal(save_connections({ setItem: () => { throw new Error("full"); } }, back), false);
});

server.close();
console.log(`\n${passed} passed`);
