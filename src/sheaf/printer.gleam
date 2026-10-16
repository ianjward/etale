//// Printing: parsing run backwards (language.sheaf, Step 9).
////
//// print(type, value) builds the canonical text for a value, then parses it
//// back and refuses to return it unless it reads back to that same value in
//// exactly one way. format(file) prints a file from its own parse tree, with
//// every sequence that declares print= reset to that many items.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sheaf/decimal.{type Decimal}
import sheaf/evaluate.{type Val, VNumber, VRecord, VSeqv, VText}
import sheaf/grammar
import sheaf/model.{
  type Decl, type Field, type Item, NumItem, StrItem, TypeItem, VNum,
}
import sheaf/node.{type Node, NAlt, NChar, NLay, NLit, NRec, NSeq}
import sheaf/program.{type Program}
import sheaf/reader

/// A value to print: numbers, texts, records by field name, sequences.
pub type PV {
  PNum(Decimal)
  PText(String)
  PRec(List(#(String, PV)))
  PList(List(PV))
}

@external(javascript, "./printer_ffi.mjs", "parse_json")
pub fn parse_json(text: String) -> Result(PV, String)

@external(javascript, "./ffi.mjs", "slice")
fn slice(s: String, a: Int, b: Int) -> String

pub fn pv_text(v: PV) -> String {
  case v {
    PNum(d) -> decimal.to_short(d)
    PText(t) -> model.quote(t)
    PRec(kvs) ->
      "{"
      <> list.map(kvs, fn(kv) { kv.0 <> ": " <> pv_text(kv.1) })
      |> string.join(", ")
      <> "}"
    PList(xs) -> "[" <> list.map(xs, pv_text) |> string.join(", ") <> "]"
  }
}

// ---------------------------------------------------------------- printing

/// The one canonical text of `type_name` that reads back to `v`.
pub fn print(p: Program, type_name: String, v: PV) -> Result(String, String) {
  use text <- result.try(print_type(p, type_name, v, type_name))
  let out = program.check(p, type_name, text)
  case out.ok, out.value {
    True, Some(val) ->
      case matches(p, val, v) {
        True -> Ok(text)
        False ->
          Error(
            "printing is not unique here: "
            <> string.inspect(text)
            <> " reads back as "
            <> evaluate.show(val)
            <> ", not "
            <> pv_text(v),
          )
      }
    _, _ ->
      Error(
        "the printed text "
        <> string.inspect(text)
        <> " does not inhabit "
        <> type_name
        <> case out.error, out.failures {
          "", [] -> ""
          "", fs -> ": " <> string.join(fs, "; ")
          e, [] -> ": " <> e
          e, fs -> ": " <> e <> " (" <> string.join(fs, "; ") <> ")"
        },
      )
  }
}

fn decl(p: Program, name: String) -> Option(Decl) {
  option.from_result(dict.get(p.decls, name))
}

fn raw(v: PV) -> Option(String) {
  case v {
    PText(t) -> Some(t)
    PNum(d) -> Some(decimal.to_string(d))
    _ -> None
  }
}

fn need(o: Option(a), msg: String) -> Result(a, String) {
  option.to_result(o, msg)
}

fn print_item(
  p: Program,
  it: Item,
  v: PV,
  at: String,
) -> Result(String, String) {
  case it {
    StrItem(s) ->
      case raw(v) == Some(s) {
        True -> Ok(s)
        False -> Error(at <> ": " <> pv_text(v) <> " is not " <> model.quote(s))
      }
    NumItem(d, t) ->
      case v {
        PNum(x) ->
          case decimal.eq(x, d) {
            True -> Ok(t)
            False -> Error(at <> ": " <> pv_text(v) <> " is not " <> t)
          }
        _ ->
          case raw(v) == Some(t) {
            True -> Ok(t)
            False -> Error(at <> ": " <> pv_text(v) <> " is not " <> t)
          }
      }
    TypeItem(n) -> print_type(p, n, v, at)
  }
}

fn print_type(
  p: Program,
  name: String,
  v: PV,
  at: String,
) -> Result(String, String) {
  case name, v {
    "Integer", PNum(d) ->
      case decimal.is_integral(d) {
        True -> Ok(decimal.to_string(decimal.floor(d)))
        False -> Error(at <> ": " <> pv_text(v) <> " is not an integer")
      }
    "Decimal", PNum(d) -> Ok(decimal.to_string(d))
    "Integer", _ | "Decimal", _ ->
      need(raw(v), at <> ": " <> pv_text(v) <> " is not a number")
    _, _ ->
      case decl(p, name) {
        None -> Error(at <> ": unknown type " <> name)
        Some(d) -> print_decl(p, d, v, at)
      }
  }
}

fn print_decl(
  p: Program,
  d: Decl,
  v: PV,
  at: String,
) -> Result(String, String) {
  case d.kind {
    model.Union -> first_ok(p, d.items, v, at, d.name)
    model.Intersection -> print_item(p, model.decl_base(d), v, at)
    model.Refine ->
      case model.qty_of(d.preds) {
        Some(_) -> {
          let #(lo, hi) = grammar.qty_bounds(model.qty_of(d.preds))
          print_seq(p, model.decl_base(d), lo, hi, v, at)
        }
        None -> print_item(p, model.decl_base(d), v, at)
      }
    model.Layout ->
      case model.decl_base(d), v {
        TypeItem(b), PNum(x) ->
          case list.contains(model.builtin_numeric, b) {
            True -> print_conversion(d, x, at)
            False -> need(raw(v), at)
          }
        _, _ -> need(raw(v), at <> ": " <> d.name <> " prints from its text")
      }
    model.Record ->
      case v {
        PRec(kvs) -> print_record(p, d, kvs, at)
        _ ->
          need(raw(v), at <> ": " <> d.name <> " is a record; give its fields")
      }
  }
}

fn first_ok(
  p: Program,
  items: List(Item),
  v: PV,
  at: String,
  name: String,
) -> Result(String, String) {
  case items {
    [] -> Error(at <> ": no item of " <> name <> " prints " <> pv_text(v))
    [it, ..rest] ->
      case print_item(p, it, v, at) {
        Ok(t) -> Ok(t)
        Error(_) -> first_ok(p, rest, v, at, name)
      }
  }
}

fn print_seq(
  p: Program,
  elem: Item,
  lo: Int,
  hi: Option(Int),
  v: PV,
  at: String,
) -> Result(String, String) {
  case v {
    PList(xs) -> {
      let n = list.length(xs)
      let fits =
        n >= lo
        && case hi {
          Some(h) -> n <= h
          None -> True
        }
      case fits {
        False ->
          Error(at <> ": " <> int.to_string(n) <> " items do not fit the qty")
        True ->
          list.index_map(xs, fn(x, i) {
            print_item(p, elem, x, at <> "[" <> int.to_string(i + 1) <> "]")
          })
          |> result.all
          |> result.map(string.concat)
      }
    }
    _ -> need(raw(v), at <> ": a sequence takes a list or a text")
  }
}

/// A conversion layout prints its value in its one digit position, padded with
/// leading zeros to the fewest digits that position allows.
fn print_conversion(d: Decl, x: Decimal, at: String) -> Result(String, String) {
  let digit_positions =
    list.filter(d.positions, fn(pos) {
      !list.all(pos.items, fn(i) {
        case i {
          StrItem(_) -> True
          _ -> False
        }
      })
    })
  let signed = list.any(d.positions, fn(p) { p.items == [StrItem("-")] })
  case
    digit_positions,
    decimal.is_integral(x),
    decimal.is_negative(x) && !signed
  {
    _, False, _ -> Error(at <> ": " <> decimal.to_short(x) <> " is not whole")
    _, _, True ->
      Error(
        at
        <> ": "
        <> d.name
        <> " has no \"-\" position, so it cannot print a negative",
      )
    [dp], True, False -> {
      let #(lo, hi) = grammar.qty_bounds(model.qty_of(dp.preds))
      let digits = decimal.abs_digits(x)
      let digits = string.pad_start(digits, lo, "0")
      let fits = case hi {
        Some(h) -> string.length(digits) <= h
        None -> True
      }
      case fits {
        False ->
          Error(
            at
            <> ": "
            <> decimal.to_short(x)
            <> " has too many digits for "
            <> d.name,
          )
        True ->
          list.map(d.positions, fn(pos) {
            case pos.number == dp.number, pos.items == [StrItem("-")] {
              True, _ -> Ok(digits)
              False, True ->
                case decimal.is_negative(x) {
                  True -> Ok("-")
                  False -> default_position(pos)
                }
              False, False -> default_position(pos)
            }
          })
          |> result.all
          |> result.map(string.concat)
          |> result.map_error(fn(_) { at <> ": " <> d.name })
      }
    }
    _, _, _ ->
      Error(
        at <> ": " <> d.name <> " has several digit positions; give its text",
      )
  }
}

fn default_position(pos: model.Position) -> Result(String, Nil) {
  let #(lo, _) = grammar.qty_bounds(model.qty_of(pos.preds))
  case pos.items {
    [StrItem(s)] -> Ok(string.repeat(s, lo))
    _ -> Error(Nil)
  }
}

fn print_record(
  p: Program,
  d: Decl,
  kvs: List(#(String, PV)),
  at: String,
) -> Result(String, String) {
  let unknown =
    list.filter(kvs, fn(kv) { option.is_none(model.field(d, kv.0)) })
  case unknown {
    [#(k, _), ..] ->
      Error(at <> ": " <> d.name <> " has no field '" <> k <> "'")
    [] ->
      list.filter(d.fields, model.is_stored)
      |> list.map(fn(f) {
        let here = at <> "." <> f.name
        case list.key_find(kvs, f.name) {
          Ok(fv) -> print_field(p, f, fv, here)
          Error(_) -> need(default_field(p, f), here <> ": a value is needed")
        }
      })
      |> result.all
      |> result.map(string.concat)
  }
}

fn print_field(
  p: Program,
  f: Field,
  v: PV,
  at: String,
) -> Result(String, String) {
  let v = case v, model.field_places(p.decls, f) {
    PNum(x), Some(VNum(n)) ->
      case decimal.with_places(x, decimal.to_int(n.value)) {
        Ok(y) -> Ok(PNum(y))
        Error(_) ->
          Error(
            at
            <> ": "
            <> decimal.to_short(x)
            <> " needs more than places = "
            <> n.text,
          )
      }
    _, _ -> Ok(v)
  }
  use v <- result.try(v)
  case model.qty(f), f.items {
    Some(_), [one] -> {
      let #(lo, hi) = grammar.qty_bounds(model.qty(f))
      print_seq(p, one, lo, hi, v, at)
    }
    _, items -> first_ok(p, items, v, at, f.name)
  }
}

// ---------------------------------------------------------------- defaults

/// The text of a part when the value says nothing about it: a literal, a type
/// with one inhabitant, or a sequence of its print count (or fewest items).
fn default_field(p: Program, f: Field) -> Option(String) {
  case model.qty(f), f.items {
    Some(_), [one] -> {
      let n = print_count(f.preds)
      default_item(p, one, [])
      |> option.map(fn(t) { string.repeat(t, n) })
    }
    None, [one] -> default_item(p, one, [])
    _, _ -> None
  }
}

fn print_count(preds: model.Block) -> Int {
  case model.setting(preds, "print") {
    Some(VNum(n)) -> decimal.to_int(n.value)
    _ -> grammar.qty_bounds(model.qty_of(preds)).0
  }
}

fn default_item(p: Program, it: Item, seen: List(String)) -> Option(String) {
  case it {
    StrItem(s) -> Some(s)
    NumItem(_, t) -> Some(t)
    TypeItem(n) ->
      case list.contains(seen, n), decl(p, n) {
        True, _ | _, None -> None
        False, Some(d) -> {
          let seen = [n, ..seen]
          case d.kind, d.items {
            model.Union, [one] -> default_item(p, one, seen)
            model.Refine, [one] ->
              case model.qty_of(d.preds) {
                Some(_) ->
                  default_item(p, one, seen)
                  |> option.map(fn(t) { string.repeat(t, print_count(d.preds)) })
                None ->
                  case model.plains(d.preds) {
                    [] -> default_item(p, one, seen)
                    _ -> None
                  }
              }
            model.Record, _ ->
              list.filter(d.fields, model.is_stored)
              |> list.map(fn(f) { default_field(p, f) })
              |> option.all
              |> option.map(string.concat)
            _, _ -> None
          }
        }
      }
  }
}

// ---------------------------------------------------------------- reading back

fn matches(p: Program, val: Val, v: PV) -> Bool {
  case val, v {
    VNumber(x), PNum(y) -> decimal.eq(x, y)
    VNumber(x), PText(t) ->
      case decimal.parse(t) {
        Ok(y) -> decimal.eq(x, y)
        Error(_) -> False
      }
    VText(x), PText(t) -> x == t
    VText(x), PNum(y) -> x == decimal.to_string(y)
    VText(_), PList(_) -> True
    VRecord(r), PRec(kvs) ->
      list.all(kvs, fn(kv) { matches(p, evaluate.get(p.ev, r, kv.0), kv.1) })
    VRecord(r), PText(t) -> slice(r.text, r.node.s, r.node.e) == t
    VSeqv(items, _, _), PList(xs) ->
      list.length(items) == list.length(xs)
      && list.all(list.zip(items, xs), fn(z) { matches(p, z.0, z.1) })
    VSeqv(_, _, _), PText(_) -> True
    _, _ -> False
  }
}

// ---------------------------------------------------------------- formatting

/// A file printed from its own parse: every sequence whose type declares
/// print= is reset to that many items; everything else keeps its text.
/// A file that omits its final newline keeps omitting it (the last-line rule).
pub fn format(
  p: Program,
  text: String,
  fname: String,
) -> Result(String, String) {
  let bare = text != "" && !string.ends_with(text, "\n")
  let text = reader.as_file_text(text)
  use entries <- result.try(
    reader.read(text, fname) |> result.map_error(model.error_text),
  )
  use tree <- result.try(
    program.verify_file(p, text, fname, entries)
    |> result.map_error(model.error_text),
  )
  let out = emit(p, tree, text)
  use entries2 <- result.try(
    reader.read(out, fname)
    |> result.map_error(fn(e) {
      "formatting would break the file: " <> model.error_text(e)
    }),
  )
  use _ <- result.try(
    program.verify_file(p, out, fname, entries2)
    |> result.map_error(fn(e) {
      "formatting would break the file: " <> model.error_text(e)
    }),
  )
  case entries2 == entries {
    True ->
      Ok(case bare {
        True -> string.drop_end(out, 1)
        False -> out
      })
    False -> Error("internal: formatting changed the meaning of the file")
  }
}

fn emit(p: Program, n: Node, text: String) -> String {
  let reset = case n.t {
    Some(name) ->
      case decl(p, name) {
        Some(d) ->
          case d.kind, model.setting(d.preds, "print"), model.qty_of(d.preds) {
            model.Refine, Some(VNum(c)), Some(_) ->
              default_item(p, model.decl_base(d), [])
              |> option.map(fn(t) { string.repeat(t, decimal.to_int(c.value)) })
            _, _, _ -> None
          }
        None -> None
      }
    None -> None
  }
  case reset {
    Some(t) -> t
    None ->
      case n.kind {
        NLit | NChar -> slice(text, n.s, n.e)
        NAlt(c) -> emit(p, c, text)
        NSeq(_) -> list.map(node.items(n), emit(p, _, text)) |> string.concat
        NRec(kids) | NLay(kids) ->
          list.map(kids, fn(k) { emit(p, k.1, text) }) |> string.concat
      }
  }
}

// ---------------------------------------------------------------- one rule

/// The value of a text, as something printable: numbers, texts, the stored
/// fields of records, and lists.
pub fn from_val(p: Program, v: Val) -> PV {
  case v {
    VNumber(d) -> PNum(d)
    VText(t) -> PText(t)
    VRecord(r) ->
      PRec(
        list.filter(r.decl.fields, model.is_stored)
        |> list.map(fn(f) {
          #(f.name, from_val(p, evaluate.get(p.ev, r, f.name)))
        }),
      )
    VSeqv(items, _, _) -> PList(list.map(items, from_val(p, _)))
    _ -> PText("")
  }
}

/// Data prints its values: read the text as the type, then print it back in
/// canonical form.
pub fn print_text(
  p: Program,
  type_name: String,
  text: String,
) -> Result(String, String) {
  let out = program.check(p, type_name, text)
  case out.ok, out.value {
    True, Some(v) -> print(p, type_name, from_val(p, v))
    _, _ ->
      Error(
        "the text does not inhabit "
        <> type_name
        <> case out.error {
          "" -> ""
          e -> ": " <> e
        },
      )
  }
}

/// A type prints its code: its declaration in canonical form, with the
/// comment lines directly above it. `source` reads the file it is in.
pub fn print_code(
  p: Program,
  type_name: String,
  source: fn(String) -> Result(String, Nil),
) -> Result(String, String) {
  case dict.get(p.decls, type_name) {
    Error(_) ->
      case list.contains(model.builtin_numeric, type_name) {
        True -> Error(type_name <> " is built in; it has no code to print")
        False -> Error("unknown type '" <> type_name <> "'")
      }
    Ok(d) ->
      case source(d.file) {
        Error(_) -> Error("cannot read " <> d.file)
        Ok(text) -> {
          use formatted <- result.try(format(p, text, d.file))
          use entries <- result.try(
            reader.read(formatted, d.file) |> result.map_error(model.error_text),
          )
          let starts =
            reader.decls(entries)
            |> list.map(fn(x) { #(x.name, x.line) })
          let lines = string.split(reader.as_file_text(formatted), "\n")
          let assert Ok(start) = list.key_find(starts, type_name)
          let next =
            list.filter_map(starts, fn(s) {
              case s.1 > start {
                True -> Ok(s.1)
                False -> Error(Nil)
              }
            })
            |> list.first
            |> result.unwrap(list.length(lines))
          // the block: its doc comment above, then lines up to the next
          // declaration's doc comment
          let body =
            lines
            |> list.drop(start - 1)
            |> list.take(next - start)
            |> drop_tail_comments
          let doc = doc_above(list.take(lines, start - 1))
          Ok(string.join(list.append(doc, body), "\n") <> "\n")
        }
      }
  }
}

fn is_comment_or_blank(l: String) -> Bool {
  string.trim(l) == "" || string.starts_with(l, "#")
}

/// Drop the trailing blank and comment lines (they belong to the next block).
fn drop_tail_comments(ls: List(String)) -> List(String) {
  ls
  |> list.reverse
  |> list.drop_while(is_comment_or_blank)
  |> list.reverse
}

/// The comment lines directly above a declaration.
fn doc_above(before: List(String)) -> List(String) {
  before
  |> list.reverse
  |> list.take_while(fn(l) { string.starts_with(l, "#") })
  |> list.reverse
}
