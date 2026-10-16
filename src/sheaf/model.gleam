//// The declarations of a language.sheaf program. Every type here is one line
//// form of language.sheaf (Steps 5-7): unions, refinements, layouts, records,
//// fields, mappings and cases.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sheaf/decimal.{type Decimal}

pub const folds = ["qty", "sum"]

pub const reserved = ["qty", "sum", "val", "places", "mod", "cost", "print"]

pub const builtin_numeric = ["Integer", "Decimal"]

pub const literal_numeric = [
  "Integer_Literal",
  "Decimal_Literal",
  "Number_Literal",
]

pub type MapError {
  MapError(msg: String, file: String, line: Int, col: Int)
}

pub fn error_text(e: MapError) -> String {
  case e.line {
    0 ->
      case e.file {
        "" -> e.msg
        f -> f <> ": " <> e.msg
      }
    l ->
      e.file
      <> ":"
      <> string.inspect(l)
      <> ":"
      <> string.inspect(e.col)
      <> ": "
      <> e.msg
  }
}

// ---------------------------------------------------------------- items and values

/// A Union_Item: a type name, a string literal or a number literal.
pub type Item {
  TypeItem(name: String)
  StrItem(text: String)
  NumItem(value: Decimal, text: String)
}

pub type Num {
  Num(value: Decimal, text: String)
}

pub type Value {
  VArith(op: String, terms: List(Value))
  VRange(low: Option(Num), high: Option(Num))
  VNum(num: Num)
  VStr(text: String)
  VPath(parts: List(String))
  VMulti(values: List(Value))
}

pub type Clause {
  Plain(path: List(String), op: String, value: Value)
  Setting(key: String, value: Value)
  Flag(name: String)
}

pub type Conn {
  AndConn
  OrConn
}

pub type Block {
  Block(conn: Conn, clauses: List(Clause))
}

pub const empty = Block(AndConn, [])

pub type Case {
  Case(output: Item, preds: Block, line: Int)
}

pub type Mapping {
  Mapping(inputs: List(String), outputs: List(Item), cases: List(Case))
}

pub type Role {
  Stored
  Rule
  Constant
  Claim
  Computed
  MappingRole
}

pub type Field {
  Field(
    name: String,
    items: List(Item),
    preds: Block,
    mapping: Option(Mapping),
    line: Int,
    comment: String,
    role: Role,
  )
}

pub type Position {
  Position(number: Int, items: List(Item), preds: Block, line: Int)
}

pub type Kind {
  Union
  Refine
  Layout
  Record
  /// 'Name {A & B}': texts that inhabit every listed type over the same span.
  /// Values and fields come from the first type; the others only constrain.
  Intersection
}

pub type Decl {
  Decl(
    name: String,
    kind: Kind,
    line: Int,
    file: String,
    items: List(Item),
    preds: Block,
    positions: List(Position),
    fields: List(Field),
    comment: String,
    doc: String,
  )
}

/// What a file contains, in order: its declarations.
pub type Entry {
  DeclEntry(decl: Decl)
}

// ---------------------------------------------------------------- printing

pub fn item_text(i: Item) -> String {
  case i {
    TypeItem(n) -> n
    StrItem(s) -> quote(s)
    NumItem(_, t) -> t
  }
}

pub fn quote(s: String) -> String {
  "\""
  <> s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  <> "\""
}

pub fn value_text(v: Value) -> String {
  case v {
    VArith(op, terms) ->
      list.map(terms, value_text) |> string.join(" " <> op <> " ")
    VRange(lo, hi) -> opt_num(lo) <> ".." <> opt_num(hi)
    VNum(n) -> n.text
    VStr(s) -> quote(s)
    VPath(parts) -> string.join(parts, ".")
    VMulti(vs) -> list.map(vs, value_text) |> string.join(" | ")
  }
}

fn opt_num(n: Option(Num)) -> String {
  case n {
    Some(x) -> x.text
    None -> ""
  }
}

