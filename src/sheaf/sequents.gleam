//// A file's theory as geometric sequents (docs/geometric.md).
////
//// One block per declaration. 'N(t) ⊣⊢ φ' defines the type N: both
//// 'N(t) ⊢ φ' and 'φ ⊢ N(t)'. 'N(t) ⊢ t.f = e' defines a computed field as
//// a total function. A mapping gives one sequent per case. A claim is a
//// sequent the checker proved, marked [claim]. Only = ∧ ∨ ∃ ⊢ appear, with
//// ≤ < ≥ > on numbers (decidable, so their complements are positive too).
////
//// Paths are kept as written, after the text they start from: 't.lines.qty'.
//// A path that starts with a type name starts from the nearest record of
//// that type around t: 'around(t, Order).customer'. '.qty', '.sum' and type
//// filters are the folds of docs/geometric.md, defined by recursion on lists.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sheaf/evaluate
import sheaf/model.{
  type Block, type Clause, type Decl, type Field, type Item, type Num,
  type Value, Flag, NumItem, OrConn, Plain, Setting, StrItem, TypeItem, VArith,
  VMulti, VNum, VPath, VRange, VStr,
}
import sheaf/program.{type Program}

/// The theory of one file: its declarations, in order, as sequents.
pub fn file(p: Program, path: String) -> String {
  program.ordered(p)
  |> list.filter(fn(d) { d.file == path })
  |> list.map(fn(d) { decl(p, d) |> string.join("\n") })
  |> string.join("\n\n")
}

/// The sequents of one declaration, with a heading comment.
pub fn decl(p: Program, d: Decl) -> List(String) {
  let head =
    "# "
    <> d.name
    <> "  ("
    <> model.kind_text(d.kind)
    <> ", line "
    <> int.to_string(d.line)
    <> ")"
  let me = d.name <> "(t)"
  let body = case d.kind {
    model.Union -> [
      define(me, [
        list.map(d.items, fn(i) { item(i, "t") }) |> string.join(" ∨ "),
      ]),
    ]
    model.Intersection -> [
      define(me, list.map(d.items, fn(i) { item(i, "t") })),
    ]
    model.Refine -> [
      define(me, [box(d.items, d.preds, "t"), ..block_parts(d.preds, "t")]),
    ]
    model.Layout -> layout(p, d, me)
    model.Record -> record(d, me)
  }
  [head, ..body]
}

// ---------------------------------------------------------------- shapes

fn layout(p: Program, d: Decl, me: String) -> List(String) {
  let vars = list.map(d.positions, fn(pos) { "p" <> int.to_string(pos.number) })
  let parts =
    list.map(d.positions, fn(pos) {
      let v = "p" <> int.to_string(pos.number)
      [box(pos.items, pos.preds, v), ..block_parts(pos.preds, v)]
      |> join_and
    })
  let numeric = evaluate.is_numeric(p.ev, d.name)
  let self = case numeric {
    True -> "t.val"
    False -> "t"
  }
  let def =
    define(me, [
      exists(vars, "t = " <> string.join(vars, " ⧺ ")),
      ..list.append(parts, block_parts(d.preds, self))
    ])
  case numeric {
    False -> [def]
    True -> {
      let digits =
        d.positions
        |> list.filter(fn(pos) { pos.items == [TypeItem("Digit")] })
        |> list.map(fn(pos) { "p" <> int.to_string(pos.number) })
      let sign =
        d.positions
        |> list.find(fn(pos) { pos.items == [StrItem("-")] })
      let number = "digits(" <> string.join(digits, " ⧺ ") <> ")"
      let value = case sign {
        Ok(pos) -> "sign(p" <> int.to_string(pos.number) <> ") * " <> number
        Error(_) -> number
      }
      [def, me <> " ⊢ t.val = " <> value]
    }
  }
}

