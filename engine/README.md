# The new engine

A small engine that grows beside the Gleam host, which stays as it is. The Gleam host is the
judge: on every type and every text that CI tries, both must give the same verdict, and on
every text that both accept, every field of every record must have the same value. On every
file that CI tries, an error of a kind that the engine checks must be the same in both. When
the engine checks every kind of error that main does, the Gleam host can go.

To run the judges without CI, build main's checker first (it needs Gleam):

```
sh tools/build_ide.sh && node engine/judge.mjs && node engine/judge_files.mjs
```

Without Gleam, the file judge can take main's errors from a CI run started by hand, which
prints them, one line for each file it tries:

```
gh workflow run site.yml --ref BRANCH
gh api repos/ianjward/etale/actions/jobs/JOB/logs > main.log
JUDGE_MAIN=main.log node engine/judge_files.mjs
```

A file that the run did not print, such as one made by a newer mistakes.mjs, is counted and
not judged.

## How it starts

seed.json holds the rules of language.etale, one rule a line. The engine reads language.etale
with them, in exactly one way, and its reading gives the same rules back. That is the language
asserting itself:

```
node engine/etale.mjs self
```

No other reader is needed to start. The first seed was made once by a throwaway line reader;
since then the engine makes the seed from its own reading.

To change the syntax, do it in two steps. First change the declarations in language.etale in
forms that the current seed still reads, and store the rules that they give:

```
node engine/etale.mjs seed
```

Then write files in the new forms.

## One rule shape

Every kind of declaration becomes rules of one shape:

```
a text is a HEAD when it is these parts in a row, and each part is that
```

A part is a literal, a type, or several types that read the same characters. A part may be a
list, with a least and a most count. A rule may say which numbers its whole text may write and
how many decimal places it writes. A union is one rule for each of its items.

A record's rule names its stored fields among its parts. Its other fields go on the same rule,
as data, with constants and types of one value written out as their values:

```
a text is a Time when it is: Hour.2 (hour), then ":", then Minute.2 (minute);
  where hour_minutes is hour * 60; where minutes is hour_minutes + minute
```

These are worked-out values (with 'round:' and 'wrap_at:'), kept and collected lists,
mappings, rules and claims. 'node engine/etale.mjs rules FILE' prints them in these words.

From one start in a text, the engine finds every place where a type can end, in how many ways
(one, or two for "two or more"), and one reading for each end. So a text is accepted, refused,
or has two readings.

## Worked-out fields

evaluate.mjs works out the fields over the reading, as language.etale says:

- Every field is a value or INVALID, and what is worked out from INVALID is INVALID. While the
  text is read, a record with an INVALID field has no reading. A rule that does not hold is
  INVALID. A claim is INVALID only when it is false. A mapping is INVALID when an input is
  INVALID or when not exactly one case is left (Step 8).
- A path that starts with a type, 'Train.max_delay', reaches the nearest Train around this
  record. It is worked out once the whole text has one reading. If there is no Train around
  it, or a rule over it does not hold then, the text is refused.
- Numbers are exact. A quotient and 'round:' round to the unit: a tie goes to even, or as
  'away', 'lower' or 'higher' says. 'wrap_at:' never gives a number below 0.
- A list is one value only when it holds at most one item, and then 0 when it is empty.
- A relation between two lists of the record, '(orders.customer in customers.code)', holds
  when every value on the left is a value on the right.
- 'unique: code' on a list: while the text is read, a list with two items of the same key has
  no reading. Numbers are the same by value, anything else by its text.
- 'order: due.minutes' on a list: once the text is read, a key below the one before it refuses
  the text. 'order: Station_Order.rank' on a text field names the mapping that ranks its
  characters, and its texts compare by those ranks, character by character: in a list's
  order and with < <= > >=. A text with a character that has no rank is never out of order.

A refused text names what refused it:

```
node engine/etale.mjs read Book examples/book/book.etale examples/book/book_unknown.txt
refused
  Book.each_order_has_its_customer: orders.customer in customers.code
```

## What it carries, and what not yet

Every line of every file in the repo is carried: unions, intersections, refinements, layouts,
records with their stored fields and text shapes, counts, allowed values, constants by name,
'digits:', 'places:', a field that holds a named list of records, worked-out values, kept and
collected lists, methods (count, sum, min, max), mappings, rules, claims, relations between
lists, paths to a record around this one, 'round:', 'wrap_at:', 'unique:' and 'order:'. A line
that the rules cannot carry is listed by 'node engine/etale.mjs rules FILE'.