pub fn clause_text(c: Clause) -> String {
  case c {
    Plain(p, op, v) -> string.join(p, ".") <> " " <> op <> " " <> value_text(v)
    Setting("qty", v) -> "count " <> value_text(v)
    Setting("cost", v) -> "cost <= " <> value_text(v)
    Setting(k, v) -> k <> " = " <> value_text(v)
    Flag(n) -> n
  }
}

/// Predicates as written: the count of a list is shown in its braces instead
/// (see box_text).
pub fn block_text(b: Block) -> String {
  let sep = case b.conn {
    AndConn -> " & "
    OrConn -> " | "
  }
  b.clauses
  |> list.filter(fn(c) {
    case c {
      Setting("qty", _) -> False
      _ -> True
    }
  })
  |> list.map(clause_text)
  |> string.join(sep)
}

/// A base in braces with its count, as written: {Digit 2}, {Line 1..}.
pub fn box_text(items: List(Item), b: Block) -> String {
  let inner = list.map(items, item_text) |> string.join(" | ")
  case setting(b, "qty") {
    Some(v) -> "{" <> inner <> " " <> value_text(v) <> "}"
    None -> "{" <> inner <> "}"
  }
}

pub fn mapping_text(m: Mapping) -> String {
  string.join(m.inputs, " & ")
  <> " -> "
  <> { list.map(m.outputs, item_text) |> string.join(" | ") }
}

pub fn kind_text(k: Kind) -> String {
  case k {
    Union -> "union"
    Refine -> "refine"
    Layout -> "layout"
    Record -> "record"
    Intersection -> "intersection"
  }
}

pub fn role_text(r: Role) -> String {
  case r {
    Stored -> "stored"
    Rule -> "rule"
    Constant -> "constant"
    Claim -> "claim"
    Computed -> "computed"
    MappingRole -> "mapping"
  }
}

// ---------------------------------------------------------------- block helpers

