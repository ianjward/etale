# Etale: the plan

This is the one plan for Etale. It replaces every earlier plan, decisions doc and handoff
(16 October to 25 November 2026). Where an older doc says something else, this plan holds.
Decisions go into this file in the same commit as the work they belong to, not into a new
dated doc.

Last changed: 26 November 2026 (phase 2 started).

## 1. What Etale is for

- A secure computing environment that starts from a seed small enough to check by hand, with
  nothing above it that cannot be read.
- A typed language for geometric logic that a person who reads English, but does not
  program, can read: types read from text, facts, rules, and claims with their proofs.
- A way to reason about what a system can and can't be, and to trace that reasoning. Change
  over time is just a type or a ledger.
- One language all the way down: Etale's own definition is written in Etale, and run by an
  engine small enough to read in full.

The project's aims, and where each one stands:

| Aim | Where it stands |
|---|---|
| A readable typed language for geometric sequents over character sequences | version 1's forms are decided (section 3) |
| Proofs | claims with written steps, induction and citations, checked by the engine (section 3.8) |
| Verify quickly | the engine (sections 4 and 5); no speed target yet |
| Visual graphs | after the GUI (section 8) |
| Compile | not decided (section 8) |

## 2. Where things stand

- Decided: the forms of version 1 (the eight files in examples/), the five decisions of
  25 November (characters, input and output, checks, self-reference, induction), the frozen
  core, and the route: a small engine written by hand in assembly on the stage0-posix seed.
- Built: the corpus (phase 0, done 25 November): the examples, and in tests/ every text and
  mistake of section 6 with the test list. The test engine (phase 1, done 26 November, 5.6):
  it reads every example and runs rule files written in the core's part of Etale.
- Started: Etale's own rule files (phase 2, from 26 November, 5.7). They read every line of
  the eight examples as its form and check that names are defined above where they are
  used. Case tables, claims, texts and values are still to come, so 29 of the corpus's
  verdicts wait.
- Retired: the Gleam host (to 16 November), and the JavaScript engine with every file in the
  old forms, route B, kernel.etale and wasm.etale (to 19 November). Both are in the history
  (section 10).

## 3. The language, version 1

### 3.1 The examples are the definition

Version 1 is the eight files in examples/, exactly as written. A form they do not use is not
in version 1. A change to a form starts as a change to an example. What each example means,
and what it must accept and refuse, is in section 6.

Why it can be small: every geometric rule has one shape, given some facts, then what follows.
A file stands for a restricted Lisp: a block is a list of cases, a case is a list of facts,
and a fact is a list of words. Indentation stands for the brackets one to one, as wisp does
for Scheme, so a file never holds a bracket for structure, and what a person reads is exactly
what is checked.

### 3.2 Blocks

- A one-line definition: one value (`Minutes_Per_Hour: 60`), a calculation of constants, a
  range, or a choice (`Station_Character: " " | Letter`).
- A type: `Name:` with lines under it, in paragraphs (3.4).
- A type that is only a text: its numbered positions right under its name, after
  `ordered by` if it has one (`ordered by Alphabetical`). It has no paragraphs.
- A claim type: a type with a `claim` line, its parts narrowed by `given` lines if any (3.8).
- Refused: an empty type (a name with nothing under it), a case table outside its type, and
  comments (`#`). Nothing below a type, or in another file, can add to it.

### 3.3 Lines

In a type:

- A field, `name: definition`. A starred field, `name*: definition`, is given by whoever
  makes the type with a call.
- A field worked out by cases: each case one step under it (`True:`, `"late":`, `30:`), and
  the case's facts one step under that, one fact a line. A case stands alone: none wins over
  another.
- `impossible:` with its facts under it: one case for each block.
- `text:`, or another name such as `european:`, with numbered positions under it.
- `claim` and a fact, alone or with a colon and numbered steps under it. A step is a fact,
  or a call to a proved claim above it (3.8).
- Inside a type, a bare name is the type's own field.
- A line has at most one colon, between its name or number and its definition. A numbered
  line has its number in place of a colon.

Under a field:

- `where` and a fact (a filter); `places 2`; `wrap_at Minutes_Per_Day`; `unique station`;
  `ordered by due.minutes`.
- `1.` and `2...`, each with a call, and `until` and a fact one step under `2...` (a loop).
- `given` and a fact, one step under a part: only the values where it holds (chosen
  25 November). It names the part, not its type, since two parts can share a type, and a
  `given` that ties two parts together goes under the later one. `where` makes a smaller list
  inside each value; `given` narrows the type itself; neither refuses anything, only
  `impossible:` does. In version 1 files only claim types use it; rule files use it too.

Definitions:

- A range: `0..9999`, `1..`, `-1000..1000`, `0..9999.99`.
- A choice of values or type names, with `|`. A type name.
- A call: `Xor(left: a, right: b)`. Every starred field is given by name, as a name or a path
  with one dot, never a list. A comma appears only between a call's inputs.
- A list declared: `(Stop... 1..)`, the item type, `...`, a space, then how many (a range or
  a number). The item must be a named type.
- A list used: `(stops)`, `(stops.delay_minutes)`, `(network.links)`, then `.count`, `.sum`,
  `.min`, `.max`, `.first` or `.last`. `(trains.stops)` is every train's stops, joined in
  order.
- One of `+ - * /` between two values. A path with one dot.

Facts: `is`, `in` (a choice, a range or a list), `divisible_by`, `not_divisible_by`, `<`,
`<=`, `>`, `>=`. A `where` fact names every field by its type, with no bare names
(`where Nonstop_Link.from is Leg.from`), and takes only a fact whose opposite the engine
knows: `is`, `in` (a choice, a range or a list), the four comparisons, and `divisible_by`
(see 7.2).

Text positions: a field, with `digits 4` after it if any; a text in quotes; `Letter`, `Digit`
or `Newline`; a list, declared or used.

Loops: `previous` is the item before the one being made; `last` means only a list's last
item. `until` is checked on `previous` before each item after the first, and the top of the
count still caps the list. A list read from a text has no `until`: the text ends it.

Numbers: a minus right before a number belongs to it. A value read from a text has exactly
its field's places. A worked-out value rounds to its places, a tie to the even one. `wrap_at`
also gives a remainder (`remainder: number` with `wrap_at divisor`). A quotient the engine
proves exact needs no `places`.

### 3.4 Layout and limits (chosen 25 November)

- A type's lines come in paragraphs, one blank line apart, in this order:
  1. Parts: starred inputs first, then what is read from the text (in a claim type, what the
     claim is about), each with its `given` lines one step under it.
  2. Worked out: each value after what it uses. A field worked out by cases is a paragraph
     of its own.
  3. Impossible.
  4. The claim: the claim and its steps.
  5. Texts: each in a paragraph of its own.
- A kind with nothing in it is left out. No blank line inside a paragraph, and never two
  together. A blank line around every type.
- A part's range holds only fixed values. A limit that depends on a worked-out value is an
  impossible block below it, as with Date's day.
