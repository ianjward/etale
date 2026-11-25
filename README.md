# Etale

Etale is an experimental typed language for geometric logic, written to be read by someone
who reads English but does not program. It is to be checked by a small engine written by hand
in assembly, built from a seed small enough to check by hand.

Nothing runs yet. Start with PLAN.md: what Etale is for, the forms of version 1, how Etale is
checked, the build in phases, and what is still open.

- PLAN.md: the one plan.
- examples/: the eight example files that define version 1. Nothing has checked them yet.
- tests/: the texts each example must accept or refuse, a copy of an example for each mistake
  it must refuse, and test_list.txt with every verdict. Nothing has run them yet.
- LICENSE

Earlier work is in the history of this branch:

- bacec75: the Gleam host, as on 16 November 2026.
- ca81f1e: the JavaScript engine and every file in the old forms, including route B,
  kernel.etale and wasm.etale, as on 25 November 2026.
