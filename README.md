# Sheaf

**Sheaf** is an extremely rough outline for an experimental typed language that is hopefully a human readable version of positive (geometric) logic. It will feature proofs and drawn graphs (eventually). This repository contains its checker, evaluator, and infinite-canvas IDE workspace. Its core grammar is in `priv/language.sheaf`.

## Quick Start

```sh
gleam build                                       # Requires Gleam ≥ 1.14 and Node ≥ 22
node bin/sheaf.mjs bootstrap                    # Self-parses language.sheaf
node bin/sheaf.mjs check examples/orders/orders.sheaf    # Parse and check a file
node bin/sheaf.mjs check examples/shop                # Check a project folder
node bin/sheaf.mjs bundle examples/shop -o shop.txt   # Bundle project into one text file
node bin/sheaf.mjs run examples/orders/orders.sheaf Order examples/orders/order_1042.txt --trace
node bin/sheaf.mjs run priv/stdlib/dates.sheaf Date --text 2024-02-29
node bin/sheaf.mjs graph examples/orders/orders.sheaf -o orders.svg
node bin/sheaf.mjs fmt examples/orders/orders.sheaf --check   # Validate spacing
node bin/sheaf.mjs print examples/orders/orders.sheaf Line          # Print type source
node bin/sheaf.mjs print examples/orders/orders.sheaf Order examples/orders/order_1042.txt   # Print values
gleam test                                        # Run test suite
./tools/build_ide.sh                              # Build dist/workspace.html
```

> `gleam_stdlib` is vendored under `vendor/gleam_stdlib` (Apache-2.0) to allow registry-free builds. To use Hex instead, configure `gleam_stdlib = ">= 1.0.0"` in your `gleam.toml`.

## The Demo Site

The `site/` directory contains a static site deployed to GitHub Pages via CI/CD on every push to `main`:
* **index.html**: General project overview and examples.
* **workspace.html**: The prebuilt canvas IDE (`dist/workspace.html`).
* **playground.html**: An in-browser IDE that runs the Gleam compiler via WebAssembly. It builds your changes in a web worker (~1 second) and updates the live workspace. Edits persist locally in the browser.

### Local Site Setup
```sh
V=1.19.2; mkdir -p wasm
curl -fsSL https://github.com | tar xz -C wasm
./tools/build_ide.sh && node tools/build_site.mjs wasm && node tools/check_wasm.mjs wasm
python3 -m http.server -d _site          # Open http://localhost:8000
```

## The Workspace

Open `dist/workspace.html` in any browser to access a self-contained, infinite, zoomable canvas IDE.

#### UI Status Indicators

| Outline Color | State | Condition |
| :--- | :--- | :--- |
| **Green** | Compiled | Clean compilation with zero errors. |
| **Purple** | Claims Proved | Successful compilation; all internal `{Fact}` claims verified. |
| **Yellow** | Changed | Unsaved edits present since last compile. |
| **Orange** | Affected | Local file unchanged, but a linked dependency text was modified or has errors. |
| **Red** | Errors | Compilation attempted but rejected by the checker. |
| **Dashed Grey** | Out of Scope | Reference targets an inaccessible private type. |
| **Blue** | Locked | Read-only target (Core library files default to locked). |