- No name is used above its definition, between types or inside one. No exception.
- Limits, each one a refusal: at most 7 items in a paragraph (an item is a line one step
  under the type's name, with the lines under it), 7 paragraphs in a type, 7 cases in a
  field, 7 choices in a union, 7 one-line definitions together, 7 lines directly under any
  line in a type, and 7 types in a file; at most 70 characters in a line, indentation 3 steps
  deep, and 4 words in a name.

### 3.5 Characters (decided 25 November)

- A character is a printable ASCII character, a space, a newline or a tab. Anything else is
  refused, naming the character where reading stopped.
- A tab is allowed in input texts and refused in Etale files, where it would clash with
  indentation. No version 1 form reads a tab, so an input text with one is refused where
  reading reaches it.
- Lines end with a newline only. A carriage return is refused everywhere, in Etale files and
  in input texts; for that, the HTTP example left version 1 (25 November; section 8).
- Characters are ordered by their code number, so a range such as `"A".."Z"` keeps its meaning
  when Unicode comes.
- Later: a character is a Unicode code point read from UTF-8, and text not in the standard
  form is refused. Every text version 1 accepts is already in that form, so its meaning and
  hash do not change. Grapheme clusters never go in the engine. Until then, accented letters
  and non-English text from outside are refused.

### 3.6 Reserved words and built-in names

- Words: `claim`, `given`, `impossible`, `text`, `where`, `until`, `previous`, `first`,
  `last`, `count`, `sum`, `min`, `max`, `unique`, `ordered`, `by`, `places`, `wrap_at`,
  `digits`, `is`, `in`, `divisible_by`, `not_divisible_by`.
- Names: `True`, `False`, `Letter`, `Digit`, `Newline`, and the order `Alphabetical`.
- Characters: `:`, `|`, `..`, `...`, `.`, `( )`, `,` between a call's inputs, `"`, `*` after
  a starred field's name, `+ - * /`, `< <= > >=`, a minus before a number, a point in a
  decimal, and the numbers of numbered lines (`1.`, `2...`).
- Alphabetical is built in (chosen 25 November) and written in the rule files, since no form
  reaches the character at each place of a name. Two names compare at the first place where
  they differ. A space comes before any letter. Letters go from A to Z, a capital and a small
  letter counting the same. A name that is the start of a longer one comes first, so Oslo
  comes before Oslo S.

### 3.7 Meaning (decided 25 November)

- Every form is sugar for the frozen core (section 4).
- A type may refer to itself only through positive forms (restriction, union, there exists,
  contained in): never through an opposite, an `impossible`, or a fact that something is
  absent, such as `count is 0`. A definition built only from positive forms always has a
  meaning: the smallest set of texts that fits it.
- Nothing may depend on whether a refusal happened. `impossible` only checks values after
  they are built and never helps build them.
- An opposite in a `where` is only taken of a type that is fully defined. In version 1 this
  follows from names being defined before use.
- The loop (`1.`, then `2...` built from `previous`) is the only self-reference in version 1.
  It is positive, and `1.` grounds it.
- Version 1 has no types that hold each other (trees such as JSON, XML or bracketed
  expressions). Etale does not need them to read itself: brackets never go inside brackets,
  and a calculation's terms are only paths and numbers.
- A list item cannot be the empty text.

### 3.8 Claims and proofs (decided 24 and 25 November)

- A claim is its own type. Its fields name what it is about, `given` lines narrow them, and
  `claim` and a fact is what holds for every value left.
- `claim` marks a fact proved once, for every value. Every other line is a requirement,
  tested on each text.
- Numbered steps under the claim each follow from the givens and the steps above, by one case,
  one built-in fact (2023 `not_divisible_by` 4) or one list rule (an item is in a filter when
  it is in the list and the `where` fact holds; a list's first and last items are in it; a
  list with an item in it has a count of 1 or more). The claim follows from the steps by one more case, so it is not repeated as a step.
- A claim with no steps is tried on every value, as Xor_Associativity is.
- Induction works only over lists built with `1.` and `2...`. The engine splits a claim about
  a whole list into two without the file saying anything: it holds for item `1.`, and if it
  holds for `previous`, it holds for the next item. Each part is tried on every value or shown
  by written steps. No new word and no new form.
- A step may cite another claim by its name, and so may the next-item case as its assumption.
  Only claims in the same file, and only proved ones, not claims tried on some values.
  Defining names before use rules out claims proving each other in a circle.
- A step cites a claim by calling it, giving its parts by name, as in
  `2. Very_Late_Refund(train: train, stop: stop)` in Late_Start_Refund (chosen 25 November).
  The engine checks that the cited claim's `given` lines hold for those values, and its claim
  then holds for them. The same call, given `previous`, cites a claim for the item before in
  the next-item case of induction.
- No proof search: someone writes the steps, or the engine tries every value.

### 3.9 Checks (decided 25 November)

Every check refuses. There is no warning level.

How the code is written (the forms rule file):

- Arithmetic and `<`, `<=`, `>`, `>=` only on numbers. A calculation gives a number, never a
  text or a record. Two texts compared with `<` must use the same order.
- `<` and the like between two values are refused when either one wraps, unless the other
  is a fixed value: a constant cannot wrap, so the timetable's `arrives < Day_Starts` is
  allowed (chosen 25 November).
- No raw numbers in calculations: a number in a calculation is a named constant.
- At most three starred fields in a type.
- A list item cannot be the empty text.

Values (the values rule file, using induction for claims about whole lists):

- A divisor that might be 0.
- A quotient that might not be exact and has no `places` line.
- A value that might not fit its range. Impossible blocks count as facts about every value
  of their type, so the bank account's `previous.balance_after`, which every Transaction keeps
  at 0 or more, fits `balance_before*: 0..` (chosen 25 November).
- A rule that never refuses.
- A `wrap_at` that never wraps.
- A type no value can have: whatever it reads from a text or is given by a call, its ranges,
  cases, `given` lines and impossible blocks leave nothing. This covers a text shape no text
  can match, a type no call could make, and a claim whose `given` lines leave nothing, which
  would otherwise pass whatever it claims (chosen 25 November).

Case tables (the case tables rule file):

- A case's value outside its field's range.
- An output of a case table that no input produces.
- A case that can never be reached.

Texts (the texts rule file):

- A type with exactly the same texts as another.
- A printed text that does not read back to the same value in exactly one way.
- Without nesting, a type's texts are built from unions, sequences and lists of simpler
  types, so these checks can be exact.

How refusals are reported:

- The engine reports every refusal it can, not only the first. Every type that does not use
  a refused type is still checked; a type that uses one is skipped, not refused again.
- Each refusal names its rule and its line. For a refused text, it also gives the character
  where reading stopped.
- Tests compare verdicts and lines, never wording (16 November). A test of an accepted text
  also compares what it prints.

Which line a refusal names (Claude's defaults, set with the test list on 25 November, to
change at review):

- A field worked out by cases that gives some value no answer, or two: the field's line. It
  is tried over the ranges of the fields it uses, so a field that uses a refused field is not
  refused as well.
- A claim step that does not follow, or that calls a claim whose `given` lines do not hold
  for what it gives: the step's line. The steps below it and the claim rest on it, so they
  are not checked.
- A claim with no steps that fails: its `claim` line.
- A refused text names two lines: the line of the Etale file that refused it (a part's range,
  a `places`, `unique` or `ordered by` line, or an `impossible:` line), and the line of the
  text where the refused value starts. For `unique` and `ordered by`, that value is the item
  that breaks it: the second item with the same value, or the first item that comes before
  the one above it. A text that does not read names the position or range where reading
  stopped, and the line of the text where it stopped.
- A value that holds a refused value, such as the train of a refused stop, is not refused
  again.

### 3.10 Running a type from outside (decided 25 November)

- The engine asks the operating system for four things: open a file by name, read, write,
  and exit with a value.
- Memory is one fixed area set aside when the engine loads. The engine never asks for more.
- Input is one text, read in full before checking starts, from a named file, or from standard
  input if no file is named. Reading a text as it grows comes later.
- Accepted: the printed text of the result goes to standard output. Refused: the refusals go
  to the error output.
- Exit values: 0 accepted; 1 the input was refused; 2 the Etale file itself was refused;
  3 the step budget or the memory ran out.
- The step budget has a fixed default, which the command line can lower. Running out is a
  refusal, never a crash. It also bounds how deep input can go.
- Every rule match, new element and branch counts as one step, and there is no other bound
  (chosen 25 November). The default is set in phase 2 from the steps the examples need, with
  room to spare.
- No clock, randomness, network or environment variables. The same file and the same input
  always give the same result, so checks can later be cached by hash.

## 4. How Etale is checked: the frozen core (chosen 25 November)

The engine understands five things and never learns another. Every Etale form is sugar for
them.

1. Atoms: the starting facts the engine gives itself: a value's field (this stop's delay), a
   character at a place in a text, and the number facts (less than, `divisible_by` and the
   rest). They are not sugar for anything.
