// Browser runtime for the workspace. Gleam owns all state and decides what to
// draw; this file only owns the canvas, the DOM panels that hold editable text,
// and the event wiring. Every frame is requestAnimationFrame-driven.
import { toList } from "../gleam.mjs";

let app = null;
let model = null;
let ctx = null;

export function start(application, files) {
  app = application;
  const stage = document.getElementById("stage");
  const canvas = document.createElement("canvas");
  canvas.id = "canvas";
  stage.appendChild(canvas);
  const dom = document.createElement("div");
  dom.id = "world-dom";
  stage.appendChild(dom);
  const g = canvas.getContext("2d");
  ctx = { canvas, g, dom, cam: { x: 0, y: 0, z: 1 }, panels: new Map(), seen: new Set(), dpr: 1, w: 0, h: 0,
          fonts: {}, info: document.getElementById("info"), status: document.getElementById("status") };
  resize();
  const t = document.documentElement.dataset.theme;
  const dark = t ? t === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const list = toList(Object.entries(files).map(([k, v]) => [k, v]));
  model = app.init(ctx.w, ctx.h, dark, reduced, list);
  wire(canvas);
  document.fonts?.ready?.then(() => { ctx.fonts = {}; });
  requestAnimationFrame(loop);
  return undefined;
}

function resize() {
  const dpr = window.devicePixelRatio || 1;
  const r = ctx.canvas.parentElement.getBoundingClientRect();
  ctx.dpr = dpr;
  ctx.w = r.width;
  ctx.h = r.height;
  ctx.canvas.width = Math.round(r.width * dpr);
  ctx.canvas.height = Math.round(r.height * dpr);
  ctx.canvas.style.width = r.width + "px";
  ctx.canvas.style.height = r.height + "px";
}

function loop(t) {
  try {
    model = app.frame(model, t);
    ctx.seen = new Set();
    app.view(model, ctx);
    // panes that are no longer drawn fade out, then go
    const now = performance.now();
    for (const [id, el] of ctx.panels) {
      if (ctx.seen.has(id)) continue;
      if (!el.dataset.leaving) {
        el.dataset.leaving = String(now);
        el.style.opacity = "0";
        el.style.pointerEvents = "none";
      } else if (now - Number(el.dataset.leaving) > 300) {
        el.remove();
        ctx.panels.delete(id);
      }
    }
  } catch (e) {
    console.error(e);
  }
  requestAnimationFrame(loop);
}

function local(e) {
  const r = ctx.canvas.getBoundingClientRect();
  return [e.clientX - r.left, e.clientY - r.top];
}

function wire(canvas) {
  const stage = canvas.parentElement;
  // the canvas never scrolls, even when the browser brings a focused or
  // clicked element into view: the camera alone decides what is shown
  for (const box of [stage, ctx.dom]) box.addEventListener("scroll", () => { box.scrollLeft = 0; box.scrollTop = 0; });
  stage.addEventListener("pointerdown", (e) => {
    const head = e.target.closest && e.target.closest("[data-drag]");
    if (e.target.closest && e.target.closest("textarea, pre, button, select, input") && !head) return;
    const [x, y] = local(e);
    model = app.down(model, x, y, e.button, head ? head.dataset.drag : "", e.shiftKey);
    stage.setPointerCapture(e.pointerId);
    if (!head) e.preventDefault();
  });
  stage.addEventListener("pointermove", (e) => {
    const [x, y] = local(e);
    model = app.move(model, x, y);
  });
  const up = (e) => {
    const [x, y] = local(e);
    model = app.up(model, x, y);
  };
  stage.addEventListener("pointerup", up);
  stage.addEventListener("pointercancel", up);
  stage.addEventListener("dblclick", (e) => {
    if (e.target.closest && e.target.closest(".panel")) return;
    const [x, y] = local(e);
    model = app.command(model, `dbl:${x}:${y}`);
  });
  // The canvas never scrolls. Ctrl+wheel zooms it; a plain wheel scrolls the
  // pane under the pointer, up and down only, and does nothing elsewhere.
  window.addEventListener("wheel", (e) => {
    const k = e.deltaMode === 1 ? 16 : 1;
    if (e.ctrlKey || e.metaKey) {
      e.preventDefault();
      const [x, y] = local(e);
      model = app.wheel(model, e.deltaX * k, e.deltaY * k, x, y, true);
      return;
    }
    const pane = e.target.closest && e.target.closest("textarea, pre, #card, #info");
    if (pane) {
      if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) e.preventDefault();
      return;
    }
    if (e.target.closest && e.target.closest("#stage")) e.preventDefault();
  }, { passive: false });
  setup_card();
  setup_search();
  fit_font();
  document.fonts?.ready?.then(fit_font);
  window.addEventListener("keydown", (e) => {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && (e.key === "f" || e.key === "F")) {
      // the pane being typed in or pointed at gets a find bar; otherwise the canvas search
      const pane = (e.target.closest && e.target.closest("section.panel")) || lastPane;
      e.preventDefault();
      if (pane && document.body.contains(pane) && pane.style.opacity !== "0") open_find(pane);
      else focus_search();
      return;
    }
    if (mod && (e.key === "k" || e.key === "K")) { e.preventDefault(); focus_search(); return; }
    if (e.key === "/" && !(e.target.closest && e.target.closest("textarea, input, select"))) { e.preventDefault(); focus_search(); return; }
    if (e.altKey && (e.key === "ArrowLeft" || e.key === "ArrowRight")) {
      e.preventDefault();
      model = app.command(model, e.key === "ArrowLeft" ? "back" : "forward");
      return;
    }
    if (e.target.closest && e.target.closest("textarea, input, select")) return;
    if ((e.key === "n" || e.key === "N") && !mod && !e.altKey && window.openNewFile) { e.preventDefault(); window.openNewFile(); return; }
    model = app.key(model, e.key);
  });
  // the mouse's own back and forward buttons
  window.addEventListener("mouseup", (e) => {
    if (e.button === 3 || e.button === 4) {
      e.preventDefault();
      model = app.command(model, e.button === 3 ? "back" : "forward");
    }
  });
  window.addEventListener("resize", () => { resize(); model = app.resize(model, ctx.w, ctx.h); });
  window.__ide = { command: (name) => { model = app.command(model, name); } };
}

