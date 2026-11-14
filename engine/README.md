# The new engine

A small engine that grows beside the Gleam host, which stays as it is. The Gleam host is the
judge: on every type and every text that CI tries, both must give the same verdict. When the
engine carries everything, the Gleam host can go.

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
list, with a least and a most count. A rule may say which numbers its whole text may write,
how many decimal places it writes, and that the number of one part compares with the number of
another part or with a constant. A union is one rule for each of its items.

From one start in a text, the engine finds every place where a type can end, in how many ways
(one, or two for "two or more"), and one reading for each end. So a text is accepted, refused,
or has two readings.

## What it carries, and what not yet

Carried: unions, intersections, refinements, layouts, records with their stored fields and text
shapes, counts, allowed values, constants by name, 'digits:', 'places:' on a refinement, a field
that holds a named list of records, and a rule that compares one field with another field or
with a fixed value.

Not carried yet: worked-out fields, kept and collected lists, mappings, claims, other rules,
'unique:', 'order:', 'round:' and 'wrap_at:'. A text can break one of these and still be
accepted by the engine. 'node engine/etale.mjs rules FILE' lists them for a file.

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
- declarations.mjs: the declarations of a file, from the engine's reading of it as File.
- rules.mjs: declarations to rules, and a rule in plain words.
- checks.mjs: the two refusals.
- etale.mjs: the command line, and what a file sees.
- seed.json: the stored rules of language.etale.
- test.mjs and judge.mjs: the tests and the judge.

The engine itself, without the tests and the judge, must stay under 2,000 lines of code. The
tests check that.