2. Restriction, "and": only the values where all of these facts hold.
3. Union, "or": any one of these.
4. There exists: forgetting a field. "A train has a late stop" is a restriction on a train
   and a stop together, with the stop then forgotten. This is how Etale says "some", and how
   the engine makes new elements.
5. Contained in: the rule itself. Everything in this restriction is also in that union. This
   is what a sequent of geometric logic is.

These are what geometric formulas are built from, plus the sequent, so the core adds nothing
to geometric logic and leaves nothing out.

How the forms become sugar:

- A type with fields: values with named parts, restricted by its facts.
- A range: a restriction of the numbers.
- A choice with `|`: a union.
- A field worked out by cases: a union of restrictions, one for each case, and a rule that
  each value is in exactly one of them.
- `impossible`: a restriction contained in the empty union.
- `claim`: a restriction contained in another, shown by its steps.
- Lists and texts: rules that refer to themselves (a list is empty, or an item followed by a
  list), positive only (3.7), within the engine's bound on new elements.

How the core is written (chosen 25 November): rule files are written in a small part of
Etale itself, using only four forms the examples already use: a type with its parts, `given`
lines, a field worked out by cases, and `impossible:`. These are the five core things in
Etale's own words: a type's parts are there exists, `given` lines a restriction, cases a union,
`impossible:` contained in nothing, and the atoms are the engine's built-in facts. No new word
is needed. Two things differ from version 1 files. First, a type's values are every match
among the facts the engine holds, not texts read from outside: an unstarred part is matched
among those facts, and a starred part is given by a call, as in version 1. Second, a type may
call itself one step on, as in `earlier: Name_Above(name: name, line: line.above)`, with the
walk's end stated as one of its cases, so a rule can walk through a file's lines (chosen
25 November). Version 1 files keep the loop as their only way to refer to themselves, and the
rule files define the loop on top of such calls. A call to itself carries back only a fixed
answer such as True or False; handing back a value would need a case whose value is another
field, which version 1 does not have, so that is decided if a rule file needs it. The file
being checked comes in as built-in types, as Letter and Digit are built in (5.3).

New forms come only as rule files that rewrite them into these five. The engine never grows,
and the chain stays one step: Rust is built from source one release after another, and Go
pins an old version, but here the pin is total.

## 5. The build

The route was chosen on 25 November ("start outlining this build"), in place of the route
through a C compiler and GNU Mes. The parts and phases below are Claude's outline; the person
has not reviewed them in detail.

### 5.1 The chain

Each step is a small program that builds the next, every one from readable source except the
first.

1. The seed: 357 bytes of machine code, small enough to check by hand. It turns hexadecimal
   text, each byte as two digits, into a program. A copy written out with notes lets anyone
   rebuild it and compare.
2. Four small tools, each written in the language of the one before: hexadecimal with simple
   labels; full labels, which also puts each finished program together; joining files; and
   the assembler, which turns instruction names such as add and jump into machine code.
3. The engine: written by hand in assembly, built by the assembler and the label tool.
4. Etale's rules: Etale's definition of itself, in Etale, run by the engine.
5. The file to check, and any texts to read as its types.

Underneath, an operating system loads and runs each program: Linux at first, later a tiny
operating system built from the same seed.

What must be right: the seed, the operating system, the four tools' source, the engine's
source, and the rule files, which a person reads as Etale. Everything else is a tool whose
output the engine checks: fmt, a faster runner, the display, the graph view, an English
rendering, the AI pane, and Claude.

Why not hexadecimal alone: with no labels, every jump is counted by hand, and one inserted
instruction shifts them all. The four tools cost little and give names.

Fixed: 32-bit x86 first, since the seed and the tiny operating system are written for it;
and whole numbers of any size, as lists of digits in base 10000, so a 32-bit machine holds
every step.

Names, for looking things up: the seed and the four tools come from stage0-posix, where the
seed is hex0, the tools are hex1, hex2, catm and M0, and their assembly is M1. The tiny
operating system is builder-hex0, from live-bootstrap.

### 5.2 The engine

Eight parts, each small and tested on its own. Memory, loading and running follow Zig's
bootstrap ideas without its parts (no WebAssembly, no committed binary, no C compiler). A
guess at its size, to be measured: a few hundred to about a thousand lines of assembly. It
stays small enough to read in full.

1. Memory: one flat block, set aside at load. Space is handed out by moving one pointer
   forward and is never freed: the engine checks once and exits. A list pair is two 32-bit
   numbers, each a place in the block, so nothing can point outside it. A full block stops
   the check with exit value 3.
2. Loading: the four calls to the operating system (3.10), each behind one routine. Nothing
   else calls the operating system, so leaving Linux changes only these four. Input is read
   through a small buffer.
3. The reader: lines to lists. Indentation becomes nesting; words, numbers and quoted texts
   become atoms. Refused at their line: a tab, a line two steps deeper than the one above,
   `#`, a carriage return, any character outside 3.5, outside a quoted text any character no
   form uses, two blank lines together, and a blank line inside an item (one followed by a
   line two or more steps in). A command prints the tree as bracketed lists, so the reader can be
   checked by eye.
4. The file as facts: the tree becomes the built-in types of 5.3, its lines, words and
   paragraphs with their counts, and a text to read becomes its characters.
5. The rule loop: for each contained-in rule, find every match of its restriction among the
   facts, fill in the names, and add what its union says follows, until nothing new appears.
   A match of a rule contained in the empty union is a refusal.
6. Unions and there exists: a result that is a union of several cases branches, one branch
   for each. A result that says a value exists makes a new element. Both count against the
   step budget (3.10): a check that runs out stops with exit value 3, never a wrong verdict.
7. Numbers: comparing, adding, multiplying, the remainder and `divisible_by`, on whole
   numbers of any size. These are atoms, since arithmetic as rules would be far too slow.
8. Verdicts: accepted, with the result's printed text on standard output; or every refusal
   on the error output (3.9); then the exit value (3.10).

### 5.3 The rule files

Etale's definition, written in the core's part of Etale (section 4), run by the engine. Each file rewrites forms
into the core and checks them. Each form's rewrite should be short enough to check by reading.

1. Forms: every block and line is a form of version 1, in the paragraph order and within the
   limits (3.4), with the checks on how code is written (3.9).
2. Names: every name is defined above where it is used; a path has one dot; a call gives every
   starred field, by name.
3. Case tables: every field worked out by cases gets exactly one value, tried by parts of each
   input's range, not every value: each input is split at the numbers the cases name and by
   the divisors they test, so is_leap needs 400 parts, not 10,000 years. A refusal names a
   value with no answer or two ("month 4 in a leap year gets both 30 and 29"). Then the case
   checks of 3.9.
4. Claims: each numbered step follows (3.8), with induction and citations.
5. Texts: a text reads as its type in exactly one way; printing a value as a text, such as
   Date's `european`; and the text checks of 3.9.
6. Values: the value checks of 3.9.

Alphabetical (3.6) is written here too.

