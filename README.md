# Etale

Etale is an experimental typed language that aims to be a human-readable version of positive
(geometric) logic. Its grammar is language/language.etale, which reads itself.

This branch is the smallest form of the repository: Etale files, and one small engine that
reads, writes, checks and runs them. It needs Node 22 and nothing else. There are no tests.

## What is here

- language/: every Etale file. language.etale is the language; every other file is the
  standard library, which every file sees.
- language/kernel.etale: the kernel, a small stack machine. Etale is to compile to its
  programs, and each program is to print as WebAssembly.
- engine/: the engine, about 2,100 lines of code, with its command line in etale.mjs. It goes
  once Etale runs on its own kernel.

## Commands

```
node engine/etale.mjs self                  language.etale reads as File and gives the stored rules back
node engine/etale.mjs seed                  store the rules that language.etale gives
node engine/etale.mjs check FILE            FILE's mistakes
node engine/etale.mjs fmt FILE [--write]    FILE in its canonical form
node engine/etale.mjs read FILE TYPE DATA   is the text of DATA a TYPE of FILE?
node engine/etale.mjs run FILE TYPE DATA    read DATA as a TYPE of FILE and show every value
node engine/etale.mjs print FILE TYPE DATA  the canonical text of DATA
node engine/etale.mjs rules FILE            FILE's rules, in plain words
```

For example, with a date from the standard library in date.txt:

```
node engine/etale.mjs run language/dates.etale Date date.txt
```

## How it starts

engine/seed.json holds the rules of language.etale. The engine reads language.etale with them
in exactly one way, and its reading gives the same rules back. To change the syntax, first
change the declarations in language.etale in forms that the stored rules still read, run
'seed', then write files in the new forms.

Every declaration becomes rules of one shape: a text is a HEAD when it is these parts in a
row, and each part is that. A record's rule also holds its worked-out fields.

## Printing

Printing is reading run backwards (language.etale, Step 9). A type that reads only spaces,
such as Pad, Gap or End_Spaces, prints its first form, and so does a position of a record that
holds no value. Everything else prints as it was read. The printed text must read back in
exactly one way, to the same values, or printing fails.

## Two refusals

1. A type that can reach itself before it reads a character is refused.
2. A list, or an item that may be absent, whose item can be the empty text is refused. Put a
   mark that always reads, such as a separator, in the item.

## Not carried yet

- The bounds of a calculation, and the checks that need them: a divisor that may be 0, a
  quotient with no 'round:' that may not be exact, a calculation that needs 'wrap_at:', a
  'wrap_at:' that can never wrap.
- Claims as a proof over every text. A claim is checked on each text that is read, not
  proved for all texts.
- The checks on 'order:', 'unique:' and on kept and collected lists, before any text is read.
- The seed is JSON, not a text of an Etale type.
