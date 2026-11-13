# Etale

**Etale** is an extremely rough outline for an experimental typed language that aims to be a human-readable version of positive (geometric) logic, with proofs and drawn graphs (eventually). This repository contains its checker, evaluator and infinite-canvas IDE workspace. Its core grammar is in priv/language.etale.

The bigger picture is a fair, distributed network of verified OS level proof machines sharing knowledge repositories. No machine is in charge. Each machine’s history is a proof of its state, and every message carries a proof its receiver checks, so trust comes from checking, not from the sender. The repositories hold versioned theories and proved claims that anyone can publish, extend and check on equal terms.

The name: a sheaf and its étale space are one thing seen two ways.

## Layout

The Etale tree, read top-down in the order things are stated:
- `priv/language.etale`: the language, which parses itself as `File` in exactly one way.
- `priv/stdlib/`: the standard library.
- `examples/`: theories, with the data texts that inhabit them beside them.

The host, scaffolding in Gleam and JavaScript that self-hosting replaces:
- `src/`: the reader, checker, evaluator, printer, sequents, graph and workspace.
- `test/`: the test suite.
- `bin/etale.mjs`: the command line.
- `tools/`, `site/`: the workspace and site builds.

## Quick Start
- An overview of the language: https://ianjward.github.io/etale
- A canvas based IDE for the language: https://ianjward.github.io/etale/workspace.html

## Local Development
```sh
gleam build                                       # Requires Gleam ≥ 1.14 and Node ≥ 22
node bin/etale.mjs bootstrap                    # Self-parses language.etale
node bin/etale.mjs check examples/orders/orders.etale    # Parse and check a file
node bin/etale.mjs check examples/shop                # Check a project folder
node bin/etale.mjs bundle examples/shop -o shop.txt   # Bundle project into one text file
node bin/etale.mjs run examples/orders/orders.etale Order examples/orders/order_1042.txt --trace
node bin/etale.mjs run priv/stdlib/dates.etale Date --text 2024-02-29
node bin/etale.mjs graph examples/orders/orders.etale -o orders.svg
node bin/etale.mjs sequents examples/orders/orders.etale  # Its theory as geometric sequents (docs/geometric.md)
node bin/etale.mjs fmt examples/orders/orders.etale --check   # Validate spacing
node bin/etale.mjs print examples/orders/orders.etale Line          # Print type source
node bin/etale.mjs print examples/orders/orders.etale Order examples/orders/order_1042.txt   # Print values
gleam test                                        # Run test suite
./tools/build_ide.sh                              # Build dist/workspace.html
```

> `gleam_stdlib` is vendored under `vendor/gleam_stdlib` (Apache-2.0) to allow registry-free builds. To use Hex instead, configure `gleam_stdlib = ">= 1.0.0"` in your `gleam.toml`.

## The Demo Site

The `site/` directory contains a static site deployed to GitHub Pages via CI/CD on every push to `main`:
* **index.html**: What Etale is for, its guarantees, and the workspace embedded in the page.
* **workspace.html**: The canvas IDE, built by CI with `tools/build_ide.sh` (`dist/workspace.html`, which is not checked in).

### Local Site Setup
```sh
./tools/build_ide.sh && node tools/build_site.mjs
python3 -m http.server -d _site          # Open http://localhost:8000
```

## The Workspace

Build it with `./tools/build_ide.sh`, then open `dist/workspace.html` in any browser to access a self-contained, infinite, zoomable canvas IDE. It is also published on the demo site.

#### UI Status Indicators

| Outline Color | State | Condition |
| :--- | :--- | :--- |
| **Green** | Compiled | Clean compilation with zero errors. |
| **Purple** | Claims Proved | Successful compilation; all internal `{Claims}` claims verified. |
| **Yellow** | Changed | Unsaved edits present since last compile. |
| **Orange** | Affected | Local file unchanged, but a linked dependency text was modified or has errors. |
| **Red** | Errors | Compilation attempted but rejected by the checker. |
| **Dashed Grey** | Out of Scope | Reference targets an inaccessible private type. |
| **Blue** | Locked | Read-only target (Core library files default to locked). |