Finding that a text has exactly one reading, splitting ranges into parts for case tables, and
the number checks of 3.9 all start as rules (chosen 25 November). The engine's atoms stay as
section 4 has them: a value's field, a character at a place, and the number facts. A check
moves into the engine only if phase 2 measures it as too slow, and then as a general routine
over facts the rule files produce, so the engine still never learns a form. Reading is the
check most likely to move.

Every file is checked by the whole set of rule files, always. A file never names its own
rules, so nothing can opt out of a check, and the set's checksum is recorded with the engine's
(chosen 25 November).

What the rule files see (chosen 25 November): the engine hands over the file being checked,
and any text being read, as built-in types, the way Letter and Digit are built in. Each
limit of 3.4 comes with its count as a field, so every limit is one impossible block. A field
that does not apply, such as the line above the first line, is absent, and a rule that names
it matches nothing there. The field names, and how a line splits into words, are Claude's
defaults, to change at review (word_count, under_count, Word's length, Quoted_Character and
Input_Text were added on 26 November for phase 2, answering 7.4):

- Line, one for each line that is not blank: number (in the file, blank lines counted), depth
  (steps of indentation), holder (the line it sits under), above (the line before it), length
  (characters, indentation included), place (among the lines directly under its holder),
  word_count (its words), under_count (the lines directly under it, 0 for none),
  choice_count (choices joined by `|` on it), type_place (for a line that starts a type, its
  place among the file's types), paragraph (the one it is in).
- Word, one for each word of a line: line, place (on its line), next (the word after it), kind
  ("name", "number", "quoted" or "mark"), text (for a quoted text, what is between the
  quotes), length (the characters of its text), name_word_count (for a name, its words
  between underscores).
- Paragraph, one for each run of lines with no blank line in it: holder (the line of the type
  it is in, absent at the top of the file), place (among its holder's paragraphs, or the
  file's), before (the paragraph before it), first_line, last_line, item_count (at the top of
  a file, its definitions).
- Quoted_Character, one for each character of a quoted word, between its quotes: word, place,
  value, code, next. A rule needs these to read a quoted text such as `" > "` from an input
  text, since no form takes a text apart.
- Input_Text, one for the text being read: type (the name of the type it is read as), printed_as
  (the name of the text it is printed with: "text" unless the command line names another,
  such as "european"), length (its characters). The last character is the one whose place is
  the length.
- Input_Character, one for each character of a text being read: place, value (the character
  as a quoted text, or Newline), code (its code number), next (the character after it).

A rule file may also give a starred part the type `Number` (any whole number) or `Text` (any
text). Only a starred part can have them, since they have no end; they let a value such as a
representative of a range, or a quoted word's text, be handed to a call. They are names of
the rule files only, like Line and Word, and no version 1 file sees them (chosen by Claude on
26 November, to change at review).

A line splits into words at spaces. A quoted text is one word, spaces and all. Each of `:`, `(`,
`)`, `,`, `|`, `*` and a run of dots (`.`, `..`, `...`) is a word of its own even with no space
around it, except a single point between two digits, which stays in its number; a minus right
before a digit belongs to the number. So `(Stop... 1..)` is the words `(`, `Stop`, `...`, `1`,
`..` and `)`, and `previous.quotient` is `previous`, `.` and `quotient`.

### 5.4 Phases

| Phase | What | Done when |
|---|---|---|
| 0 | Corpus | the examples are in files, with a test list of section 6's texts and verdicts, and one file for each mistake listed there. Done 25 November: examples/ and tests/ |
| 1 | Test engine | a short engine in the small Scheme below, on Chibi-Scheme, runs the frozen core (engine parts 3 to 8). It is a test bench, not part of the chain, and is deleted after phase 5. Done 26 November: test_engine/ (5.6) |
| 2 | Etale as rules | the rule files rewrite every example into the core and give section 6's verdicts on the test engine. This is the milestone: Etale defined in Etale |
| 3 | Seed tools | in an empty system holding only the seed and the four tools' pinned sources, the seed builds the four tools, and a test program in assembly copies a file to its output and exits with a value |
| 4 | The engine in assembly | built part by part, translated by hand from the test engine; each part gives the test engine's output on its tests |
| 5 | Agreement | both engines give the same verdict on every example; the engine's checksum is recorded with the versions, and the test engine is deleted. Etale now runs from the seed |
| 6 | No Linux | the same in a virtual machine, with the tiny operating system in place of Linux |

The test engine stays only until both engines agree on every example, then it is deleted, so
the repo ends with no language but Etale and the engine's assembly (chosen 25 November). It
runs on Chibi-Scheme, since Guile cannot be had here (5.5). It uses only this part of Scheme,
so that it reads as plain code and translates to assembly part by part: `define`, `lambda`, `if`, `cond`, `let`, `let*`, `letrec`, named
`let`, `and`, `or`, `not`, `quote`, `begin`; `cons`, `car`, `cdr`, `list`, `append`,
`reverse`, `length`, `map`, `for-each`, `assoc`, `member`, `equal?`, `null?`; `char=?`,
`char->integer`, `string->list`, `list->string`, `string-append`, `string=?`,
`string->symbol`, `symbol->string`; whole numbers below 100,000,000, so every step fits in
the 32 bits the assembly engine holds (`+`, `-`, `*`,
`quotient`, `remainder`, `=`, `<`, `<=`, `>`, `>=`); `read-char`, `peek-char`, `eof-object?`,
`open-input-file`, `display`, `newline`, `exit`, `command-line`, and `current-error-port`
(added 26 November, so refusals go to the error output as 3.10 says). Not `set!`, macros,
`call/cc`, exceptions, records, hash tables, vectors, floating point or modules. Its names are
whole words.

Claude's suggestions, not chosen:

- Before the test engine's rule loop is written, draft the two hardest rule files, names and
  reading, to try the rule-file forms on real lines before the engine depends on them.
- Reach the milestone with the first five rule files, then add the values file before phase 4.
  The value checks are the largest part of version 1 and need the rest working first.

### 5.5 What this workspace can do (checked 25 November)

- 32-bit x86 programs run here: one built with nasm and ld wrote its text and exited with 42.
- Installed: gcc, GNU as and ld, nasm, gdb, objdump, make and git. Not installed: any Scheme,
  and QEMU. Chibi-Scheme builds from its source in a few minutes (make, then make install
  into a folder of the workspace). A new session does not keep the build, so each builds it
  again. Phase 1 used Chibi-Scheme at commit bf73c0c (24 November 2026).
- Package installs and downloads from the shell are refused, but git clones public GitHub
  repositories through the session's proxy: stage0-posix and Chibi-Scheme both answered. So
  phase 3's sources can come by git, and Chibi-Scheme can be built with the C compiler here.
  Guile is not installed and cannot be downloaded.
- The engine in the chain is built only by stage0-posix's own tools. nasm and gdb are for
  trying things out and finding bugs, never for the engine that is trusted.
- Phase 6 needs QEMU, which is not here.

### 5.6 The test engine (phase 1, built 26 November)

test_engine/engine.scm is the test engine, and test_engine/tests/ holds its own tests. From
the top of the repo, with Chibi-Scheme built (5.5):

```
chibi-scheme -h 1G -I test_engine -x small_scheme test_engine/engine.scm COMMAND
```

- `tree FILE` prints the reader's tree as bracketed lists, a line of the file to a line
  (engine part 3).
- `facts FILE [TYPE [TEXT]]` prints every built-in fact the rules see (part 4).
- `check FILE [TYPE [TEXT]] [print NAME] [steps N] [rules RULE_FILE ...]` checks a file, and
  a text read as TYPE, with the whole set of rule files or the ones named last. `print NAME`
  names the text it is printed with, such as european (added 26 November; until then the
  rules print with `text`). A TYPE with no TEXT reads standard input. Verdicts and exit
  values are those of 3.10.
- `made FILE [TYPE [TEXT]] [print NAME] [steps N] [rules RULE_FILE ...]` prints every value
  the rules made, type by type, then the refusals (added 26 November, to check rule files by
  eye as `tree` and `facts` check the reader).
- `test TEST_LIST` runs a test list and says which tests pass.

small_scheme.sld names the part of Scheme in 5.4. The engine runs with only those names, so
a name outside them stops it before anything runs. `-h 1G` gives Chibi-Scheme a large heap
from the start; without it the engine runs about half as fast.

The engine's tests (test_engine/tests/test_list.txt, 72 tests, all passing) cover each part:
the reader's refusals, and its tree of dates.etale; the limits of 3.4 as a rule file
(rules/limits.etale, moved there on 26 November), which accepts the eight examples and every
rule file, and refuses a file that breaks each limit at the right line; a walk up the lines
through a type that calls itself one step on; numbers of up to 36 digits; a union tried
member by member; a text printed back exactly; a refusal naming a line of the file and a line
of the text; the step budget running out; and rule files the engine refuses. The whole set of
rule files is the list `whole-rule-set` in engine.scm (5.7).

What the engine does, and Claude's choices in it, to change at review:

- The reader: a step of indentation is two spaces, and a line indented by an odd number of
  spaces is refused. A line of only spaces is blank. A quoted text with no closing quote is
  refused. A `#` is refused outside a quoted text; inside one it is part of the text. A first
  line that is indented is refused as two steps deeper than the one above.
- The facts are those of 5.3, with these choices. A Word that is a number also has `number`,
  its digits as a whole number without the point, and `places`, the digits after the point:
  19.99 has number 1999 and places 2. A word's `text` is the word itself, or for a quoted
  text what is between the quotes. A line with no `|` has a choice_count of 1. A line starts
  a type when it is at depth 0 and has lines under it. A paragraph is a run of lines with no
  blank line in it that are under the same type, so a type's name line is in a paragraph of
  the top of the file, and the lines under it are in the type's paragraphs.
- Rule files: besides the four forms of section 4, the engine reads one-line definitions (a
  value, a choice, a range, or a calculation of constants), a worked-out field that is a
  calculation or a copy of a name or path (with `wrap_at` under it if any), and a call. A
  part is matched among the facts when its type is a built-in or rule type, a choice of
  them, or a choice of values such as `Bit: 0 | 1`; only a starred part may have a range. A
  rule file uses whole numbers only, and the engine refuses a rule file that uses a name
  above its definition, a field its type does not have, or a call that does not give every
  starred part by name.
- How the forms become the core: each match of a type's parts is a value of the type, made
  once (there exists); each case of a field is a rule of its own, giving the field its value
  where the case's facts hold (the union of the cases is on the side of what is given);
  `impossible:` is a rule contained in nothing. A case's facts are matched, never assumed,
  so a case naming an absent field matches nothing there (section 4).
- Found while building: with these forms no rule has a union on the side of what follows,
  so the engine never splits its facts into separate branches as 5.2's part 6 expected. A
  union is tried one member at a time instead (a part over `0 | 1` gives a value for each),
  and each member tried is a branch, counted as a step. If a later form puts a union on that
  side, part 6 grows to split.
- Atoms (section 4): `<` and the other comparisons also compare two texts, by their
  characters' code numbers (3.5). A rule needs this to say that two names differ, since no
  fact word says "is not": two texts differ when one comes before the other. Division gives
  a value only when it is exact, and `wrap_at` gives the remainder.
- What a refusal names: the first of the refused value's parts, in order, that is or holds a
  Line (its number), a Word (its line), a Paragraph (its first line) or an Input_Character
  (its place, and so its line of the text). A refusal that names a character refuses the
  input (exit value 1); any other refuses the Etale file (exit value 2). One rule naming the
  same lines twice is reported once.
- Printing: when a text is accepted, the engine prints the `value` of every value of the rule
  type named Printed_Character, in the order of their `place`.
- Steps: each full match of a rule, each new element (the built-in facts too) and each member
  of a union tried counts one. The default budget is 10,000,000 until phase 2 sets it.
- Speed, on this workspace's two cores: limits.etale checks the largest example in about a
  second. Two things keep it there: an index on the field named by a part's first `given` (as
  in `given start.line is line`), and a rule runs again in a pass only when a type or field
  it reads has changed since it last started. From 26 November a change is kept for each
  field of each type, not for each field name across every type, where the rule knows the
  type it reads: a new value of Name_Search's `line` had re-run every rule that reads any
  `line`, and timetable.etale went from 13.7 to 9.7 seconds. Measured with the first rule
  files, see 5.7.