## Checks on a file

file_checks.mjs finds the mistakes in a file's own declarations, before any text is read. The
words are the engine's own; the file judge compares only the verdict with main's:

```
node engine/etale.mjs check examples/mistakes/mistakes.etale
examples/mistakes/mistakes.etale:4: error: type 'Later' is used before it is declared (line 5) [Early]
```

Carried so far:

- Names: a type that is unknown, used before it is declared, or used by itself; a name
  declared twice, or a name of the language or a built-in name declared again; files that use
  each other.
- Fields of a record: a reserved name, a field written twice, a record that holds itself other
  than as a list from 0, a rule with no condition.
- Paths: an unknown field, a field below, a field that names itself, a step that is not a
  field, a list read as one value, a method that is not last or not on a list, '.sum' on a list
  that is not of numbers, a type that is not a value; a relation between two lists (each side a
  field of the items, with 'in' only, on a line of its own).
- A path to a record around this one, when something can hold this record without one around.
- Mappings: their inputs, their outputs, each case as a box, and the three checks of
  language.etale: the cases cover every input, no two cases overlap, and every output is
  produced.
- Numbers: arithmetic and order on what is not a number, as '(code * Two)' with code a Digit,
  also in the condition of a kept list; two texts compared with '<'
  by different orders; 'places:' and 'wrap_at:' only on numbers, and a wrap above 0; a
  calculation gives a number, TRUE or FALSE; decimal places that would need rounding, and a
  'round:' with nothing to round; a product or a quotient that reads two of its terms through
  a recursive field; a layout of a number too small for its range.

A kept or a collected list is not a field: a path of two or more steps through one is checked
as a path through its list, and only if the list is written above. A field names only fields
above it, but in a record with a text shape its stored fields may be named from any line. A
number written with 'digits: 2' must fit in 2 digits. A constant in a path is already a number.
The places of a number: + and - keep the larger number, * adds them. A kept list's condition is
checked once, at the kept list's own line.

Not carried yet: what needs the bounds of a calculation (a divisor that may be 0, a quotient
with no 'round:' that may not be exact, a calculation that may not fit its type and needs
'wrap_at:', a 'wrap_at:' that can never wrap, a wrapped value compared with '<' or used as an
order key), claims (the prover), costs, the checks on 'order:', 'unique:' and kept and
collected lists, and the mistakes that main's line reader finds before checking (a line in the
wrong form). The file judge counts each of these by kind.

## The two refusals

Decided on 14 November 2026, for this engine only:

1. A type that can reach itself before it reads a character is refused.
2. A list, or an item that may be absent, whose item can be the empty text is refused. Put a
   mark that always reads, such as a separator, in the item.

## Commands

```
node engine/etale.mjs self                 language.etale gives back the stored rules
node engine/etale.mjs seed                 store the rules that language.etale gives
node engine/etale.mjs check FILE           FILE's errors; the two refusals
node engine/etale.mjs read TYPE FILE DATA  is the text of DATA a TYPE of FILE?
node engine/etale.mjs rules FILE           FILE's rules, in plain words
node engine/test.mjs                       the tests, with node alone
node engine/judge.mjs                      texts, against main's checker; CI runs it
node engine/judge_files.mjs                files, against main's checker; CI runs it
```

The file judge tries every file of the library and the examples as it is, and with one mistake
made in it at a time (mistakes.mjs): about 1,500 files. Each must have the same verdict as main:
refused by both, or by neither. A file that main refuses only for a kind of error that the
engine does not carry yet is counted, not judged. It takes about 4 minutes. With
JUDGE_CACHE=FILE it keeps main's errors in FILE between runs, and with JUDGE_MAIN=LOG it takes
them from a CI log (see the top of this page).

## The files

- read.mjs: the engine.
- evaluate.mjs: the values of a reading, and its worked-out fields.
- declarations.mjs: the declarations of a file, from the engine's reading of it as File.
- rules.mjs: declarations to rules, and a rule in plain words.
- checks.mjs: the two refusals.
- file_checks.mjs: the checks on a file.
- etale.mjs: the command line, and what a file sees.
- seed.json: the stored rules of language.etale.
- test.mjs, judge.mjs and judge_files.mjs: the tests and the two judges. main.mjs loads main's
  checker for the judges; mistakes.mjs makes the mistakes that the file judge tries.

The engine itself, without the tests and the judges, must stay at or under 2,000 lines of code.
The tests check that.