pub fn settings(b: Block) -> List(#(String, Value)) {
  list.filter_map(b.clauses, fn(c) {
    case c {
      Setting(k, v) -> Ok(#(k, v))
      _ -> Error(Nil)
    }
  })
}

pub fn setting(b: Block, key: String) -> Option(Value) {
  case list.key_find(settings(b), key) {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

pub fn has_flag(b: Block, name: String) -> Bool {
  list.any(b.clauses, fn(c) { c == Flag(name) })
}

pub fn plains(b: Block) -> List(Clause) {
  list.filter(b.clauses, fn(c) {
    case c {
      Plain(..) -> True
      _ -> False
    }
  })
}

// ---------------------------------------------------------------- field helpers

pub fn base(f: Field) -> Item {
  let assert [first, ..] = f.items
  first
}

pub fn decl_base(d: Decl) -> Item {
  let assert [first, ..] = d.items
  first
}

/// A list's count as a range: {Digit 2} is 2..2. Kept as the 'qty' setting.
pub fn qty(f: Field) -> Option(#(Option(Num), Option(Num))) {
  qty_of(f.preds)
}

pub fn qty_of(b: Block) -> Option(#(Option(Num), Option(Num))) {
  case setting(b, "qty") {
    Some(VNum(n)) -> Some(#(Some(n), Some(n)))
    Some(VRange(lo, hi)) -> Some(#(lo, hi))
    _ -> None
  }
}

/// The value of a 'val =' predicate that defines the field, if any.
pub fn definition(f: Field) -> Option(Value) {
  list.find_map(f.preds.clauses, fn(c) {
    case c {
      Plain(["val"], "=", v) ->
        case v {
          VRange(..) | VMulti(..) -> Error(Nil)
          _ -> Ok(v)
        }
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// The plain predicates that constrain the field (all but its definition).
pub fn constraints(f: Field) -> List(Clause) {
  let def = definition(f)
  let #(_, out) =
    list.fold(plains(f.preds), #(False, []), fn(acc, c) {
      let #(skipped, out) = acc
      case c, def, skipped {
        Plain(["val"], "=", v), Some(dv), False if v == dv -> #(True, out)
        _, _, _ -> #(skipped, [c, ..out])
      }
    })
  list.reverse(out)
}

/// Stored fields contribute text; the others are computed (Step 3).
pub fn classify(f: Field) -> Role {
  case f.mapping {
    Some(_) -> MappingRole
    None -> {
      let ps = plains(f.preds)
      case f.items, ps, settings(f.preds) {
        [TypeItem("True")], [], _ -> Constant
        [TypeItem("True")], _, _ -> Rule
        [TypeItem("Fact")], [Plain(path, _, _)], [] if path != ["val"] -> Claim
        _, _, _ ->
          case definition(f) {
            Some(_) -> Computed
            None -> Stored
          }
      }
    }
  }
}

pub fn field(d: Decl, name: String) -> Option(Field) {
  list.find(d.fields, fn(f) { f.name == name }) |> option.from_result
}

pub fn is_stored(f: Field) -> Bool {
  f.role == Stored
}

// ---------------------------------------------------------------- references

/// The type names a declaration uses: its items, its fields' types, mapping
/// outputs, and type names in predicates (constants like True, and filters).
fn value_paths(v: Value) -> List(String) {
  case v {
    VPath(ps) -> ps
    VArith(_, ts) | VMulti(ts) -> list.flat_map(ts, value_paths)
    _ -> []
  }
}

pub fn references(d: Decl) -> List(String) {
  let from_items = fn(its: List(Item)) {
    list.filter_map(its, fn(i) {
      case i {
        TypeItem(n) -> Ok(n)
        _ -> Error(Nil)
      }
    })
  }
  let upper = fn(parts: List(String)) {
    list.filter(parts, fn(x) {
      case string.first(x) {
        Ok(c) -> string.uppercase(c) == c && string.lowercase(c) != c
        Error(_) -> False
      }
    })
  }
  let value_refs = fn(v) {
    list.filter(value_paths(v), fn(x) { upper([x]) != [] })
  }
  let block_refs = fn(b: Block) {
    list.flat_map(b.clauses, fn(c) {
      case c {
        Plain(path, _, v) -> list.append(upper(path), value_refs(v))
        Setting(_, v) -> value_refs(v)
        Flag(_) -> []
      }
    })
  }
  list.flatten([
    from_items(d.items),
    block_refs(d.preds),
    list.flat_map(d.positions, fn(p) {
      list.append(from_items(p.items), block_refs(p.preds))
    }),
    list.flat_map(d.fields, fn(f) {
      let m = case f.mapping {
        Some(mp) ->
          list.append(
            from_items(mp.outputs),
            list.flat_map(mp.cases, fn(c) {
              list.append(from_items([c.output]), block_refs(c.preds))
            }),
          )
        None -> []
      }
      list.flatten([from_items(f.items), block_refs(f.preds), m])
    }),
  ])
  |> list.unique
}

/// The places a field holds: its own 'places = n', or else the first one on
/// a refinement line up its type chain, as in 'Money {Decimal} places = 2'.
pub fn field_places(decls: Dict(String, Decl), f: Field) -> Option(Value) {
  case setting(f.preds, "places") {
    Some(v) -> Some(v)
    None ->
      case f.items {
        [TypeItem(t)] -> type_places(decls, t, [])
        _ -> None
      }
  }
}

pub fn type_places(
  decls: Dict(String, Decl),
  name: String,
  seen: List(String),
) -> Option(Value) {
  case list.contains(seen, name), dict.get(decls, name) {
    False, Ok(d) ->
      case d.kind, setting(d.preds, "places") {
        Refine, Some(v) | Layout, Some(v) -> Some(v)
        Refine, None | Intersection, None ->
          case d.items {
            [TypeItem(b), ..] -> type_places(decls, b, [name, ..seen])
            _ -> None
          }
        _, _ -> None
      }
    _, _ -> None
  }
}

/// Items as written in braces: Digit, "a" | "b".
pub fn items_text(items: List(Item)) -> String {
  list.map(items, item_text) |> string.join(" | ")
}