- Size: engine.scm is about 2,200 lines of Scheme without comments and blank lines: the reader
  230, the facts 310, numbers 145, reading rule files and running them 1,050, verdicts 100,
  and the commands and test runner 230. Reading rule files is the largest part, so 5.2's
  guess for the engine in assembly may be low.
- The test list gains three kinds of line: `rules FILE ...` (the rule files for the tests
  below it, none if no file follows), `steps N`, and `tree FILE TREE`; and three verdicts:
  `ran out of steps`, `rule file refused at N`, and, for a text refused before any rule runs,
  `refused at N`, naming a line of the text. A text's line `TYPE TEXT printed as NAME FILE`
  checks the text with `print NAME` and compares what it prints with FILE (26 November).

### 5.7 The rule files (phase 2, started 26 November)

rules/ holds the rule files, run in the order of `whole-rule-set` in engine.scm. Each keeps to
every limit of 3.4, so a file holds at most 7 types, and each is accepted by rules/limits.etale
(tested in the engine's test list). The parts and the names below are Claude's, to change at
review; the person has not reviewed them.

The files so far:

1. limits.etale: the limits of 3.4 (phase 1).
2. terms.etale: every term a line can hold: a word (a number, a quoted text or a name), a path
   (`date.year`), a list used (`(stops)`, `(train.stops)`) and a list use (`(stops).count`,
   `(train.stops).first`), each as a Term with its first and last word. A Term is made for
   every place one could start, and the line around it decides which is meant: in
   `date.year is 2023` only the path is followed by a fact word. Term_Use and Name_Use mark
   the terms and names a definition or fact uses.
3. definitions.etale: what follows a colon, or the right side of a fact, as a Definition
   from its first word to its last: a term, a range, an open range (`1..`) or a choice, whose
   members are found by a walk along the `|` marks.
4. compounds.etale: a calculation (`hour * Minutes_Per_Hour`), a list declared
   (`(Stop... 1..)`, its count a Definition of its own) and a call, with its inputs found by
   a walk along the commas.
5. facts.etale: a fact as its left term, its fact word and a Definition for its right side.
6. blocks.etale: a type's line, a one-line definition, the items of a type, a field (starred
   or not, with its Definition), `impossible:` and texts such as `text:` and `european:`,
   and a claim.
7. fact_lines.etale: where facts stand: under a case, under `impossible:`, after `given`,
   `where` and `until`, in a claim, with or without steps, and in a step.
8. settings.etale: `places`, `wrap_at`, `unique`, `ordered by`, and the loop's `1.` and
   `2...` lines.
9. positions.etale: a text's numbered positions, with `digits` or without, and a step that is
   a call.
10. uses.etale: which names a term uses (the name, a path's first name, a list's inside), and
    a refusal for a path with two dots.