// ---------------------------------------------------------------- drawing

function font(f) {
  return f;
}

export function clear(c, color) {
  const g = c.g;
  g.setTransform(c.dpr, 0, 0, c.dpr, 0, 0);
  g.fillStyle = color;
  g.fillRect(0, 0, c.w, c.h);
  return undefined;
}

export function world(c, x, y, z) {
  c.cam = { x, y, z };
  c.g.setTransform(c.dpr * z, 0, 0, c.dpr * z, -x * z * c.dpr, -y * z * c.dpr);
  return undefined;
}

export function screen(c) {
  c.g.setTransform(c.dpr, 0, 0, c.dpr, 0, 0);
  return undefined;
}

export function rect(c, x, y, w, h, r, fill, stroke, lw, dash) {
  const g = c.g;
  g.beginPath();
  if (r > 0 && g.roundRect) g.roundRect(x, y, w, h, r); else g.rect(x, y, w, h);
  if (fill) { g.fillStyle = fill; g.fill(); }
  if (stroke) {
    g.setLineDash(dash > 0 ? [dash, dash * 0.8] : []);
    g.strokeStyle = stroke; g.lineWidth = lw; g.stroke();
    g.setLineDash([]);
  }
  return undefined;
}

export function curve(c, x1, y1, cx1, cy1, cx2, cy2, x2, y2, color, lw, dash, offset) {
  const g = c.g;
  g.beginPath();
  g.moveTo(x1, y1);
  g.bezierCurveTo(cx1, cy1, cx2, cy2, x2, y2);
  g.setLineDash(dash > 0 ? [dash, dash] : []);
  g.lineDashOffset = offset;
  g.strokeStyle = color;
  g.lineWidth = lw;
  g.stroke();
  g.setLineDash([]);
  return undefined;
}

export function circle(c, x, y, r, fill, stroke, lw) {
  const g = c.g;
  g.beginPath();
  g.arc(x, y, r, 0, Math.PI * 2);
  if (fill) { g.fillStyle = fill; g.fill(); }
  if (stroke) { g.strokeStyle = stroke; g.lineWidth = lw; g.stroke(); }
  return undefined;
}

export function arrow(c, x, y, angle, size, color) {
  const g = c.g;
  g.save();
  g.translate(x, y);
  g.rotate(angle);
  g.beginPath();
  g.moveTo(0, 0);
  g.lineTo(-size, -size * 0.55);
  g.lineTo(-size, size * 0.55);
  g.closePath();
  g.fillStyle = color;
  g.fill();
  g.restore();
  return undefined;
}

export function text(c, x, y, s, f, color, align, max_w) {
  const g = c.g;
  g.font = font(f);
  g.fillStyle = color;
  g.textAlign = align;
  g.textBaseline = "alphabetic";
  let out = s;
  if (max_w > 0 && g.measureText(out).width > max_w) {
    let lo = 0, hi = out.length;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (g.measureText(s.slice(0, mid) + "…").width <= max_w) lo = mid; else hi = mid - 1;
    }
    out = s.slice(0, lo) + "…";
  }
  g.fillText(out, x, y);
  return undefined;
}

