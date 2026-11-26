# Etale

Etale is an experimental typed language for geometric logic, written to be read by someone
who reads English but does not program. It is to be checked by a small engine written by hand
in assembly, built from a seed small enough to check by hand.

The test engine runs (phase 1), and Etale's own rule files are under way (phase 2): they
refuse a line that reads as no form and a type whose paragraphs are out of order, check that
names are defined above where they are used, and check that a field worked out by cases gives
one answer, while claims, texts and values are still to come. Start with PLAN.md: what Etale
is for, the forms of version 1, how Etale is checked, the build in phases, and what is still
open.

- PLAN.md: the one plan.
- examples/: the eight example files that define version 1.
- tests/: the texts each example must accept or refuse, a copy of an example for each mistake
  it must refuse, and test_list.txt with every verdict.
- rules/: Etale's rule files, its definition of itself in Etale, run by the engine.
- test_engine/: the test engine, in a small part of Scheme, and its own tests. It is a test
  bench, deleted once the engine in assembly agrees with it on every example.
- LICENSE

To run the test engine, build Chibi-Scheme
(`git clone https://github.com/ashinn/chibi-scheme`, then `make` and `make install`), and
from the top of this repo:

```
chibi-scheme -h 1G -I test_engine -x small_scheme test_engine/engine.scm test test_engine/tests/test_list.txt
chibi-scheme -h 1G -I test_engine -x small_scheme test_engine/engine.scm tree examples/dates.etale
chibi-scheme -h 1G -I test_engine -x small_scheme test_engine/engine.scm check examples/dates.etale
chibi-scheme -h 1G -I test_engine -x small_scheme test_engine/engine.scm test tests/test_list.txt
```

PLAN.md 5.6 lists the commands and what the engine does.

Earlier work is in the history of this branch:

- bacec75: the Gleam host, as on 16 November 2026.
- ca81f1e: the JavaScript engine and every file in the old forms, including route B,
  kernel.etale and wasm.etale, as on 25 November 2026.