11. name_search.etale and name_steps.etale: a name is defined above where it is used. The
    search walks up the items of the name's own type, then the type's line, then the lines
    at the top of the file, and refuses the name if it reaches the first line without
    meeting it. True, False, Letter, Digit, Newline, Alphabetical and `previous` are not
    searched. The search starts at the item the name is in, so a field that names itself
    inside its own cases is not refused yet. Field_Use, Type_Use and Constant_Use link a name
    to the field, type or constant it means.

What they give now: every line of the eight examples is read as exactly one form (checked by
listing which form claims each line), and every definition and fact is read. On the corpus,
the eight examples are accepted and three mistakes added for the names rules are refused at
the right lines: a name not defined (names_undefined), a constant used one line above its
definition (names_used_above), and a path with two dots (names_two_dots). 11 tests pass and
29 wait. The corpus takes about 156 seconds; the largest example, timetable.etale, about 10.

Still to come, in this order:

- Forms: refusing a line that is no form, the paragraph order, and the checks on how code is
  written (3.9). A rule cannot see that a line read no way, since nothing is absent in a
  match, so each line's start will be classified by facts with known opposites (its depth,
  its holder's kind, its first word's kind and text), and a refusal written for each start
  that is no form, and for each form whose words stop before the line does.
- Names: a path's second name is a field of the first one's type, `unique` and `ordered by`
  name fields of the list's item, and a call gives every starred field of the type it
  calls, by name, and nothing else.
