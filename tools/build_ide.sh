#!/bin/sh
# Builds dist/workspace.html: the Gleam workspace compiled to JavaScript, bundled
# with language.sheaf, the standard library and the examples into one page.
set -e
cd "$(dirname "$0")/.."
gleam build --target javascript >/dev/null
mkdir -p dist
node -e '
const fs = require("fs"), path = require("path");
const out = {};
function add(dir) {
  for (const f of fs.readdirSync(dir)) {
    const p = path.join(dir, f);
    if (fs.statSync(p).isDirectory()) add(p);
    else if (p.endsWith(".sheaf") || p.endsWith(".txt")) out["/" + p] = fs.readFileSync(p, "utf8");
  }
}
add("priv"); add("examples");
fs.writeFileSync("dist/files.json", JSON.stringify(out));
'
node tools/bundle.mjs build/dev/javascript/sheaf/sheaf/ide.mjs tools/ide.html dist/workspace.html dist/files.json
rm dist/files.json
