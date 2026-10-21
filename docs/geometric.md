# Compiles means geometric

The guarantee: **a file that compiles is a definitional extension of the base theory
(texts, integers, decimals), every formula in it is geometric, and every claim in it is
a theorem.** So the actual texts are always a model (the theory is consistent), and by
Barr's theorem the prover may reason classically about geometric claims.

This page maps each construct to the formula it means and says whether it is geometric.
`sheaf sequents FILE` prints a file's theory in the notation below. Every new construct
adds its row here and its case to `src/sheaf/sequents.gleam`.

## The base theory

- **Sorts.** Texts (finite strings of `Character`), integers, exact decimals.
- **Symbols.** Text literals, `⧺` (concatenation), number literals, `+ - *`, `= ≤ <`,
  and `digits(p)`, the number a text of digits spells in base 10.
- **Every atom is decidable, and its complement is positive.** `x ≠ y` on numbers is
  `x < y ∨ y < x`; on texts it is "they differ at some position, or one is longer",
  an existential over positions. So a hidden negation over these atoms (`qty = 0`,
  `<`, "no closer record") can always be rewritten without `¬`. This is the condition
  for every row marked GEOMETRIC IF DECIDABLE, and in Sheaf it always holds: every
  type is a positive combination of these atoms over a finite text, so whether a text
  inhabits a type is decidable too.

## Notation (as `sheaf sequents` prints it)

| Form | Meaning |
|---|---|
| `N(t) ⊣⊢ φ` | Definition of type N: both `N(t) ⊢ φ` and `φ ⊢ N(t)`. |
| `N(t) ⊢ t.f = e` | Definition of the computed field f, a total function. |
| `N(t) ∧ guard ⊢ t.f = c` | One case of a mapping. |
| `N(t) ⊢ φ    [claim]` | A claim; a theorem the checker proved, not an axiom. |
| `∃ a b. t = a ⧺ b ∧ …` | The text splits into its parts. |
| `X{n..m}(x)` | x is a list of n to m texts of X, one after another (below). |
| `t.f`, `t.lines.qty` | Paths, as written, starting from t. |
| `around(t, T)` | The nearest record of type T around t. |

Only `= ∧ ∨ ∃ ⊢` appear, with `≤ < ≥ >` between numbers.

## Constructs

| Construct | Formula or sequent | Verdict |
|---|---|---|
| Literal `"x"`, `{5}`, one-value type `True` | `t = "x"`, `t = 5`, `t = TRUE` | GEOMETRIC |
| Record, layout (sequence) | `∃ a b c. t = a ⧺ b ⧺ c ∧ A(a) ∧ B(b) ∧ C(c)` | GEOMETRIC |
| Conversion layout (`{Integer}` base) | `N(t) ⊢ t.val = sign(p1) * digits(p2)`; `digits` is total on digit texts | GEOMETRIC |
| Union `{A \| B}` | `A(t) ∨ B(t)` | GEOMETRIC |
| Intersection `{A & B}` | `A(t) ∧ B(t)`, over the same t. "Values come from A" is META. | GEOMETRIC |
| Counted list `{X n..m}`, `{X 2}` | `⋁_{k=n..m} ∃ x₁…x_k. t = x₁ ⧺ … ⧺ x_k ∧ X(x₁) ∧ … ∧ X(x_k)`, finite | GEOMETRIC |
| Open list `{X 1..}`, `{X 0..}` | The same with `k ≥ n`: an infinite disjunction, which geometric logic allows. On one text only `k ≤ len(t)` can hold. | GEOMETRIC |
| Recursive field `rest {R 0..1}` | R appears in its own definition: a definition only if the equation has one solution. It does when every way round the recursion reads text (well-founded on length). | GEOMETRIC IF IT READS TEXT; see Open 1 |
| Refinement predicates, `&` | conjunction of atoms | GEOMETRIC |
| Predicates joined by `\|`, choices `0 \| 10..100` | disjunction | GEOMETRIC |
| Comparisons `= < <= > >=` | atoms on numbers; on texts only `=` (ordering text is refused) | GEOMETRIC |
| `val = low..high`, `low..`, `..high` | `low ≤ x ∧ x ≤ high` | GEOMETRIC |
| Computed field, `+ - *` | `N(t) ⊢ t.f = e`: a new function symbol defined from earlier ones; total, since there is no division | GEOMETRIC |
| `mod = m` | `t.f = e mod m`: total only for `m > 0`. Now refused unless m is a positive number written out. | GEOMETRIC (with the guard) |
| `.qty` | `qty(ε) = 0`, `qty(x ⧺ xs) = 1 + qty(xs)`: defined by recursion on the list | GEOMETRIC |
| `.sum` | `sum(ε) = 0`, `sum(x ⧺ xs) = x.f + sum(xs)` | GEOMETRIC |
| Type-named filter `lines.Big_Line` | The recursion needs both `T(x) ⊢ …` and `not T(x) ⊢ …`; `not T(x)` is positive because T is decidable | GEOMETRIC IF DECIDABLE |
| `qty = 0`, "every item" (`xs.T.qty = xs.qty`) | Hidden `¬∃` / `∀` over a finite list; safe because the filter is decidable | GEOMETRIC IF DECIDABLE |
| Context path `Order.customer` | `around(t, Order).customer`. "Nearest" hides "no closer Order", decidable on a finite parse tree. Total because the checker proves the type always sits inside an Order. | GEOMETRIC IF DECIDABLE; see Open 2 |
| `{True}` rule field | a conjunct of the type's definition: texts that break it do not inhabit | GEOMETRIC |
| `{True}` with no predicates | would say nothing; refused | META |
| `{Fact}` claim | `N(t) ⊢ φ`, proved by the checker for every value | GEOMETRIC (a theorem) |
| Mapping field and its cases | one sequent per case; coverage and disjointness (checked by splitting at case boundaries) make the cases define a total function | GEOMETRIC IF DECIDABLE |
| `unique` | `N(t) ∧ N(u) ∧ rows_of_one_list(t, u) ∧ t.f = u.f ⊢ t = u`, a Horn sequent; `=` is the language's equality (numbers by value) | GEOMETRIC IF DECIDABLE |
| `places = p` | `places(x) ≤ p`, i.e. `∃ n. x * 10^p = n`. "No implicit rounding" is META. | GEOMETRIC |
| `print = n`, `cost <= …` | how printing and checking go; not formulas | META |
| INVALID | not a value of the theory: a text with a failed rule is outside the type's extension, and everything computed from it is refused with it | META |
| Exactly one reading | makes the `∃` in a record's definition an `∃!`, so `t.field` is a well-defined function | META |
| Scope, "declared above" | each definition uses only symbols defined before it (recursion excepted, above), so no definition is circular | META |
| Division, `!=`, `not`, `forall`, `->` in predicates | do not exist or do not parse | n/a |