export function measure(c, f, s) {
  c.g.font = font(f);
  return c.g.measureText(s).width;
}

export function dots(c, x0, y0, x1, y1, step, r, color) {
  const g = c.g;
  g.fillStyle = color;
  const sx = Math.floor(x0 / step) * step, sy = Math.floor(y0 / step) * step;
  for (let x = sx; x <= x1; x += step) for (let y = sy; y <= y1; y += step) g.fillRect(x - r, y - r, r * 2, r * 2);
  return undefined;
}

// ---------------------------------------------------------------- DOM panels in world space

function esc(s) {
  return String(s).replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[ch]);
}

// Explore mode: the file as read-only text with its type names as links.
// Comments and strings are coloured and never linked.
function explore_html(body, links, mark, notes) {
  const byLine = new Map();
  for (const [n, cls, label] of notes || []) {
    const cur = byLine.get(n) || [[], ""];
    cur[0].push(cls);
    if (label) cur[1] = label;
    byLine.set(n, cur);
  }
  const known = new Set(links);
  const lines = body.split("\n");
  return lines.map((line, i) => {
    let out = "", k = 0, inStr = false;
    while (k < line.length) {
      const ch = line[k];
      if (!inStr && ch === "#" && (k === 0 || line[k - 1] === " ")) {
        out += `<span class="cm">${esc(line.slice(k))}</span>`;
        k = line.length;
        break;
      }
      if (ch === '"') {
        let e = k + 1;
        while (e < line.length && line[e] !== '"') e += line[e] === "\\" ? 2 : 1;
        out += `<span class="str">${esc(line.slice(k, e + 1))}</span>`;
        k = e + 1;
        continue;
      }
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(line.slice(k));
      if (m && (k === 0 || !/[A-Za-z0-9_]/.test(line[k - 1]))) {
        const w = m[0];
        if (/^[A-Z]/.test(w) && known.has(w)) out += `<span class="ty" data-type="${esc(w)}">${esc(w)}</span>`;
        else out += esc(w);
        k += w.length;
        continue;
      }
      const n = /^\d+(\.\d+)?/.exec(line.slice(k));
      if (n && (k === 0 || !/[A-Za-z0-9_]/.test(line[k - 1]))) {
        out += `<span class="num">${esc(n[0])}</span>`;
        k += n[0].length;
        continue;
      }
      out += esc(ch);
      k += 1;
    }
    const note = byLine.get(i + 1);
    const cls = (i + 1 === mark ? " hl" : "") + (note ? " " + note[0].join(" ") : "");
    const chip = note && note[1] ? `<span class="back" data-cmd="back" title="Go back (Alt+←)">${esc(note[1])}</span>` : "";
    return `<span class="ln${cls}">${out}${chip}</span>`;
  }).join("");
}

