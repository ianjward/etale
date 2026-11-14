# The new engine

A small engine that grows beside the Gleam host, which stays as it is. The Gleam host is the
judge: on every type and every text that CI tries, both must give the same verdict, and on
every text that both accept, every field of every record must have the same value. When the
engine carries everything, the Gleam host can go.

To run the judge without CI, build main's checker first (it needs Gleam):

```
sh tools/build_ide.sh && node engine/judge.mjs
```

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

A refused text names what refused it:

```
node engine/etale.mjs read Book examples/book/book.etale examples/book/book_unknown.txt
refused
  Book.each_order_has_its_customer: orders.customer in customers.code
```

## What it carries, and what not yet

Carried: unions, intersections, refinements, layouts, records with their stored fields and text
shapes, counts, allowed values, constants by name, 'digits:', 'places:', a field that holds a
named list of records, worked-out values, kept and collected lists, methods (count, sum, min,
max), mappings, rules, claims, relations between lists, paths to a record around this one,
'round:' and 'wrap_at:'.

Not carried yet: 'unique:' and 'order:'. A text can break one of these and still be accepted by
the engine. 'node engine/etale.mjs rules FILE' lists them for a file.

## The two refusals

Decided on 14 November 2026, for this engine only:

1. A type that can reach itself before it reads a character is refused.
2. A list, or an item that may be absent, whose item can be the empty text is refused. Put a
   mark that always reads, such as a separator, in the item.

## Commands

```
node engine/etale.mjs self                 language.etale gives back the stored rules
node engine/etale.mjs seed                 store the rules that language.etale gives
node engine/etale.mjs check FILE           read FILE and what it sees; the two refusals
node engine/etale.mjs read TYPE FILE DATA  is the text of DATA a TYPE of FILE?
node engine/etale.mjs rules FILE           FILE's rules, in plain words
node engine/test.mjs                       the tests, with node alone
node engine/judge.mjs                      against main's checker; CI runs it
```

## The files

- read.mjs: the engine.
- evaluate.mjs: the values of a reading, and its worked-out fields.
- declarations.mjs: the declarations of a file, from the engine's reading of it as File.
- rules.mjs: declarations to rules, and a rule in plain words.
- checks.mjs: the two refusals.
- etale.mjs: the command line, and what a file sees.
- seed.json: the stored rules of language.etale.
- test.mjs and judge.mjs: the tests and the judge.

The engine itself, without the tests and the judge, must stay under 2,000 lines of code. The
tests check that.
