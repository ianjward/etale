// Builds the demo site into _site/: the pages and assets in site/, and
// workspace.html (the prebuilt dist/workspace.html).
//
//   node tools/build_site.mjs
// Run tools/build_ide.sh first: it builds dist/workspace.html.
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const out = path.join(root, "_site");
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

for (const f of fs.readdirSync(path.join(root, "site"))) fs.copyFileSync(path.join(root, "site", f), path.join(out, f));
fs.copyFileSync(path.join(root, "dist/workspace.html"), path.join(out, "workspace.html"));
fs.writeFileSync(path.join(out, ".nojekyll"), "");
const kb = (p) => (fs.statSync(path.join(out, p)).size / 1024).toFixed(0) + " KB";
console.log(`_site: index.html ${kb("index.html")}, workspace.html ${kb("workspace.html")}`);