fn record(d: Decl, me: String) -> List(String) {
  let stored = list.filter(d.fields, model.is_stored)
  let names = list.map(stored, fn(f) { f.name })
  let shape = case names {
    [] -> "t = \"\""
    _ -> exists(names, "t = " <> string.join(names, " ⧺ "))
  }
  let stored_parts =
    list.map(stored, fn(f) {
      [box(f.items, f.preds, f.name), ..block_parts(f.preds, f.name)]
      |> join_and
    })
  let rule_parts =
    d.fields
    |> list.flat_map(fn(f) {
      case f.role {
        model.Rule -> [paren_or(f.preds, "t")]
        model.Computed ->
          model.constraints(f)
          |> list.map(fn(c) { clause(c, "t." <> f.name) })
          |> list.filter(fn(s) { s != "" })
        _ -> []
      }
    })
  let def = define(me, [shape, ..list.append(stored_parts, rule_parts)])
  let rest =
    list.flat_map(d.fields, fn(f) {
      case f.role {
        model.Computed -> [computed(f, me)]
        model.MappingRole -> mapping(f, me)
        model.Claim -> [me <> " ⊢ " <> paren_or(f.preds, "t") <> "    [claim]"]
        _ -> []
      }
    })
  let uniques =
    stored
    |> list.filter(fn(f) { model.has_flag(f.preds, "unique") })
    |> list.map(fn(f) {
      me
      <> " ∧ "
      <> d.name
      <> "(u) ∧ rows_of_one_list(t, u) ∧ t."
      <> f.name
      <> " = u."
      <> f.name
      <> " ⊢ t = u"
    })
  [def, ..list.append(rest, uniques)]
}

fn computed(f: Field, me: String) -> String {
  let assert Some(def) = model.definition(f)
  let e = value(def, "t")
  let e = case model.setting(f.preds, "mod") {
    Some(m) -> paren(e) <> " mod " <> value(m, "t")
    None -> e
  }
  me <> " ⊢ t." <> f.name <> " = " <> e
}

fn mapping(f: Field, me: String) -> List(String) {
  let assert Some(m) = f.mapping
  list.map(m.cases, fn(c) {
    me
    <> " ∧ "
    <> paren_or(c.preds, "t")
    <> " ⊢ t."
    <> f.name
    <> " = "
    <> output(c.output)
  })
}

// ---------------------------------------------------------------- formulas

fn define(head: String, parts: List(String)) -> String {
  let parts = list.filter(parts, fn(s) { s != "" })
  let one = head <> " ⊣⊢ " <> string.join(parts, " ∧ ")
  case string.length(one) <= 100 {
    True -> one
    False ->
      case parts {
        [first, ..rest] ->
          [head <> " ⊣⊢ " <> first, ..list.map(rest, fn(s) { "    ∧ " <> s })]
          |> string.join("\n")
        [] -> head <> " ⊣⊢ TRUE"
      }
  }
}

fn exists(vars: List(String), body: String) -> String {
  "∃ " <> string.join(vars, " ") <> ". " <> body
}

fn join_and(parts: List(String)) -> String {
  parts |> list.filter(fn(s) { s != "" }) |> string.join(" ∧ ")
}

fn paren(s: String) -> String {
  case string.contains(s, " ") {
    True -> "(" <> s <> ")"
    False -> s
  }
}

/// A block as one formula: its clauses joined by ∧ or ∨, in parentheses
/// when they are a disjunction.
fn paren_or(b: Block, self: String) -> String {
  let parts = block_parts(b, self)
  case b.conn, parts {
    OrConn, [_, _, ..] -> "(" <> string.join(parts, " ∨ ") <> ")"
    _, _ -> join_and(parts)
  }
}

/// The clauses of a block that are formulas: counts are shown on the box,
/// cost and print are promises about checking, not formulas.
fn block_parts(b: Block, self: String) -> List(String) {
  let parts =
    b.clauses
    |> list.map(fn(c) { clause(c, self) })
    |> list.filter(fn(s) { s != "" })
  case b.conn, parts {
    OrConn, [_, _, ..] -> ["(" <> string.join(parts, " ∨ ") <> ")"]
    _, _ -> parts
  }
}

