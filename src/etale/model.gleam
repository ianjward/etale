//// The declarations of a language.etale program. Every type here is one line
//// form of language.etale (Steps 5-7): unions, refinements, layouts, records,
//// fields, mappings and cases.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import etale/decimal.{type Decimal}

pub const folds = ["qty", "sum", "min", "max"]

/// Names no field may take (the header of language.etale). Inside the model the
/// line's own value is the path 'val', and folds end a path in qty or sum.
pub const reserved = ["value", "text", "count", "sum", "min", "max"]

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
  /// A fold over only the items that meet a condition: 'count: stops, filter:
  /// stops.delay >= 2'. 'path' is the fold's path ([stops, "qty"] or
  /// [lines, amount, "sum"]); 'conditions' name fields of the list's items
  /// (delay), not of this record.
  VFilter(path: List(String), conditions: Block)
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
    /// A record's kept and collected lists ('late_stops {Stop...} (stops.delay
    /// >= 2)'): lines of the record that the model holds as folds, not fields.
    worked: List(String),
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
    VPath(parts) -> path_text(parts)
    VMulti(vs) -> list.map(vs, value_text) |> string.join(" | ")
    VFilter(path, conditions) -> {
      let assert [list_name, ..] = path
      path_text(path)
      <> " [only items with "
      <> through_list(list_name, conditions)
      <> "]"
    }
  }
}

/// A path as the language writes it: the model's own names 'qty' and 'val'
/// read as the method '.count' and the line's value. Neither can name a
/// field, so nothing else is renamed.
pub fn path_text(parts: List(String)) -> String {
  list.map(parts, fn(x) {
    case x {
      "qty" -> "count"
      "val" -> "value"
      other -> other
    }
  })
  |> string.join(".")
}

/// '=' with a range or a choice reads as 'in', as the language writes it.
fn op_text(op: String, v: Value) -> String {
  case op, v {
    "=", VRange(..) | "=", VMulti(..) -> "in"
    _, _ -> op
  }
}

/// A filter's conditions as written: each item field through its list.
pub fn through_list(list_name: String, b: Block) -> String {
  let sep = case b.conn {
    AndConn -> " & "
    OrConn -> " | "
  }
  b.clauses
  |> list.map(fn(c) {
    case c {
      Plain(p, op, v) ->
        list_name
        <> "."
        <> path_text(p)
        <> " "
        <> op_text(op, v)
        <> " "
        <> value_text(v)
      other -> clause_text(other)
    }
  })
  |> string.join(sep)
}

fn opt_num(n: Option(Num)) -> String {
  case n {
    Some(x) -> x.text
    None -> ""
  }
}

pub fn clause_text(c: Clause) -> String {
  case c {
    Plain(p, op, v) -> path_text(p) <> " " <> op_text(op, v) <> " " <> value_text(v)
    Setting("qty", v) -> "count: " <> value_text(v)
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

/// A base in braces with its count, as written: {Digit...} count: 2,
/// {Line...} count: 1.., {Stop...}, {Journey} count: 0..1.
pub fn box_text(items: List(Item), b: Block) -> String {
  let inner = list.map(items, item_text) |> string.join(" | ")
  case setting(b, "qty") {
    Some(VRange(Some(lo), None) as v) ->
      case decimal.is_zero(lo.value) {
        True -> "{" <> inner <> "...}"
        False -> "{" <> inner <> "...} count: " <> value_text(v)
      }
    Some(VRange(Some(lo), Some(hi)) as v) ->
      case
        decimal.is_zero(lo.value) && decimal.eq(hi.value, decimal.from_int(1))
      {
        True -> "{" <> inner <> "} count: 0..1"
        False -> "{" <> inner <> "...} count: " <> value_text(v)
      }
    Some(v) -> "{" <> inner <> "...} count: " <> value_text(v)
    None -> "{" <> inner <> "}"
  }
}

/// A mapping's head as written after its name: '{Out} (a, b)'.
pub fn mapping_text(m: Mapping) -> String {
  "{"
  <> { list.map(m.outputs, item_text) |> string.join(" | ") }
  <> "} ("
  <> string.join(m.inputs, ", ")
  <> ")"
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

/// A field that holds more than one item: a list.
pub fn is_list_field(f: Field) -> Bool {
  case qty(f) {
    Some(#(_, None)) -> True
    Some(#(_, Some(h))) -> decimal.lt(decimal.from_int(1), h.value)
    None -> False
  }
}

/// A relation between two lists of a record: 'orders.customer =
/// customers.code', each side a field of the items of a list of the record.
pub type Relation {
  Relation(
    left_list: Field,
    left_field: String,
    right_list: Field,
    right_field: String,
    op: String,
  )
}

pub fn relation_of(d: Decl, cl: Clause) -> Option(Relation) {
  case cl {
    Plain([l1, f1], op, VPath([l2, f2])) ->
      case field(d, l1), field(d, l2) {
        Some(a), Some(b) ->
          case is_list_field(a) && is_list_field(b) {
            True -> Some(Relation(a, f1, b, f2, op))
            False -> None
          }
        _, _ -> None
      }
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
          // a range whose ends name constants, before the file is settled
          VArith(op, _) ->
            case string.starts_with(op, "..") {
              True -> Error(Nil)
              False -> Ok(v)
            }
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
        [TypeItem("Needs")], [], _ -> Constant
        [TypeItem("Needs")], _, _ -> Rule
        [TypeItem("Claims")], [Plain(path, _, _)], [] if path != ["val"] -> Claim
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

/// The record whose values a type holds: the record itself, or the record
/// under a refinement (a filter) or under an intersection's first type. So a
/// field typed 'Small', with 'Small {Mul} out <= 5', has Mul's fields.
pub fn record_of(decls: Dict(String, Decl), name: String) -> Option(Decl) {
  record_of_loop(decls, name, [])
}

fn record_of_loop(
  decls: Dict(String, Decl),
  name: String,
  seen: List(String),
) -> Option(Decl) {
  case list.contains(seen, name), dict.get(decls, name) {
    False, Ok(d) ->
      case d.kind, d.items {
        Record, _ -> Some(d)
        Refine, [TypeItem(b)] | Intersection, [TypeItem(b), ..] ->
          record_of_loop(decls, b, [name, ..seen])
        _, _ -> None
      }
    _, _ -> None
  }
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
