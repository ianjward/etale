# Features and goals for later (25 November)

Everything from the 25 November review that is not in version 1, in one place so it can
be organized and planned later. What version 1 decided is in
etale-five-decisions-2026-11-25.md. Where one of those decisions changes an item, the
item says so.

Each item has a "when" line:
- after the GUI: wait until the GUI works
- later: no time set
- not decided: still needs a decision about what it should be

## Forms and data

- Types that hold each other, for nested data: JSON, XML, bracketed expressions.
  When: later.
  Needs two things first: the positive-only rule for self-reference, and a rule that a
  type reads at least one character before coming back to itself. Both are already in
  the five decisions. Also needs an exception to the rule that no name is used above
  its definition, for types that use each other. The preferred exception is to allow
  it only where the later type uses the earlier one in return.
- Unicode: a character becomes a code point read from UTF-8, and text not in the
  standard form is refused. Accented letters and non-English text follow from this.
  When: later. The path is set by decision 5, and version 1 texts keep their meaning
  and hashes.
- Character ranges such as `"A".."Z"`. Code-number order is already fixed by
  decision 5. When: later.
- Exact fractions. When: later.
- binary64. When: later.
- Bytes and binary files, including bytes as a second shape on a record. When: later.
- Text operations: case-insensitive compare, join, split, search, replace.
  When: later.
- Sorting. When: later.
- Lookup by a text key other than a filter. When: later.
- Lookups on a unique key without a full scan. When: later.
- Type intersection (`{Word & Short}`). No form writes it, and it was never dropped by
  name. When: not decided.
- Reachability: the engine's rule loop can work it out, but no form lets a file state
  it. A trip is checked only when it is given. When: not decided.
- Still open from 24 November:
  - reading a list from its last item
  - whether a second text also reads
  - rounding to a unit that is not a place
  - the levels of isomorphism
  When: not decided.

## Reuse and organizing code

- Types that take a type ("a ledger over any Money"). When: later.
- Abstract theories and models (sorts), dropped 24 to 25 November. Suggested: a sort is
  a starred field whose value is a type, and a model is the call that fills it in. This
  is the same feature as types that take a type. Its claims need step proofs, because
  there are no values to try. When: later, together with types that take a type.
- A case table passed as a value. When: later.
- A list given to a call. When: later.
- Imports, private names and a library file. When: later.
- Packages. When: later. See also "Projects and versions".
- Lemmas across files. Version 1 cites only claims in the same file. When: later, after
  imports.

## Proofs and correctness

- Proof search: finding steps automatically. Version 1 has induction set up by the
  engine, but no search. When: later.
- Rewriting and reasoning by equality. These were for claims about theories, so they
  come with sorts. When: later.
- Counterexamples. Suggested for version 1: when trying every value finds a failure,
  report that value. For step proofs, a failed proof only names the wrong step.
  When: not decided.
- The proof player, proof traces, the Claims view, and "can" and "can't" for each case
  of a type. When: after the GUI.
- Lean export. Not in either plan. Etale's meaning is now written in Etale, in the rule
  files. When: not decided.
- Intent tools. When: later.
  - witnesses and near misses
  - a plain-language read-back
  - examples kept in the file (the plan keeps them in a separate test list instead)
  - what changed in meaning on each edit
  - refusals for unrelated units
  - the interview, the goal graph, and assumptions retracted by version
- Machine-made tests. The plan has hand-made tests and a test engine that must agree
  with the assembly engine. When: later.
  - every short text
  - random texts
  - print-then-read checks
- Which facts still hold as a text grows (the column planned for docs/geometric.md).
  When: later. Goes with "Growing texts".

## Costs, limits and speed

- Costs. The Gleam checker on main already worked out every record's cost and reported
  it in a set form: the worst case in list counts, up to a constant, such as
  `O(legs.count * links.count)`. A type could state `cost <= ...` as a promise, which
  the checker refused when broken. This went with Gleam on 16 November.
  When: later, including whether to carry it over at all.
  To decide then:
  - whether the cost report and the `cost <= ...` promise come to the new engine (the
    promise refuses when broken, so it fits decision 3)
  - whether costs become exact step counts, which would need the engine to fix what
    one step costs
  - whether costs per version are still wanted once promises exist, since a broken
    promise already catches a rise
- Limits worked out before reading input from strangers: size and depth. Version 1 has
  a step budget and a fixed memory area (decision 4). When: later.
- A speed target. The engine plan measures speed in phase 2 but sets no number.
  When: not decided.
- A compiled runner (route B, kernel.etale, wasm.etale, x86, the speed ideas from Zig).
  These stay on the minimal branch and are not part of either plan's chain, so
  "compile" has no path. When: not decided.
- Caching of checks by hash. Possible because decision 4 makes every run give the same
  result. When: later. Goes with "Projects and versions".

## Running

- Version 1 reads one whole input and writes one output, with four exit values
  (decision 4). For later:
  - reading files other than the input
  - reading a text as it grows
  - clock and randomness: these would break same-input, same-result, so each needs a
    decision about how it stays checkable
  - another program calling the engine as a library, not only running it as a command
  When: later.
- Execution: event logs, events in, an outbox out. When: later.
- Engine paths beyond 32-bit x86 Linux: browser, phone. When: later.
- GPU and hard real time. When: later.

## Tools

- fmt. The Mes plan put it after the milestone; the engine plan doesn't mention it.
  When: after the milestone.
- Commands: check a folder, bundle a project, run with a trace, print a type's code.
  When: before the GUI. These are the exception to the GUI items below.
- The graph command (SVG) and the sequents printout. When: after the GUI.
- Editor support, trace or debugger, REPL, profiler, CI, package registry, docs
  generator. When: later.
- A tool that updates files when the forms change. When: later.

## The GUI and workspace (after the GUI is functional)

- The display and graph view.
- The AI pane.
- The canvas workspace:
  - Code and Types views, file colours, search, back and forward, data panes
  - the glass skin, puzzle panes, Claims view and alluvial diagrams
  - the version grid and a phone layout
  - the GitHub Pages site and playground
- AI beyond the pane: ghost-pane proposals, generalizing two types without AI, and a
  live agent.
- For people who don't program: a fixed picture for each form, and writing by edge
  cases.

## Projects and versions

- Projects: folders as scope. No example uses two files now. When: later.
- Versions as hashes, cached checks, locks and packages. When: later.
- Growing texts: what part of a message already proves ("verified up to here").
  When: later.

## The larger goals

- The Etale machine. When: later.
  - the network of proof machines
  - graph union
  - finding versions by hash
  - provenance by physical links
  - signatures
- Other languages: their values checked at boundaries, and the checker as a library.
  When: later.

## Decided against

- Confidentiality: by decision.
- Warnings: decision 3 makes every check a refusal.
- Grapheme clusters in the engine: decision 5.