/// 'self' is what 'val' stands for on this line.
fn clause(c: Clause, self: String) -> String {
  case c {
    Plain(path, op, v) -> compare(path_term(path, self), op, v, self)
    Setting("places", v) -> "places(" <> self <> ") ≤ " <> value(v, self)
    // the count goes on the box; mod on the definition; cost and print say
    // how checking and printing go, so they are not formulas (META)
    Setting(_, _) -> ""
    // unique is a sequent of its own, between two rows (see record)
    Flag(_) -> ""
  }
}

fn compare(left: String, op: String, v: Value, self: String) -> String {
  case v, op {
    VRange(lo, hi), "=" -> range(left, lo, hi)
    VMulti(vs), "=" ->
      "("
      <> list.map(vs, fn(x) { compare(left, "=", x, self) })
      |> string.join(" ∨ ")
      <> ")"
    _, _ -> left <> " " <> symbol(op) <> " " <> value(v, self)
  }
}

fn range(x: String, lo: Option(Num), hi: Option(Num)) -> String {
  case lo, hi {
    Some(l), Some(h) -> l.text <> " ≤ " <> x <> " ∧ " <> x <> " ≤ " <> h.text
    Some(l), None -> x <> " ≥ " <> l.text
    None, Some(h) -> x <> " ≤ " <> h.text
    None, None -> "TRUE"
  }
}

fn symbol(op: String) -> String {
  case op {
    "<=" -> "≤"
    ">=" -> "≥"
    o -> o
  }
}

fn value(v: Value, self: String) -> String {
  case v {
    VArith(op, terms) ->
      list.map(terms, fn(x) { value(x, self) }) |> string.join(" " <> op <> " ")
    VNum(n) -> n.text
    VStr(s) -> model.quote(s)
    VPath(parts) -> path_term(parts, self)
    VRange(lo, hi) -> range("_", lo, hi)
    VMulti(vs) -> list.map(vs, fn(x) { value(x, self) }) |> string.join(" | ")
  }
}

/// 'val' is the line's own value; a field path starts from t; a path that
/// starts with a type name starts from the record of that type around t,
/// or, with nothing after it, is that type's one value (True).
fn path_term(parts: List(String), self: String) -> String {
  case parts {
    ["val", ..rest] -> string.join([self, ..rest], ".")
    ["True"] -> "TRUE"
    ["False"] -> "FALSE"
    [head, ..rest] ->
      case is_type(head) {
        True -> string.join(["around(t, " <> head <> ")", ..rest], ".")
        False -> string.join(["t", head, ..rest], ".")
      }
    [] -> self
  }
}

fn is_type(s: String) -> Bool {
  case string.first(s) {
    Ok(ch) -> string.uppercase(ch) == ch && string.lowercase(ch) != ch
    Error(_) -> False
  }
}

/// The base of a line, applied to x: 'T(x)', 'x = "a"', or with a count
/// 'T{1..}(x)', a list of that many texts of T, one after another.
fn box(items: List(Item), b: Block, x: String) -> String {
  let count = case model.setting(b, "qty") {
    Some(v) -> Some(model.value_text(v))
    None -> None
  }
  case items, count {
    [one], None -> item(one, x)
    [one], Some(n) -> model.item_text(one) <> "{" <> n <> "}(" <> x <> ")"
    many, _ ->
      "(" <> list.map(many, fn(i) { item(i, x) }) |> string.join(" ∨ ") <> ")"
  }
}

fn item(i: Item, x: String) -> String {
  case i {
    TypeItem(n) -> n <> "(" <> x <> ")"
    StrItem(s) -> x <> " = " <> model.quote(s)
    NumItem(_, t) -> x <> " = " <> t
  }
}

fn output(i: Item) -> String {
  case i {
    TypeItem("True") -> "TRUE"
    TypeItem("False") -> "FALSE"
    TypeItem(n) -> n
    StrItem(s) -> model.quote(s)
    NumItem(_, t) -> t
  }
}