- Case tables (3 of the corpus's mistakes). Claude's outline: each field read in a case is an
  input; each input gets representative values (the members of a choice; for a range, its
  low end and each place the cases split it, and with `divisible_by` every remainder of a
  common multiple of the divisors, which gives is_leap its 400); a walk over the type's
  fields builds every assignment of representatives, with one more value for "not an input"
  so that a field the case table does not read passes through; each fact then holds or fails
  on a representative, both found as facts, since a fact on a known number has a known
  opposite; two cases holding on one assignment refuse the field's line, and so does every
  case failing on one.
- Claims (4), texts (21), and values.
- Speed: every pass matches every value again, so a walk of 15 steps costs 15 full passes.
  Matching only what is new since a rule last ran (semi-naive matching) is the fix to try
  next in the engine; it changes how the engine runs rules, not what they mean.

## 6. The corpus: what each example must do

These are phase 0's tests. The plain-English sentences say what each type means; since
comments are refused, they live here and not in the files. A text in quotes is one the type
must accept.

Every text and mistake below is a file in tests/, and tests/test_list.txt gives each test
with its verdict, grouped by example in this order (done 25 November). Its lines, with one
space between words:

- `examples/dates.etale accepted`: the file is accepted (exit value 0).
- `tests/dates_two_answers.etale refused at 18`: the file is refused at its line 18 (exit
  value 2).
- `Date tests/dates_2026-10-15.txt accepted`, one step under an accepted file: that file reads
  the text as a Date and prints it back exactly as it was (exit value 0).
- `Date tests/dates_2023-02-29.txt refused by 30 at 1`: the text is refused by line 30 of the
  Etale file, at line 1 of the text (exit value 1).
- `Date tests/dates_2026-10-15.txt printed as european tests/dates_2026-10-15_european.txt`:
  accepted, and printed with the european text it gives that file.

A file holds its text exactly. A Date's text has no Newline, so a date's file ends without
one; every other text ends with a Newline. A mistake is a copy of its example with one
change, and is refused once: a type that uses a refused type is skipped. Which lines a
refusal names is in 3.9. How the command line names the type, and a second text to print
with, is open (7.3).

### dates.etale

- Date: a calendar date in the Gregorian calendar, as in "2026-10-15", or "15.10.2026" in
  europe. Every 4th year is a leap year, but not every 100th, unless it is every 400th. Four
  months have 30 days. February has 28, but 29 in a leap year. The rest have 31. A day is
  never past the days in its month.
- February_2023: in 2023, February has 28 days, since 2023 is not a leap year. So 2023-02-29
  is not a date.
- Accepts 2026-10-15, 2024-02-29 and 2000-02-29. Refuses 2023-02-29 and 1900-02-29. Prints
  2026-10-15 as european, 15.10.2026. February_2023 holds.
- Mistakes it must refuse: the 29 case without `month is 2` (a value gets two answers: month 1
  in a leap year gets both 31 and 29); the 400 case dropped (no year divisible by 400 gets an
  answer, the first being year 0); February_2023's step as `date.is_leap is True`, which does
  not follow.

### train.etale

- The file: a train and its stops, as in "R10 fast 60", with one line for each stop after it.
- Time: a clock time, as in "09:20". Line_Code: a line, as in "R10". Station_Character: a
  space or a letter. Station_Name: a letter, then letters and spaces, at most 20 in all.
- Stop: one stop, as in "Drammen 09:20 +4": the station, when it is due, and how many minutes
  late. A stop is late from 2 minutes, and very late from 10. Otherwise it is on time.
- Train: a train, as in "R10 fast 60", then its stops in the order it calls at them. A fast
  train gives a refund when any stop is late, and none when no stop is late. A slow train
  never gives a refund.
- Very_Late_Refund: a very late stop on a fast train gives a refund.
- Late_Start_Refund: a fast train whose first stop is 30 minutes late gives a refund, as
  Very_Late_Refund shows.
- Accepts a fast train with a late stop ("R10 fast 60", a stop 4 minutes late: a refund), and
  a slow train ("R11 slow 30", a stop 12 minutes late: no refund). Refuses the fast train
  with a delay of 121. Very_Late_Refund and Late_Start_Refund hold.
- Mistakes: a refund case that overlaps another (the second taking a count in 0..1, so a fast
  train with one late stop gets both answers); a step that does not follow (Very_Late_Refund
  without its first step, so `stop in (train.late_stops)` would need the status case and the
  list rule at once); citing Very_Late_Refund for a stop 5 minutes late, which its `given`
  lines do not allow (Late_Start_Refund's first stop 5 minutes late).

### timetable.etale

- The file: a timetable: trains with their stops, then an index of the stations in name
  order. Time, Station_Character, Station_Name and Line_Code are as in the train.
- Index_Entry: one index line: a station name.
- Stop: one stop, as in "Drammen 09:20 +4". It arrives after its delay, past midnight if need
  be. It is late from 2 minutes, and very late from 10; otherwise it is on time. A stop that
  arrives before the day starts arrives at night.
- Train: a train, as in "R10 60", then its stops in the order it calls at them. No late stop
  is later than its train allows.
- Timetable: its trains, then "---", then the index in alphabetical order. Every stop's
  station is in the index, and every station in the index has a stop.
- Accepts this text, in which Drammen arrives at 00:10, so at night, and R10's average delay
  is 10.0:

  ```
  R10 60
  Asker 09:41 +0
  Drammen 23:50 +20
  R11 30
  Oslo S 10:05 +12
  ---
  Asker
  Drammen
  Oslo S
  ```

- Refuses: a station missing from the index; an index entry with no stop; a late stop past
  its train's max_delay_minutes; stops out of time order; a station twice on one train; an
  index out of alphabetical order (Oslo S above Oslo). Each is the text above with one change:
  Drammen left out of the index; Lier added to it; R10's max_delay_minutes 10, below
  Drammen's 20; R10's two stops swapped; a second Asker on R10 at 23:55; and a stop at Oslo
  on R11, listed below Oslo S.

### trip.etale

- The file: a trip on a network of links: the links, "---", a start, then one station a line.
- Nonstop_Link: as in "Oslo S > Drammen": a train goes straight from one station to the other.
- Network: its links, then "---".
- Leg: as in "Drammen": where it arrives. Where it leaves from, and its network, are given by
  its call. It goes along one of the network's links.
- Trip: a network, a start, and the station each leg arrives at.
- Accepts this text, whose legs go Oslo S to Drammen, then Drammen to Lier:

  ```
  Oslo S > Drammen
  Drammen > Lier
  Oslo S > Asker
  ---
  Oslo S
  Drammen
  Lier
  ```

- Refuses a leg with no link: the text above ending in Asker, since no link goes from Drammen
  to Asker. The engine checks a trip it is given; finding one is a tool's job.

### bank_account.etale

- Transaction: one transaction, as in "-60": money paid in or taken out. The balance after it
  is never below 0.
- Bank_Account: as in "100", then one transaction a line, as in "-60".
- Refuses "100", then "-60", "10" and "-120", at the third transaction: its balance after
  would be -70. Accepts a text whose balance never goes below 0: "100", then "-60" and "10".

### binary_conversion.etale

- Division: a division, as in 6 by 2: 3, with 0 left.
- Binary_Conversion: writing a number in binary, the number given by its call. Divide it by
  the base, then divide each quotient by the base until it is 0. The remainders are the
  binary digits, lowest first: 6 gives divisions of 6, 3 and 1, with remainders 0, 1 and 1.
- The file is checked. It runs when a call gives it its number; no test runs it yet, since
  how a call comes from outside is open (7.3).

### decimals.etale

- Sku: a product code, as in "ABC-0001".
- Line: one order line, as in "ABC-0001 x3 @ 19.99".
- Accepts "ABC-0001 x3 @ 19.99". Refuses a price of "19.9" for its places.

### xor.etale

- Bit: 0 or 1.
- Xor: two the same give 0, two different give 1.
- Xor_Associativity: xor is associative: (a xor b) xor c is a xor (b xor c). The engine proves
  it by trying all 8 values of a, b and c.
- Mistake: a case where left 0 and right 1 give 0, refused at a 1, b 0, c 1.

## 7. Open questions

### 7.1 Before phase 1

Phase 1 is done (5.6). All settled on 25 November: the test engine (5.4); how the core is written, and how a rule
refers to itself (section 4); what the rule files see, and which rule files check a file
(5.3); one step budget (3.10); and rules before atoms (5.3).

### 7.2 Found when the docs were joined (25 November)

Each was a place where two decided things disagree, or a form was missing. All are settled.

1. Settled: carriage returns. The character decision refused a carriage return, but the HTTP
   example read texts with them. The person chose to keep carriage returns refused everywhere,
   so the HTTP example left version 1 (25 November), and with it `Return`, `Character`, `base`
   and a count taken from a field (section 8).
2. Settled: comparing a wrapping value. The 25 November list of checks dropped the
   24 November exception for a fixed value, which the timetable's `arrives < Day_Starts`
   needs. The person chose to bring it back (25 November; 3.9).
3. Settled: "a type with no texts". Read word for word, it refused every type without a text,
   such as Division, Xor and the claim types. It now means a type no value can have
   (25 November; 3.9).
4. Settled: a value given at a call. The bank account gives `previous.balance_after`, worked
   out as -1000 or more, to `balance_before*: 0..`. Impossible blocks count as facts about
   every value, so the check knows it is 0 or more (25 November; 3.9).
5. Settled: citing a claim. A step calls the cited claim, giving its parts by name, and
   train.etale's Late_Start_Refund uses it (25 November; 3.8).
6. Settled: facts in a `where`. The 24 November rule allowed only `in` a choice or a range,
   the comparisons and `divisible_by`, but the examples also use `is` (the trip's legs) and
   `in` a list (the timetable). Both have opposites the engine can work out, so `where` takes
   them too; the person kept this (25 November; 3.3).
7. Closed: the engine outline listed `previous` and `last` in loops as open. They were settled
   on 24 November (3.3).

### 7.3 When their phase comes

- Counterexamples: suggested that a claim tried on every value, when it fails, names the value
  that breaks it. The xor mistake already expects it; tests compare only verdicts and lines,
  so it blocks nothing. Counting up from each part's lowest value, the last part changing
  fastest, the first value that breaks the xor mistake is a 1, b 0, c 1.
- In a `where` fact, `Stop.station` names the list's item, or the type the line is in. If a
  type ever filters a list of its own type, it could mean either. No example does this.
- Whether `min` and `max` earn their words.
- Whether `digits` goes on its own line under a text position.
- Whether a second text, such as `european`, also reads, or only prints. Version 1 only prints
  it.
- Rounding to a unit that is not a place, such as 0.05, is written in two fields for now: a
  count of the unit with `places 0` (`twentieths: price / Five_Cents`), then the count times
  the unit (`price_shown: twentieths * Five_Cents`). Whether it earns a word is open.
- The blank-line hint. When a file was refused with no count to name, the JavaScript engine
  named the first line that did not read, then tried a blank line above it and said whether
  the file then read (commit 535871c, 18 November). Whether the new engine gives such a hint
  is not decided.
- How the command line names the type a text is read as, and a second text such as
  `european` to print with. The test list names both; 3.10 does not say. The test engine
  takes them as `check FILE TYPE TEXT print NAME` (26 November, 5.6), so the test list's
  printed line runs; what the engine in assembly takes is still open.
- How a call is given from outside, so that binary_conversion's 6 can be a test: it has only
  a starred part and no text.
- The test list's shape is written in plain words in section 6. Claude's suggestion, not
  chosen: write it as an Etale type, so the engine checks the list as well. Its lines have
  three shapes, so it needs a choice of record types read from a text, which no example uses.

### 7.4 Found in phase 1 (26 November)

Each needed an answer by phase 2. Three were answered on 26 November with Claude's defaults
(5.3), to change at review; one is open.

- Open: skipping a type that uses a refused type (3.9) is not done: the engine reports every
  refusal its rules find. Nothing may depend on whether a refusal happened (3.7), so the skip
  cannot be a rule; it would be part of how the engine reports. How the engine would know
  that one type uses another is open. None of the corpus's mistakes seems to need it, since
  in each the types that use the refused one still hold; this is to be checked when the case
  tables and claims are written.
- Answered: a walk's end. The first line of a file is the line at depth 0 whose place is 1,
  since a file's first line that is not blank is never indented, so no new field or refusal
  was needed. The last line under a line is the one whose place is its holder's under_count.
- Answered: where a text ends. Input_Text gives its length, so the last character is the one
  whose place is the length.
- Answered: the type a text is read as. Input_Text gives its type, and the text it is
  printed with.

## 8. Later

Nothing here is in version 1. "After the GUI" waits until the GUI works; "later" has no time
set; "not decided" still needs a decision on what it should be.

Forms and data:

- HTTP framing, the driving example for networking: a body framed by its Content-Length, and
  chunks with sizes in hex. It left version 1 on 25 November, since carriage returns are
  refused, and needs them back in input texts, with the names `Return` and `Character`, `base`
  after a text position, and a list's count taken from a field read before it. Later. The
  example is at commit 0c1f420 (examples/http_framing.etale).
- Types that hold each other, for JSON, XML and bracketed expressions. Later. Needs the
  positive-only rule (3.7) and a rule that a type reads at least one character before coming
  back to itself (about the engine finishing, not about meaning), and an exception to names
  before use, preferably only where the later type uses the earlier one in return. Neither
  changes the frozen core.
- Unicode (3.5), character ranges such as `"A".."Z"`, exact fractions, binary64, bytes and
  binary files (including bytes as a second shape on a record), text operations
  (case-insensitive compare, join, split, search, replace), sorting, and lookups by a text key
  or a unique key without a full scan. Later.
- Type intersection, one text read as two types at once. Not decided.
- Reachability: the rule loop can work it out, but no form lets a file state it. Not decided.
- Reading a list from its last item, and the levels of isomorphism. Not decided.

Reuse and organizing code:

- Types that take a type ("a ledger over any Money"), together with abstract theories and
  models: a sort would be a starred field whose value is a type, and a model the call that
  fills it in; its claims need step proofs, since there are no values to try. The 23 October
  rule that a model's link to its theory is a data text stands for then. Later.
- A case table passed as a value, a list given to a call, imports, private names, a library
  file, packages, and citing claims across files. Later.

Proofs and correctness:

- Proof search; rewriting and reasoning by equality (with theories); machine-made tests
  (every short text, random texts, print then read); which facts still hold as a text grows.
  Later.
- Intent tools: witnesses and near misses, a plain-language read-back, examples kept in the
  file, what changed in meaning on each edit, refusals for unrelated units, the interview to
  completion, the goal graph, and assumptions retracted by version. Later.
- The proof player, proof traces, the Claims view, and "can" and "can't" for each case of a
  type. After the GUI.
- Export to Lean. Not decided: Etale's meaning is now written in Etale, in the rule files.

Costs, limits and speed:

- Costs. The Gleam checker reported each record's worst case in list counts, and a type could
  promise `cost <= ...`, refused when broken. Whether to carry the report and the promise,
  whether costs become exact step counts, and whether costs per version are still wanted.
  Later.
- Limits worked out before reading input from strangers (size, depth). Later; version 1 has
  the step budget and fixed memory.
- A speed target. Not decided; phase 2 measures speed, and looking facts up by their first
  word is the first fix if it is slow.
- A compiled runner (route B, kernel.etale, wasm.etale, an x86 backend, the speed ideas taken
  from Zig): it would be a tool whose results the engine checks. Not decided.
- Caching checks by hash, possible because every run gives the same result. Later.

Running:

- Reading files other than the input, reading a text as it grows, clock and randomness (each
  needs a decision on how it stays checkable), and the engine as a library other programs call.
  Later.
- Execution: event logs, events in, an outbox of messages out. Later.
- The engine beyond 32-bit x86 Linux (a browser, a phone); GPU; hard real time. Later.

Tools:

- fmt, one layout for every file. After the milestone.
- Commands: check a folder, bundle a project, run with a trace, print a type's code. Before
  the GUI, the one exception to the GUI items.
- The graph command (SVG) and the sequents printout. After the GUI.
- Editor support, a trace or debugger, a REPL, a profiler, CI, a package registry, a docs
  generator, and a tool that updates files when the forms change. Later.

The GUI and workspace, after the GUI works:

- The display and graph view; the AI pane, for any model, local or hosted, with a generic key
  and a toggle to send the language or a subset.
- The canvas workspace: Code and Types views, file colours, search, back and forward, data
  panes; the glass skin, puzzle panes, Claims view and alluvial diagrams; the version grid and
  a phone layout; the GitHub Pages site and playground.
- AI beyond the pane: proposals checked before anyone sees them, generalizing two types
  without AI, and a live agent.
- For people who don't program: a fixed English reading and a fixed picture for each form,
  and writing by edge cases.

Projects and versions:

- Projects with folders as scope; versions as hashes, cached checks, locks and packages;
  growing texts ("verified up to here"). Later.

The larger goals:

- The Etale machine; a network of proof machines in which every message carries a proof its
  receiver checks; graph union; finding versions by hash; provenance by physical links;
  hash-based signatures. Later.
- Other languages: their values checked at boundaries, and the checker as a library. Later.

Decided against: confidentiality (proven physical paths are preferred to encryption);
warnings (every check refuses); grapheme clusters in the engine.

## 9. Tried and retired

Not to come back unless the person asks.

- The Gleam host, its checker and prover, the canvas workspace and the site (to 16 November):
  retired so Etale needs no outside language. At commit bacec75.
- The brace forms (`Name {Type}`, `value:`, `if:`, `{Needs}`, `{Claims}`), optional fields
  (replaced by unions, 19 November), language.etale reading itself through engine/seed.json,
  and the JavaScript engine (to 19 November). At commit ca81f1e.
- Route B (compile.etale, Etale to a small stack machine), kernel.etale, wasm.etale and the
  x86 backend plan (16 to 19 November): off the path since 24 November (section 8).
- Lean for Etale's bounds and meaning: replaced on 19 November by Etale's meaning in Etale.
- GNU Mes and its C compiler in the chain (24 November): replaced on 25 November by the
  engine in assembly.
- Comments, with the Simplified Technical English writing rules (11 November): refused since
  24 November. The plain-English sentences live in section 6.
- Chains with `otherwise`, where a lower line wins (23 November); the walk
  `train on_time_up_to stop` (replaced by a filter, 24 November); case tables outside their
  types, context paths such as `Train.max_delay`, a range ending at a worked-out field
  (`day: 1..days_in_month`), a list given to a call, abstract theories and models in version
  1, and the 20-line and 100-character limits (all replaced on 25 November).

## 10. The repo, and how work is done

The repo holds:

- README.md: what is here.
- PLAN.md: this plan.
- examples/: the eight example files, version 1's definition. The rule files read every line
  of them as its form and check their names (5.7).
- tests/: section 6's texts, a file for each of its mistakes, and test_list.txt with every
  verdict (phase 0), and below them the mistakes written for the rule files' own checks
  (phase 2). The test engine runs the list; most of section 6 waits for the rest of phase 2.
- rules/: Etale's rule files (phase 2, 5.7), limits.etale among them.
- test_engine/: the test engine (phase 1, 5.6), small_scheme.sld, and in tests/ its own
  tests and test list. It is deleted after phase 5.
- LICENSE.

All work is on main, from 25 November; the old branches kernel and minimal are fully inside
it. Each phase adds its own files: tests/ beside the examples (phase 0), the test engine
(phase 1, deleted after phase 5), the rule files (phase 2), the pinned seed sources and build script (phase 3), and
the engine's assembly (phase 4). Few folders, each named for what it holds.

Older work is in this branch's history:

- bacec75: the Gleam host, as on 16 November.
- ca81f1e: the JavaScript engine and every file in the old forms, as on 25 November.

How work is done:

- Commits are authored as Ian Ward (28372885+ianjward@users.noreply.github.com), with no
  Claude author, no signing key, and no Co-Authored-By or Claude-Session lines.
- Before writing any Etale, read examples/. Never invent a form: when the forms cannot say
  something, say so and ask. Anything in the examples that looks wrong goes to the person as a
  question, not a change.
- Once the engine runs, try a form on real input before asking about it.
- From the first working check on, a doc shows an Etale example only if the engine accepts it.
- Docs are in plain words, in the style of the examples: no symbols such as turnstiles or
  Greek letters, no codes for decisions (say what was decided), and whole-word names in code.
- The claude.ai project holds a copy of this plan and of the examples. The repo is the master
  copy, and the project is updated with it. The project's 92 older docs (16 October to
  25 November) were deleted on 25 November; what was still in force is in this plan.
- Each chat ends by saying whether it needs to be kept: anything decided only in the chat goes
  into this plan first.

## Sources

- stage0-posix: https://github.com/oriansj/stage0-posix
- live-bootstrap and builder-hex0: https://github.com/fosslinux/live-bootstrap
- Chibi-Scheme: https://github.com/ashinn/chibi-scheme
- Zig's bootstrap, bootstrap.c: https://github.com/ziglang/zig/blob/master/bootstrap.c
- Go's bootstrap versions: https://go.dev/doc/install/source
- mrustc: https://github.com/thepowersgang/mrustc
- wisp (SRFI 119): https://srfi.schemers.org/srfi-119/srfi-119.html
- Fisher and Bezem, Skolem Machines and Geometric Logic: http://dx.doi.org/10.1007/978-3-540-75292-9_14
- Metamath: https://us.metamath.org/