## Every declaration is a definition

Each declaration introduces a new predicate (`N(t) ⊣⊢ φ`, φ in earlier symbols) or a new
function symbol (`N(t) ⊢ t.f = e`, e in earlier symbols, total). Rules, ranges and
`unique` narrow the predicate being defined; they say nothing about the base sorts. Claims
are proved, not assumed. So no declaration is an axiom that could make the theory
inconsistent, and the actual texts are a model.

Exceptions found:

- **Unguarded `mod`** (fixed). `mod = m` was accepted with a field as divisor, or with
  0 or a negative number; 0 silently meant "no wrap". It is now refused unless m is a
  positive number written out (`examples/mistakes/geometric.sheaf`).
- **Left recursion** (open, lang-6). `Loop {}  more {Loop 0..}` compiles. Its equation
  `Loop(t) ⊣⊢ Loop{0..}(t)` has many solutions (the empty text only, or every text), so
  it is not a definition; the parser picks the least.

## The prover

The claim prover (`check.gleam`, `prove_claim`) expands both sides into a polynomial over
stored fields by substituting each computed field's definition, cancels, and bounds what is
left by interval arithmetic. It does **not** case-split. It uses only:

- each stored field's own ranges and its type's ranges, which every inhabitant satisfies;
- for an item of the same record type (`rest.total`, `kids.total.sum`), the claim being
  proved: induction on finite trees, with an absent item read as 0 and hulled in;
- nothing else: it never cites another claim, and has no lemmas.

Mappings are checked by splitting each input at the case boundaries, which are decidable
intervals and literal sets.

One unsound step was found and fixed. A computed field with `mod` was substituted by its
definition without the wrap, so `later = hour + 5 & mod = 24` proved `later >= hour`,
false at hour 20. A wrapped field is now an atom bounded by `[0, m)`, which still proves
`later <= 23`.

As a second line of defence, `run` now evaluates every claim on the data. A claim that was
proved but fails there is a checker bug: the text is refused, and the message says so,
instead of showing a false TRUE.

## Open

1. **Left recursion** (lang-6). Refuse a type that can reach itself without reading a
   character; until then, a recursive type is a definition only when every cycle reads
   text. `examples/mistakes` should gain `Loop {}  more {Loop 0..}`.
2. **Context paths need a sort of positions.** `around(t, Order)` is a function of where
   t sits in the whole text, not of t alone. The sequents print it as a function symbol;
   the Lean export (later-3) needs it explicit: a sort of nodes of the parse tree, with
   `parent` and `text` functions, and `around` defined by recursion up the tree.
3. **The fold and conversion functions are named, not printed.** `qty`, `sum`, filters,
   `digits`, `sign` and `mod` are defined once, in this page, rather than per file.
   `sheaf sequents` could print them as a fixed preamble for the Lean export.
4. **Claims are checked by the prover, not by a separate checker.** Evaluating claims on
   data catches a wrong proof only on the data at hand. pt-1 (proofs as `Proof` texts)
   and a small proof checker give the independent check.