// A pane is 820px wide: 12px padding and a 2px border each side leave 792px,
// which must hold exactly 100 characters, the longest line the grammar allows.
const PANE_TEXT_W = 792;
let charW = 7.92;
function measure_ch(px) {
  const m = document.createElement("span");
  m.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font-size:${px}px;font-family:var(--font-code)`;
  m.textContent = "0".repeat(100);
  document.body.appendChild(m);
  const w = m.getBoundingClientRect().width / 100;
  m.remove();
  return w;
}
function fit_font() {
  const per = measure_ch(100) / 100;
  if (!per) return;
  const size = Math.floor((PANE_TEXT_W / 100 / per) * 100) / 100;
  document.documentElement.style.setProperty("--code-size", size + "px");
  charW = measure_ch(size);
}
function char_width() {
  return charW;
}

export function panel(c, id, kind, x, y, w, h, title, body, status, state, opacity, buttons, scroll_line, readonly, editing, links, notes) {
  c.seen.add(id);
  let el = c.panels.get(id);
  if (!el) {
    el = document.createElement("section");
    el.className = "panel " + kind;
    el.innerHTML = `<header data-drag="${esc(id)}"><span class="t"></span><span class="s"></span><span class="b"></span></header><textarea spellcheck="false" autocomplete="off" autocapitalize="off" wrap="off"></textarea><pre class="explore" tabindex="-1"></pre><div class="find" hidden><label class="sr" for="find-${esc(id)}">Find in this file</label><input id="find-${esc(id)}" placeholder="Find in this file" autocomplete="off" spellcheck="false"><span class="fc">0/0</span><button type="button" data-d="-1" title="Previous (Shift+Enter)" aria-label="Previous match">↑</button><button type="button" data-d="1" title="Next (Enter)" aria-label="Next match">↓</button><button type="button" data-x title="Close (Esc)" aria-label="Close find">×</button></div>`;
    const ta = el.querySelector("textarea");
    const pre = el.querySelector("pre");
    ta.value = body;
    let timer = null;
    const flush = () => { clearTimeout(timer); model = app.edit(model, id, ta.value); };
    ta.addEventListener("input", () => {
      // the outline turns yellow at the first key, not after the pause
      if (kind !== "probe") model = app.command(model, "dirty:" + id);
      clearTimeout(timer);
      timer = setTimeout(() => { model = app.edit(model, id, ta.value); }, 180);
    });
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Tab") {
        e.preventDefault();
        const s = ta.selectionStart;
        ta.setRangeText("  ", s, ta.selectionEnd, "end");
        ta.dispatchEvent(new Event("input"));
      }
      // Ctrl/Cmd+Enter compiles this file now, whatever is still pending
      if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && kind !== "probe") {
        e.preventDefault();
        flush();
        model = app.command(model, "compile:" + id);
      }
      // Esc goes back to exploring
      if (e.key === "Escape" && kind !== "probe") {
        e.preventDefault();
        flush();
        model = app.command(model, "explore:" + id);
      }
    });
    // explore: type names are links; double-click edits at that spot
    pre.addEventListener("click", (e) => {
      const back = e.target.closest && e.target.closest(".back");
      if (back) { e.stopPropagation(); model = app.command(model, "back"); return; }
      const t = e.target.closest && e.target.closest(".ty");
      if (!t) {
        const ln = e.target.closest && e.target.closest(".ln");
        if (ln) model = app.command(model, "pick:" + id + ":" + (Array.prototype.indexOf.call(pre.children, ln) + 1));
        return;
      }
      if (t) {
        e.stopPropagation();
        const ln = t.closest(".ln");
        const line = ln ? Array.prototype.indexOf.call(pre.children, ln) + 1 : 1;
        // no preview for the link just followed, until the pointer moves on
        pre.dataset.quiet = t.dataset.type;
        model = app.command(model, "hovertype:");
        model = app.command(model, "goto:" + t.dataset.type + ":" + id + ":" + line);
      }
    });
    pre.addEventListener("pointerdown", (e) => { if (e.target.closest && e.target.closest(".ty, .back")) e.stopPropagation(); });
    pre.addEventListener("mouseover", (e) => {
      const t = e.target.closest && e.target.closest(".ty");
      if (t && pre.dataset.quiet === t.dataset.type) return;
      if (!t) { delete pre.dataset.quiet; card_hide_soon(); return; }
      clearTimeout(cardTimer);
      const r = t.getBoundingClientRect();
      const st = c.canvas.getBoundingClientRect();
      const ln = t.closest(".ln");
      cardFrom = id + ":" + (ln ? Array.prototype.indexOf.call(pre.children, ln) + 1 : 1);
      cardType = t.dataset.type;
      model = app.command(model, "hovertype:" + t.dataset.type + ":" + (r.left - st.left) + ":" + (r.bottom - st.top));
    });
    pre.addEventListener("mouseleave", () => { delete pre.dataset.quiet; card_hide_soon(); });
    pre.addEventListener("dblclick", (e) => {
      if (el.dataset.readonly === "1" || kind === "probe") return;
      e.preventDefault();
      e.stopPropagation();
      const r = pre.getBoundingClientRect();
      const z = c.cam.z || 1;
      const lineIx = Math.max(0, Math.floor(((e.clientY - r.top) / z + pre.scrollTop - 10) / 17));
      const col = Math.max(0, Math.round(((e.clientX - r.left) / z + pre.scrollLeft - 12) / char_width()));
      const lines = ta.value.split("\n");
      let off = 0;
      for (let k = 0; k < Math.min(lineIx, lines.length); k++) off += lines[k].length + 1;
      if (lineIx < lines.length) off += Math.min(col, lines[lineIx].length);
      el.dataset.caret = String(Math.min(off, ta.value.length));
      el.dataset.scrollTop = String(pre.scrollTop);
      el.dataset.scrollLeft = String(pre.scrollLeft);
      model = app.command(model, "edit:" + id);
    });
    if (kind === "code") {
      // hovering a line of code shows what it draws on
      for (const area of [ta, pre]) {
        let last = -1;
        area.addEventListener("mousemove", (e) => {
          const r = area.getBoundingClientRect();
          const z = c.cam.z || 1;
          const line = Math.floor(((e.clientY - r.top) / z + area.scrollTop - 10) / 17) + 1;
          if (line !== last) {
            last = line;
            const top = el.getBoundingClientRect().top;
            const yy = ((r.top - top) / z) + 10 + (line - 1) * 17 - area.scrollTop + 8.5;
            model = app.command(model, "codeline:" + line + ":" + yy);
          }
        });
        area.addEventListener("scroll", () => { last = -1; });
        area.addEventListener("mouseleave", () => { last = -1; model = app.command(model, "codeline:0"); });
      }
    }
    setup_find(el);
    el.addEventListener("mouseenter", () => { lastPane = el; model = app.command(model, "over:" + id); });
    el.addEventListener("mouseleave", () => { model = app.command(model, "over:"); });
    // every pane fades in when it arrives
    el.style.opacity = "0";
    el.dataset.born = "1";
    c.dom.appendChild(el);
    c.panels.set(id, el);
  }
  if (el.dataset.leaving) { delete el.dataset.leaving; el.style.pointerEvents = ""; }
  const ta = el.querySelector("textarea");
  const pre = el.querySelector("pre");
  if (document.activeElement !== ta && ta.value !== body) ta.value = body;
  if (ta.readOnly !== readonly) ta.readOnly = readonly;
  el.dataset.readonly = readonly ? "1" : "0";
  // explore or edit
  const mode = editing ? "edit" : "explore";
  if (el.dataset.mode !== mode) {
    el.dataset.mode = mode;
    if (editing) {
      ta.hidden = false;
      pre.hidden = true;
      if (el.dataset.caret !== undefined) {
        ta.scrollTop = Number(el.dataset.scrollTop || 0);
        ta.scrollLeft = Number(el.dataset.scrollLeft || 0);
        ta.focus({ preventScroll: true });
        const k = Number(el.dataset.caret);
        ta.setSelectionRange(k, k);
        delete el.dataset.caret;
      }
    } else {
      pre.scrollTop = ta.scrollTop;
      pre.scrollLeft = ta.scrollLeft;
      if (document.activeElement === ta) ta.blur();
      ta.hidden = true;
      pre.hidden = false;
    }
  }
  if (!editing) {
    const ns = notes.toArray();
    const key = body + "\u0002" + links.toArray().length + "\u0002" + scroll_line + "\u0002" + ns.map((n) => n.join("\u0001")).join("|");
    if (pre.dataset.key !== key) {
      pre.dataset.key = key;
      pre.innerHTML = explore_html(body, links.toArray(), scroll_line, ns);
      if (el._find) run_find(el, false);
    }
  }
  // new content in the same pane (the working file changed): cross-fade it
  if (el.dataset.title && el.dataset.title !== title && !matchMedia("(prefers-reduced-motion: reduce)").matches)
    el.animate([{ opacity: 0.1 }, { opacity: 1 }], { duration: 320, easing: "ease-out" });
  el.dataset.title = title;
  el.querySelector(".t").textContent = title;
  const st = el.querySelector(".s");
  if (st.textContent !== status) st.textContent = status;
  const cls = "panel " + kind + " state-" + state + (editing ? " editing" : " exploring");
  if (el.className !== cls) el.className = cls;
  const btns = buttons.toArray();
  const key = btns.map((b) => b[0] + "\u0001" + b[1]).join("\u0000");
  const bx = el.querySelector(".b");
  if (bx.dataset.key !== key) {
    bx.dataset.key = key;
    bx.innerHTML = btns.map(([label, cmd]) =>
      `<button type="button" data-cmd="${esc(cmd)}" title="${({ "Compile": "Compile this file (Ctrl+Enter)", "←": "Back (Alt+←)", "→": "Forward (Alt+→)", "Lock": "Lock this file against editing", "Unlock": "Allow editing this file" })[label] || "Close"}">${esc(label)}</button>`).join("");
    for (const b of bx.querySelectorAll("button")) {
      b.addEventListener("pointerdown", (e) => e.stopPropagation());
      b.addEventListener("click", (e) => { e.stopPropagation(); model = app.command(model, b.dataset.cmd); });
    }
  }
  // size first, so a scroll below has room to land
  const z = c.cam.z;
  el.style.width = w + "px";
  el.style.height = h + "px";
  el.style.transform = `translate(${(x - c.cam.x) * z}px, ${(y - c.cam.y) * z}px) scale(${z})`;
  if (String(scroll_line) !== el.dataset.scroll) {
    el.dataset.scroll = String(scroll_line);
    if (scroll_line > 0) {
      const top = Math.max(0, scroll_line - 1) * 17;
      ta.scrollTop = top;
      pre.scrollTop = top;
    }
  }
  const op = String(opacity);
  if (el.dataset.born) {
    // the first frame keeps it transparent so the fade has somewhere to start
    delete el.dataset.born;
  } else if (el.style.opacity !== op) {
    el.style.opacity = op;
    el.style.pointerEvents = opacity < 0.05 ? "none" : "";
  }
  return undefined;
}

// ---------------------------------------------------------------- search

// Canvas search: the tool bar box searches every file; Gleam finds, this
// shows the results and sends the choice back.
let lastPane = null;
let results = [];
let active = 0;
function focus_search() {
  const box = document.getElementById("search");
  if (box) { box.focus(); box.select(); }
}
function setup_search() {
  const box = document.getElementById("search");
  const list = document.getElementById("results");
  if (!box || !list) return;
  let timer = null;
  box.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(() => { active = 0; model = app.command(model, "search:" + box.value); }, 70);
  });
  box.addEventListener("focus", () => { if (box.value) { list.hidden = results.length === 0; place_results(); } });
  window.addEventListener("resize", place_results);
  box.addEventListener("blur", () => setTimeout(() => { list.hidden = true; }, 150));
  box.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!results.length) return;
      active = (active + (e.key === "ArrowDown" ? 1 : -1) + results.length) % results.length;
      mark_active();
    } else if (e.key === "Enter") {
      e.preventDefault();
      choose(active);
    } else if (e.key === "Escape") {
      box.value = ""; list.hidden = true; box.blur();
      model = app.command(model, "search:");
    }
  });
  list.addEventListener("pointerdown", (e) => e.preventDefault());
  list.addEventListener("click", (e) => {
    const row = e.target.closest && e.target.closest("[data-i]");
    if (row) choose(Number(row.dataset.i));
  });
}
function choose(i) {
  const r = results[i];
  if (!r) return;
  const box = document.getElementById("search");
  box.value = "";
  document.getElementById("results").hidden = true;
  box.blur();
  model = app.command(model, "searchgo:" + r[4]);
}
function mark_active() {
  const list = document.getElementById("results");
  for (const row of list.querySelectorAll("[data-i]")) {
    const on = Number(row.dataset.i) === active;
    row.classList.toggle("on", on);
    row.setAttribute("aria-selected", String(on));
    if (on) row.scrollIntoView({ block: "nearest" });
  }
}
export function set_results(c, query, items) {
  const list = document.getElementById("results");
  const box = document.getElementById("search");
  if (!list || !box) return undefined;
  const arr = items.toArray();
  const key = query + "\u0000" + arr.map((r) => r.join("\u0001")).join("\u0000");
  if (list.dataset.key === key) return undefined;
  list.dataset.key = key;
  results = arr;
  if (active >= arr.length) active = 0;
  const kinds = { type: "type", field: "field", text: "text" };
  let last = "";
  list.innerHTML = arr.length
    ? arr.map(([kind, label, where, state, i]) => {
        const head = kind !== last ? `<div class="rh">${kind === "type" ? "Types" : kind === "field" ? "Fields" : "Text"}</div>` : "";
        last = kind;
        return head + `<div class="r state-${esc(state)}" role="option" data-i="${esc(i)}"><span class="rk ${kinds[kind] || ""}">${esc(kind)}</span><span class="rl">${esc(label)}</span><span class="rw">${esc(where)}</span></div>`;
      }).join("")
    : (query.trim() ? `<div class="none">Nothing matches “${esc(query)}”.</div>` : "");
  list.hidden = !(document.activeElement === box && query.trim());
  place_results();
  mark_active();
  return undefined;
}
// keep the result list under the box and inside the window
function place_results() {
  const list = document.getElementById("results");
  const box = document.getElementById("search");
  if (!list || !box || list.hidden) return;
  const r = box.getBoundingClientRect();
  const w = Math.min(520, window.innerWidth - 24);
  list.style.width = w + "px";
  list.style.left = Math.max(12, Math.min(r.left, window.innerWidth - w - 12)) + "px";
  list.style.top = r.bottom + 6 + "px";
}

// Pane find: Ctrl+F over a pane. Every match is highlighted (CSS custom
// highlights, where the browser has them), ↑ ↓ step through them, and the
// pane scrolls to the current one.
const HL = typeof CSS !== "undefined" && CSS.highlights && typeof Highlight !== "undefined";
function setup_find(el) {
  const bar = el.querySelector(".find");
  const input = bar.querySelector("input");
  input.addEventListener("input", () => { el._find = { q: input.value, i: 0 }; run_find(el, true); });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); step_find(el, e.shiftKey ? -1 : 1); }
    if (e.key === "Escape") { e.preventDefault(); close_find(el); }
  });
  for (const b of bar.querySelectorAll("button")) {
    b.addEventListener("pointerdown", (e) => e.stopPropagation());
    b.addEventListener("click", (e) => {
      e.stopPropagation();
      if (b.dataset.x !== undefined) close_find(el); else step_find(el, Number(b.dataset.d));
    });
  }
  bar.addEventListener("pointerdown", (e) => e.stopPropagation());
}
function open_find(el) {
  const bar = el.querySelector(".find");
  bar.hidden = false;
  const input = bar.querySelector("input");
  const ta = el.querySelector("textarea");
  // start from the selected text when there is some
  const sel = document.activeElement === ta ? ta.value.slice(ta.selectionStart, ta.selectionEnd) : String(window.getSelection() || "");
  if (sel && !sel.includes("\n")) input.value = sel;
  input.focus();
  input.select();
  el._find = { q: input.value, i: 0 };
  run_find(el, true);
}
function close_find(el) {
  el.querySelector(".find").hidden = true;
  el._find = null;
  el._ranges = [];
  el._now = null;
  paint_highlights();
  const ta = el.querySelector("textarea");
  if (!ta.hidden) ta.focus();
}
function step_find(el, d) {
  if (!el._find || !el._find.hits || !el._find.hits.length) return;
  el._find.i = (el._find.i + d + el._find.hits.length) % el._find.hits.length;
  run_find(el, true, true);
}
function run_find(el, scroll, keep) {
  const f = el._find;
  const ta = el.querySelector("textarea");
  const pre = el.querySelector("pre");
  const text = ta.value;
  const q = (f && f.q) || "";
  const hits = [];
  if (q) {
    const lt = text.toLowerCase(), lq = q.toLowerCase();
    for (let k = lt.indexOf(lq); k >= 0 && hits.length < 2000; k = lt.indexOf(lq, k + Math.max(1, lq.length))) hits.push(k);
  }
  f.hits = hits;
  if (!keep) f.i = Math.min(f.i || 0, Math.max(0, hits.length - 1));
  el.querySelector(".fc").textContent = hits.length ? `${f.i + 1}/${hits.length}` : (q ? "0/0" : "");
  el.querySelector(".find").classList.toggle("miss", !!q && !hits.length);
  // offsets to (line, column)
  const starts = [0];
  for (let k = 0; k < text.length; k++) if (text[k] === "\n") starts.push(k + 1);
  const where = (off) => { let lo = 0, hi = starts.length - 1; while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= off) lo = mid; else hi = mid - 1; } return [lo, off - starts[lo]]; };
  el._ranges = [];
  el._now = null;
  if (HL && !pre.hidden) {
    hits.forEach((off, n) => {
      const [line, col] = where(off);
      const r = range_in(pre.children[line], col, q.length);
      if (r) { el._ranges.push(r); if (n === f.i) el._now = r; }
    });
  }
  paint_highlights();
  if (scroll && hits.length) {
    const [line, col] = where(hits[f.i]);
    const top = Math.max(0, line * 17 - 3 * 17);
    if (!pre.hidden) pre.scrollTop = top;
    if (!ta.hidden) { ta.scrollTop = top; ta.setSelectionRange(hits[f.i], hits[f.i] + q.length); }
  }
}
// A DOM range covering `len` characters from column `col` of one line span.
function range_in(lineEl, col, len) {
  if (!lineEl) return null;
  const walk = document.createTreeWalker(lineEl, NodeFilter.SHOW_TEXT);
  let pos = 0, start = null, r = null;
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    if (n.parentElement && n.parentElement.closest(".back")) break;
    const end = pos + n.length;
    if (!start && col < end) { r = document.createRange(); r.setStart(n, col - pos); start = true; }
    if (start && col + len <= end) { r.setEnd(n, col + len - pos); return r; }
    pos = end;
  }
  return null;
}
function paint_highlights() {
  if (!HL) return;
  const all = [], now = [];
  for (const el of ctx.panels.values()) {
    if (el._ranges) all.push(...el._ranges);
    if (el._now) now.push(el._now);
  }
  CSS.highlights.set("sheaf-find", new Highlight(...all));
  CSS.highlights.set("sheaf-find-now", new Highlight(...now));
}

// The card waits a moment after the pointer leaves a link, so the pointer can
// move into it; inside, it stays open, and a click follows the type (or a
// type link inside it) to the centre.
let cardTimer = null, inCard = false, cardFrom = "code:1", cardType = "";
function card_hide_soon() {
  clearTimeout(cardTimer);
  cardTimer = setTimeout(() => { if (!inCard) model = app.command(model, "hovertype:"); }, 320);
}
function setup_card() {
  const el = document.getElementById("card");
  if (!el) return;
  el.addEventListener("mouseenter", () => { inCard = true; clearTimeout(cardTimer); });
  el.addEventListener("mouseleave", () => { inCard = false; card_hide_soon(); });
  el.addEventListener("click", (e) => {
    const t = e.target.closest && e.target.closest(".ty");
    const type = t ? t.dataset.type : cardType;
    inCard = false;
    clearTimeout(cardTimer);
    model = app.command(model, "hovertype:");
    if (type) model = app.command(model, "cardgo:" + type + ":" + cardFrom);
  });
}

// The preview card: a type's declaration, shown while its name is hovered.
export function card(c, title, body, state, x, y, links) {
  const el = document.getElementById("card");
  if (!el) return undefined;
  if (!title) { if (!el.hidden) { el.hidden = true; el.dataset.key = ""; } return undefined; }
  const key = title + "\u0000" + body + "\u0000" + state;
  if (el.dataset.key !== key) {
    el.dataset.key = key;
    el.className = "state-" + state;
    el.innerHTML = `<div class="ct">${esc(title)}</div><pre>${explore_html(body, links.toArray(), 0, [])}</pre><div class="ch">click to bring it to the centre · click a type in it to follow that one</div>`;
  }
  el.hidden = false;
  const st = c.canvas.getBoundingClientRect();
  const w = el.offsetWidth, h = el.offsetHeight;
  let left = st.left + x, top = st.top + y + 6;
  if (left + w > window.innerWidth - 12) left = window.innerWidth - 12 - w;
  if (top + h > window.innerHeight - 12) top = st.top + y - h - 26;
  el.style.left = Math.max(12, left) + "px";
  el.style.top = Math.max(st.top + 8, top) + "px";
  return undefined;
}

export function info(c, title, lines) {
  const el = c.info;
  if (!el) return undefined;
  if (!title) { el.hidden = true; el.dataset.key = ""; return undefined; }
  const items = lines.toArray();
  const key = title + "\u0000" + items.map((p) => p[0] + "\u0001" + p[1]).join("\u0000");
  if (el.dataset.key === key && !el.hidden) return undefined;
  el.dataset.key = key;
  el.hidden = false;
  el.innerHTML = `<h2>${esc(title)}</h2>` + items.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("");
  return undefined;
}

export function status(c, s) {
  if (c.status && c.status.textContent !== s) c.status.textContent = s;
  return undefined;
}

export function set_files(c, items, current) {
  const sel = document.getElementById("file");
  if (!sel) return undefined;
  const arr = items.toArray();
  const key = arr.map((p) => p[0]).join("|");
  if (sel.dataset.key !== key) {
    sel.dataset.key = key;
    sel.innerHTML = arr.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("");
  }
  if (sel.value !== current) sel.value = current;
  return undefined;
}

export function set_theme(c, dark) {
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  return undefined;
}

export function download(name, content) {
  // Inside an embedded viewer downloads are blocked, so the SVG goes to the clipboard.
  if (window.top !== window && navigator.clipboard) {
    navigator.clipboard.writeText(content).then(
      () => { if (ctx && ctx.status) ctx.status.textContent = "SVG copied to the clipboard"; },
      () => { if (ctx && ctx.status) ctx.status.textContent = "Copy blocked: open the page on its own to export"; });
    return undefined;
  }
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([content], { type: "image/svg+xml" }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  return undefined;
}

export function set_mode(c, view, auto, levels, focused, probes_on) {
  const pb = document.getElementById("probes");
  if (pb && pb.getAttribute("aria-pressed") !== String(probes_on)) pb.setAttribute("aria-pressed", String(probes_on));
  for (const v of ["code", "types"]) {
    const b = document.getElementById("v-" + v);
    if (b) b.setAttribute("aria-pressed", String(view === v));
  }
  const cb = document.getElementById("auto");
  if (cb && cb.checked !== auto) cb.checked = auto;
  const rings = document.getElementById("ringsgrp");
  if (rings && rings.hidden !== (view !== "types")) rings.hidden = view !== "types";
  const n = document.getElementById("lvn");
  const label = levels + (levels === 1 ? " ring" : " rings");
  if (n && n.textContent !== label) n.textContent = label;
  const all = document.getElementById("allbtn");
  const showAll = focused && view === "types";
  if (all && all.hidden === showAll) all.hidden = !showAll;
  return undefined;
}

export function cursor(c, kind) {
  if (c.canvas.style.cursor !== kind) c.canvas.style.cursor = kind;
  return undefined;
}

export const files = () => globalThis.SHEAF_FILES ?? {};
export const sin = Math.sin;
export const cos = Math.cos;
export const exp = Math.exp;
export const atan2 = Math.atan2;
export const now = () => performance.now();
