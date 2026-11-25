# Five decisions before the rule files and engine are fixed (25 November)

These were the five items that would change a rule file or the engine if they came
later. All five are now decided.

## 1. Induction and lemmas (the claims rule file)

- Induction works over any list built with the `1.` / `2...` form, and nothing else.
  Numbers are finite ranges, so they are still tried value by value.
- The engine splits a claim about a whole list into two claims without the file saying
  anything: it holds for item `1.`, and if it holds for `previous`, it holds for the
  next item. Each is checked by trying every value, or by steps someone writes.
  No new word and no new form.
- A claim can cite another claim by its name, as a step or as the assumption in the
  next-item case.
- Only claims in the same file can be cited (there are no imports in version 1).
- A cited claim must itself be proved. One only tried on some values cannot be cited.
- No name is used above its definition, which already rules out claims proving each
  other in a circle.
- No proof search.

## 2. Self-reference, and types that hold each other

These were two separate questions: whether a definition that refers to itself has a
meaning, and whether data can nest (trees).

Self-reference:
- A type may refer to itself only through positive forms (restriction, union, there
  exists, contained in). Never through an opposite, an `impossible`, or a fact about
  something being absent, such as `count is 0`. A definition built only from positive
  forms always has a meaning: the smallest set of texts that fits it.
- Nothing may depend on whether a refusal happened. `impossible` only checks values
  after they are built and never helps build them.
- An opposite in a `where` may only be taken of a type that is already fully defined.
  In version 1 this follows from names being defined before use.
- The chain form (`1.` then `2...` built from `previous`) is the only self-reference in
  version 1. It is positive, and it is grounded by `1.`.

Trees:
- Types that hold each other (nested data such as JSON, XML or bracketed expressions)
  are left out of version 1. Etale does not need them to read itself: brackets do not
  go inside brackets, and a calculation's terms are only paths and numbers.
- The strict rule stays: no name is used above its definition, with no exception.
- A list item cannot be empty text. This is a refusal.
- When trees come later, they need only the positive-only rule above and a rule that a
  type must read at least one character before coming back to itself. That second rule
  is about the engine finishing, not about meaning. Neither changes the frozen core.

## 3. The section 4 checks

Every check refuses. There is no warning level in the rule-file form.

Checks on how the code is written (forms rule file):
- Arithmetic and `<` only on numbers. A calculation gives a number, never a text or a
  record. Two texts compared with `<` must use the same order.
- `<` is refused when either value wraps.
- No raw numbers in calculations.
- At most three starred fields.
- A list item cannot be empty text.

Checks on values (value checker, using induction for claims about whole lists):
- A divisor that might be 0.
- A quotient that might not be exact.
- A value that might not fit its range.
- A case's value falls outside its field's range.
- An output of a case table that no input produces.
- A case that can never be reached.
- A rule that never refuses.
- A `wrap_at` that never wraps.

Checks on texts:
- A type with no texts.
- A type with exactly the same texts as another.
- A printed text that does not read back to the same value in exactly one way.
  Without nesting, a type's texts are built from unions, sequences and lists of simpler
  types, so these text checks can be done exactly.

How refusals are reported:
- The engine reports every refusal it can, not only the first. Every type independent
  of a refused type is still checked. A type that uses a refused type is skipped, not
  refused again.
- Each refusal names its rule and its line. For a refused text, it also says the
  character where reading stopped.
- Still to find: what the blank-line trial was, and where it is written up.

## 4. Input and output for a type run from outside

- The engine asks the operating system for four things: open a file by name, read,
  write, and exit with a value.
- Memory is one fixed area set aside when the engine loads. The engine never asks for
  more while running.
- Input is one text, read in full before checking starts, from a named file, or from
  standard input if no file is named. Reading a text as it grows comes later.
- Accepted: the printed text of the result goes to standard output.
- Refused: the refusals go to the error output, as in decision 3.
- Exit values:
  - 0: accepted
  - 1: the input was refused
  - 2: the Etale file itself was refused
  - 3: the step budget or the memory area ran out
- The step budget has a fixed default, and the command line can set a lower one.
  Running out is a refusal, never a crash. This also covers how deep input can go.
- No clock, randomness, network or environment variables. The same file and the same
  input always give the same result, so checks can be cached by hash later.

## 5. What a character is

- In version 1 a character is one of: the printable ASCII characters, space, newline,
  or tab. Anything else is refused, with the character where reading stopped.
- Line endings are newline only. A carriage return is refused.
- Characters are ordered by their code number, so `"A".."Z"` will mean the same range
  when Unicode is read later.
- Tab is allowed in input texts and refused in Etale files, where it would clash with
  indentation and the paragraph layout.
- Later: a character will mean a Unicode code point read from UTF-8, and text not in
  the standard form will be refused. Every text accepted by version 1 is already in
  that form, so its meaning and hash do not change. Grapheme clusters never go in the
  engine.
- Until then, accented letters and non-English text from outside are refused.

## Suggested but not decided

- Sorts (abstract theories): a sort is a restriction whose starting set is an input. It
  could come back later as a starred field whose value is a type, with a model as the
  call that fills it in. This is the same feature as types that take a type.
- fmt: after the milestone.
- Counterexamples in version 1: when trying every value finds a failure, report that
  value.
- Exact fractions, binary64 and the other section 3 forms: later. Each adds a form
  without changing the frozen core.
- Limits on input from strangers: the step budget for now. Size and depth limits later,
  with the rest of section 6.
