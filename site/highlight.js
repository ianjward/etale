// A small Sheaf highlighter for the landing page's code samples.
export function highlight(text) {
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return text.split("\n").map((line) => {
    let out = "", k = 0;
    while (k < line.length) {
      const rest = line.slice(k);
      let m;
      if (rest[0] === "#") { out += `<span class="cm">${esc(rest)}</span>`; break; }
      if ((m = rest.match(/^"(?:[^"\\]|\\.)*"/))) { out += `<span class="str">${esc(m[0])}</span>`; k += m[0].length; continue; }
      if ((m = rest.match(/^[A-Z][A-Za-z0-9_]*/))) { out += `<span class="ty">${m[0]}</span>`; k += m[0].length; continue; }
      if ((m = rest.match(/^(val|unique)\b/))) { out += `<span class="kw">${m[0]}</span>`; k += m[0].length; continue; }
      if ((m = rest.match(/^[a-z_][A-Za-z0-9_]*/))) { out += m[0]; k += m[0].length; continue; }
      if ((m = rest.match(/^\d+(\.\d+)?/))) { out += `<span class="num">${m[0]}</span>`; k += m[0].length; continue; }
      out += esc(rest[0]); k++;
    }
    return out;
  }).join("\n");
}
