//// The line reader: the bootstrap seed. language.sheaf is read with it once; the
//// grammar it declares is compiled (grammar.gleam), and every file, language.sheaf
//// included, must then match File in exactly one way. The program cross-checks
//// the two block by block, so the reader cannot silently disagree with the spec.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sheaf/decimal
import sheaf/model.{
  type Block, type Case, type Clause, type Decl, type Entry, type Field,
  type Item, type MapError, type Num, type Position, type Value, AndConn, Block,
  Case, Decl, DeclEntry, Field, Flag, MapError, Mapping, Num, NumItem, OrConn,
  Plain, Position, Setting, StrItem, TypeItem, VArith, VMulti, VNum, VPath,
  VRange, VStr,
}

@external(javascript, "./ffi.mjs", "char_at")
fn char_at(s: String, i: Int) -> String

@external(javascript, "./ffi.mjs", "starts_with_at")
fn starts_with_at(s: String, lit: String, i: Int) -> Bool

@external(javascript, "./ffi.mjs", "slice")
fn slice(s: String, a: Int, b: Int) -> String

@external(javascript, "./ffi.mjs", "length")
fn length(s: String) -> Int

type Scan {
  Scan(s: String, i: Int, line: Int, file: String)
}

type R(a) =
  Result(#(a, Scan), MapError)

fn err(sc: Scan, msg: String) -> Result(b, MapError) {
  Error(MapError(msg, sc.file, sc.line, sc.i + 1))
}

fn at(sc: Scan, lit: String) -> Bool {
  starts_with_at(sc.s, lit, sc.i)
}

fn adv(sc: Scan, n: Int) -> Scan {
  Scan(..sc, i: sc.i + n)
}

fn peek(sc: Scan) -> String {
  char_at(sc.s, sc.i)
}

fn done(sc: Scan) -> Bool {
  sc.i >= length(sc.s)
}

fn skip_spaces(sc: Scan) -> Scan {
  case peek(sc) == " " {
    True -> skip_spaces(adv(sc, 1))
    False -> sc
  }
}

/// An operator that any number of spaces may surround: & | -> + - *
fn sym(sc: Scan, op: String) -> Option(Scan) {
  let sc2 = skip_spaces(sc)
  case at(sc2, op) {
    True -> Some(skip_spaces(adv(sc2, string.length(op))))
    False -> None
  }
}

fn has_sym(sc: Scan, op: String) -> Bool {
  option.is_some(sym(sc, op))
}

/// One or more spaces.
fn gap(sc: Scan) -> Option(Scan) {
  case peek(sc) == " " {
    True -> Some(skip_spaces(sc))
    False -> None
  }
}

/// One or more spaces between a name and its base.
fn spaces_then(sc: Scan) -> Result(Scan, MapError) {
  case gap(sc) {
    Some(sc2) -> Ok(sc2)
    None -> eat(sc, " ")
  }
}

fn eat(sc: Scan, lit: String) -> Result(Scan, MapError) {
  case at(sc, lit) {
    True -> Ok(adv(sc, string.length(lit)))
    False -> {
      let got = case slice(sc.s, sc.i, sc.i + 12) {
        "" -> "end of line"
        g -> g
      }
      err(
        sc,
        "expected " <> string.inspect(lit) <> ", found " <> string.inspect(got),
      )
    }
  }
}

// ---------------------------------------------------------------- character classes

fn is_upper(c: String) -> Bool {
  c != "" && string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
}

fn is_lower(c: String) -> Bool {
  c != "" && string.contains("abcdefghijklmnopqrstuvwxyz", c)
}

fn is_digit(c: String) -> Bool {
  c != "" && string.contains("0123456789", c)
}

fn is_name_char(c: String) -> Bool {
  is_upper(c) || is_lower(c) || is_digit(c) || c == "_"
}

fn is_lower_name_char(c: String) -> Bool {
  is_lower(c) || is_digit(c) || c == "_"
}

const plain_chars =
  " _{}|&=<>.#*+-/,:;!?'()@%[]^~`$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

fn take_while(sc: Scan, ok: fn(String) -> Bool) -> #(String, Scan) {
  take_loop(sc, sc.i, ok)
}

fn take_loop(sc: Scan, start: Int, ok: fn(String) -> Bool) -> #(String, Scan) {
  case ok(peek(sc)) {
    True -> take_loop(adv(sc, 1), start, ok)
    False -> #(slice(sc.s, start, sc.i), sc)
  }
}

fn type_name(sc: Scan, what: String) -> R(String) {
  case is_upper(peek(sc)) {
    False -> err(sc, "expected " <> what)
    True -> {
      let #(first, sc) = #(peek(sc), adv(sc, 1))
      let #(rest, sc) = take_while(sc, is_name_char)
      Ok(#(first <> rest, sc))
    }
  }
}

fn field_name(sc: Scan, what: String) -> R(String) {
  case is_lower(peek(sc)) {
    False -> err(sc, "expected " <> what)
    True -> {
      let #(first, sc) = #(peek(sc), adv(sc, 1))
      let #(rest, sc) = take_while(sc, is_lower_name_char)
      Ok(#(first <> rest, sc))
    }
  }
}

fn any_name(sc: Scan) -> R(String) {
  let c = peek(sc)
  case is_upper(c) || is_lower(c) {
    False -> err(sc, "expected a name")
    True -> {
      let #(rest, sc2) = take_while(adv(sc, 1), is_name_char)
      Ok(#(c <> rest, sc2))
    }
  }
}

// ---------------------------------------------------------------- literals

fn string_lit(sc: Scan) -> R(String) {
  use sc <- result.try(eat(sc, "\""))
  string_body(sc, [])
}

fn string_body(sc: Scan, acc: List(String)) -> R(String) {
  case done(sc) {
    True -> err(sc, "unterminated string literal")
    False ->
      case peek(sc) {
        "\"" -> Ok(#(string.concat(list.reverse(acc)), adv(sc, 1)))
        "\\" ->
          case char_at(sc.s, sc.i + 1) {
            "\"" -> string_body(adv(sc, 2), ["\"", ..acc])
            "\\" -> string_body(adv(sc, 2), ["\\", ..acc])
            "n" -> string_body(adv(sc, 2), ["\n", ..acc])
            _ -> err(sc, "the only escapes are \\\" \\\\ and \\n")
          }
        c ->
          case string.contains(plain_chars, c) {
            True -> string_body(adv(sc, 1), [c, ..acc])
            False ->
              err(
                sc,
                "character "
                  <> string.inspect(c)
                  <> " cannot appear in a string literal",
              )
          }
      }
  }
}

fn number(sc: Scan) -> R(Num) {
  let start = sc.i
  let sc1 = case peek(sc) {
    "-" -> adv(sc, 1)
    _ -> sc
  }
  case is_digit(peek(sc1)) {
    False -> err(sc, "expected a number")
    True -> {
      let #(_, sc2) = take_while(sc1, is_digit)
      let sc3 = case peek(sc2) == "." && is_digit(char_at(sc2.s, sc2.i + 1)) {
        True -> take_while(adv(sc2, 1), is_digit).1
        False -> sc2
      }
      let text = slice(sc.s, start, sc3.i)
      let assert Ok(v) = decimal.parse(text)
      Ok(#(Num(v, text), sc3))
    }
  }
}

fn starts_number(sc: Scan) -> Bool {
  let c = peek(sc)
  c == "-" || is_digit(c)
}

fn item(sc: Scan) -> R(Item) {
  case peek(sc) {
    "\"" -> result.map(string_lit(sc), fn(r) { #(StrItem(r.0), r.1) })
    _ ->
      case starts_number(sc) {
        True ->
          result.map(number(sc), fn(r) {
            #(NumItem({ r.0 }.value, { r.0 }.text), r.1)
          })
        False ->
          result.map(type_name(sc, "a type name, a string or a number"), fn(r) {
            #(TypeItem(r.0), r.1)
          })
      }
  }
}

// ---------------------------------------------------------------- values

fn path(sc: Scan) -> R(List(String)) {
  use #(first, sc) <- result.try(any_name(sc))
  path_rest(sc, [first])
}

fn path_rest(sc: Scan, acc: List(String)) -> R(List(String)) {
  case at(sc, ".") && !at(sc, "..") {
    True -> {
      use #(n, sc) <- result.try(any_name(adv(sc, 1)))
      path_rest(sc, [n, ..acc])
    }
    False -> Ok(#(list.reverse(acc), sc))
  }
}

fn term(sc: Scan) -> R(Value) {
  case starts_number(sc) {
    True -> result.map(number(sc), fn(r) { #(VNum(r.0), r.1) })
    False -> result.map(path(sc), fn(r) { #(VPath(r.0), r.1) })
  }
}

fn value(sc: Scan) -> R(Value) {
  case peek(sc) {
    "\"" -> result.map(string_lit(sc), fn(r) { #(VStr(r.0), r.1) })
    _ ->
      case at(sc, "..") {
        True -> {
          use #(hi, sc) <- result.try(number(adv(sc, 2)))
          Ok(#(VRange(None, Some(hi)), sc))
        }
        False -> {
          use #(first, sc) <- result.try(term(sc))
          case first, at(sc, "..") {
            VNum(lo), True -> {
              let sc = adv(sc, 2)
              case starts_number(sc) {
                True -> {
                  use #(hi, sc2) <- result.try(number(sc))
                  case decimal.le(hi.value, lo.value) {
                    True ->
                      err(
                        sc,
                        "range "
                          <> lo.text
                          <> ".."
                          <> hi.text
                          <> case decimal.eq(hi.value, lo.value) {
                          True ->
                            " is a single value: for a fixed value read from the text, use a literal type, {"
                            <> lo.text
                            <> "}"
                          False -> " is not ordered (high must be above low)"
                        },
                      )
                    False -> Ok(#(VRange(Some(lo), Some(hi)), sc2))
                  }
                }
                False -> Ok(#(VRange(Some(lo), None), sc))
              }
            }
            _, _ -> arith(sc, first)
          }
        }
      }
  }
}

fn arith(sc: Scan, first: Value) -> R(Value) {
  case list.find(["+", "-", "*"], fn(op) { arith_op(sc, op) }) {
    Error(_) -> Ok(#(first, sc))
    Ok(op) -> {
      use #(terms, sc) <- result.try(arith_terms(sc, op, [first]))
      case list.find(["+", "-", "*"], fn(o) { o != op && arith_op(sc, o) }) {
        Ok(_) ->
          err(
            sc,
            "an expression uses one operator kind only (no precedence exists)",
          )
        Error(_) -> Ok(#(VArith(op, terms), sc))
      }
    }
  }
}

/// An arithmetic operator follows. '-' must not be the arrow '->'.
fn arith_op(sc: Scan, op: String) -> Bool {
  case sym(sc, op) {
    None -> False
    Some(_) -> !{ op == "-" && at(skip_spaces(sc), "->") }
  }
}

fn arith_terms(sc: Scan, op: String, acc: List(Value)) -> R(List(Value)) {
  case arith_op(sc, op), sym(sc, op) {
    True, Some(sc2) -> {
      use #(t, sc) <- result.try(term(sc2))
      arith_terms(sc, op, [t, ..acc])
    }
    _, _ -> Ok(#(list.reverse(acc), sc))
  }
}

/// A comparison, with any number of spaces around it.
fn op(sc: Scan) -> Option(#(String, Scan)) {
  let sc2 = skip_spaces(sc)
  case list.find(["<=", ">=", "=", "<", ">"], fn(o) { at(sc2, o) }) {
    Error(_) -> None
    Ok(o) -> Some(#(o, skip_spaces(adv(sc2, string.length(o)))))
  }
}

// ---------------------------------------------------------------- predicates

/// The reserved properties of a line, compared like fields: places, mod and
/// print take '=', cost takes '<=' (a promise of at most that cost).
pub const properties = ["places", "mod", "print", "cost"]

fn clause(sc: Scan) -> R(Clause) {
  let #(word, after) = take_while(sc, is_name_char)
  case word {
    "unique" -> Ok(#(Flag("unique"), after))
    _ -> {
      use #(p, sc2) <- result.try(path(sc))
      case op(sc2) {
        None ->
          err(
            sc,
            "expected a predicate: 'field op value', a property like places = 2, or 'unique'",
          )
        Some(#(o, sc3)) -> {
          use #(v, sc4) <- result.try(value(sc3))
          case p, o {
            ["qty"], _ ->
              err(
                sc,
                "a list's count goes in its braces, e.g. {Digit 2} or {Line 1..}",
              )
            ["cost"], "<=" -> Ok(#(Setting("cost", v), sc4))
            ["cost"], _ -> err(sc, "cost is a promise: write cost <= ...")
            [k], "=" ->
              case list.contains(properties, k) {
                True ->
                  case v {
                    VStr(_) -> err(sc, k <> " takes a number")
                    _ -> Ok(#(Setting(k, v), sc4))
                  }
                False -> Ok(#(Plain(p, o, v), sc4))
              }
            [k], _ ->
              case list.contains(properties, k) {
                True -> err(sc, k <> " is a property: write " <> k <> " = ...")
                False -> Ok(#(Plain(p, o, v), sc4))
              }
            _, _ -> Ok(#(Plain(p, o, v), sc4))
          }
        }
      }
    }
  }
}

fn looks_like_predicate(sc: Scan) -> Bool {
  case path(sc) {
    Ok(#(_, sc2)) -> option.is_some(op(sc2))
    Error(_) -> False
  }
}

fn block(sc: Scan) -> R(Block) {
  use #(first, sc) <- result.try(clause(sc))
  case has_sym(sc, "&"), has_sym(sc, "|") {
    True, _ -> {
      use #(cs, sc) <- result.try(and_rest(sc, [first]))
      case has_sym(sc, "|") {
        True -> err(sc, "predicates use only '&' or only '|' on one line")
        False -> Ok(#(Block(AndConn, cs), sc))
      }
    }
    _, True ->
      case first {
        Plain(p, o, v) -> {
          use #(preds, sc) <- result.try(or_rest(sc, p, o, [v], []))
          case has_sym(sc, "&") {
            True -> err(sc, "predicates use only '&' or only '|' on one line")
            False -> Ok(#(Block(OrConn, preds), sc))
          }
        }
        _ -> err(sc, "only comparisons can be joined by '|'")
      }
    _, _ -> Ok(#(Block(AndConn, [first]), sc))
  }
}

fn and_rest(sc: Scan, acc: List(Clause)) -> R(List(Clause)) {
  case sym(sc, "&") {
    Some(sc2) -> {
      use #(c, sc) <- result.try(clause(sc2))
      and_rest(sc, [c, ..acc])
    }
    None -> Ok(#(list.reverse(acc), sc))
  }
}

fn multi(vals: List(Value)) -> Value {
  case vals {
    [one] -> one
    _ -> VMulti(list.reverse(vals))
  }
}

fn or_rest(
  sc: Scan,
  p: List(String),
  o: String,
  vals: List(Value),
  acc: List(Clause),
) -> R(List(Clause)) {
  case sym(sc, "|") {
    None -> Ok(#(list.reverse([Plain(p, o, multi(vals)), ..acc]), sc))
    Some(sc) -> {
      case looks_like_predicate(sc) {
        True -> {
          use #(c, sc2) <- result.try(clause(sc))
          case c {
            Plain(p2, o2, v2) ->
              or_rest(sc2, p2, o2, [v2], [Plain(p, o, multi(vals)), ..acc])
            _ -> err(sc, "only comparisons can be joined by '|'")
          }
        }
        False -> {
          use #(v, sc2) <- result.try(value(sc))
          or_rest(sc2, p, o, [v, ..vals], acc)
        }
      }
    }
  }
}

/// The end of a line: an optional trailing comment (spaces, '#', text).
fn line_end(sc: Scan) -> R(String) {
  let #(spaces, sc2) = take_while(sc, fn(c) { c == " " })
  case spaces != "" && peek(sc2) == "#" {
    True ->
      Ok(#(
        string.trim(slice(sc.s, sc2.i + 1, length(sc.s))),
        Scan(..sc, i: length(sc.s)),
      ))
    False ->
      case done(sc2) {
        True -> Ok(#("", sc2))
        False ->
          err(
            sc,
            "unexpected text " <> string.inspect(slice(sc.s, sc.i, sc.i + 20)),
          )
      }
  }
}

/// Optional ' predicates', then the line end.
fn tail(sc: Scan) -> R(#(Block, String)) {
  let #(spaces, sc2) = take_while(sc, fn(c) { c == " " })
  case spaces != "" && peek(sc2) != "#" && !done(sc2) {
    True -> {
      use #(b, sc3) <- result.try(block(sc2))
      use #(c, sc4) <- result.try(line_end(sc3))
      Ok(#(#(b, c), sc4))
    }
    False -> {
      use #(c, sc3) <- result.try(line_end(sc))
      Ok(#(#(model.empty, c), sc3))
    }
  }
}

// ---------------------------------------------------------------- boxes

type Box {
  EmptyBox
  ItemsBox(List(Item))
  /// '{Item n}': a list of n items (Step 3).
  CountBox(Item, Value)
  InterBox(List(Item))
  MapBox(inputs: List(String), outputs: List(Item))
}

fn box(sc: Scan) -> R(Box) {
  case at(sc, "{}") {
    True -> Ok(#(EmptyBox, adv(sc, 2)))
    False -> {
      use sc <- result.try(eat(sc, "{"))
      case mapping_head(sc) {
        Some(#(inputs, sc2)) -> {
          use #(outs, sc3) <- result.try(items(sc2))
          case list.length(inputs) == 2 && list.length(outs) > 1 {
            True -> err(sc, "a two-input mapping has a single output item")
            False -> {
              use sc4 <- result.try(eat(sc3, "}"))
              Ok(#(MapBox(inputs, outs), sc4))
            }
          }
        }
        None -> {
          use #(its, sc2) <- result.try(items(sc))
          let counted = case gap(sc2) {
            Some(sc3) -> starts_number(sc3) || at(sc3, "..")
            None -> False
          }
          case its, counted {
            [one], True -> {
              let assert Some(sc3) = gap(sc2)
              use #(c, sc4) <- result.try(value(sc3))
              case c {
                VNum(_) | VRange(..) -> {
                  use sc5 <- result.try(eat(sc4, "}"))
                  Ok(#(CountBox(one, c), sc5))
                }
                _ -> err(sc3, "a count is a number or a range, e.g. 2 or 1..")
              }
            }
            [_, _, ..], True ->
              err(
                sc2,
                "a count goes after a single item; to repeat a union, name it first",
              )
            _, _ -> box_rest(sc2, its)
          }
        }
      }
    }
  }
}

/// A counted box reads as a single item plus its count, kept as the
/// internal qty setting.
fn uncount(bx: Box) -> #(Box, Option(Value)) {
  case bx {
    CountBox(one, c) -> #(ItemsBox([one]), Some(c))
    _ -> #(bx, None)
  }
}

fn with_count(
  sc: Scan,
  b: Block,
  count: Option(Value),
) -> Result(Block, MapError) {
  case count, b {
    None, _ -> Ok(b)
    Some(c), Block(AndConn, cs) -> Ok(Block(AndConn, [Setting("qty", c), ..cs]))
    Some(c), Block(OrConn, []) -> Ok(Block(AndConn, [Setting("qty", c)]))
    Some(_), _ ->
      err(
        sc,
        "a list cannot take '|' predicates; put the choice on the item type",
      )
  }
}

fn box_rest(sc2: Scan, its: List(Item)) -> R(Box) {
  case its, has_sym(sc2, "&") {
    [TypeItem(_) as first], True -> {
      use #(more, sc3) <- result.try(inter_rest(sc2, [first]))
      use sc4 <- result.try(eat(sc3, "}"))
      Ok(#(InterBox(more), sc4))
    }
    _, _ -> {
      use sc3 <- result.try(eat(sc2, "}"))
      Ok(#(ItemsBox(its), sc3))
    }
  }
}

fn mapping_head(sc: Scan) -> Option(#(List(String), Scan)) {
  case field_name(sc, "") {
    Error(_) -> None
    Ok(#(a, sc2)) ->
      case sym(sc2, "->") {
        Some(sc3) -> Some(#([a], sc3))
        None ->
          case sym(sc2, "&") {
            None -> None
            Some(sc3) ->
              case field_name(sc3, "") {
                Ok(#(b, sc4)) ->
                  case sym(sc4, "->") {
                    Some(sc5) -> Some(#([a, b], sc5))
                    None -> None
                  }
                Error(_) -> None
              }
          }
      }
  }
}

/// The rest of an intersection, ' & Type_Name' repeated.
fn inter_rest(sc: Scan, acc: List(Item)) -> R(List(Item)) {
  case sym(sc, "&") {
    Some(sc2) -> {
      use #(n, sc) <- result.try(type_name(
        sc2,
        "a type name (an intersection joins types with ' & ')",
      ))
      inter_rest(sc, [TypeItem(n), ..acc])
    }
    None -> Ok(#(list.reverse(acc), sc))
  }
}

fn items(sc: Scan) -> R(List(Item)) {
  use #(first, sc) <- result.try(item(sc))
  items_rest(sc, [first])
}

fn items_rest(sc: Scan, acc: List(Item)) -> R(List(Item)) {
  case sym(sc, "|") {
    Some(sc2) -> {
      use #(i, sc) <- result.try(item(sc2))
      items_rest(sc, [i, ..acc])
    }
    None -> Ok(#(list.reverse(acc), sc))
  }
}

// ---------------------------------------------------------------- files

/// A file is read as if it ended with a newline: its last line may omit one.
pub fn as_file_text(text: String) -> String {
  case text == "" || string.ends_with(text, "\n") {
    True -> text
    False -> text <> "\n"
  }
}

pub const max_line = 100

pub fn read(text: String, file: String) -> Result(List(Entry), MapError) {
  let lines = string.split(as_file_text(text), "\n")
  let lines = list.take(lines, list.length(lines) - 1)
  use lines <- result.try(physical_lines(lines, 1, file, []))
  read_lines(lines, 1, file, [], [])
}

/// Every line is at most 100 characters and has no tabs. Trailing spaces mean
/// nothing, so they are dropped; a line of only spaces is a blank line.
fn physical_lines(
  lines: List(String),
  n: Int,
  file: String,
  acc: List(String),
) -> Result(List(String), MapError) {
  case lines {
    [] -> Ok(list.reverse(acc))
    [s, ..rest] -> {
      let len = length(s)
      case string.split_once(s, "\t"), len > max_line {
        Ok(#(before, _)), _ ->
          Error(MapError(
            "a tab: indent and separate with spaces",
            file,
            n,
            length(before) + 1,
          ))
        _, True ->
          Error(MapError(
            "this line is "
              <> int.to_string(len)
              <> " characters; the limit is "
              <> int.to_string(max_line),
            file,
            n,
            max_line + 1,
          ))
        _, False ->
          physical_lines(rest, n + 1, file, [trim_spaces_end(s), ..acc])
      }
    }
  }
}

fn trim_spaces_end(s: String) -> String {
  case string.ends_with(s, " ") {
    True -> trim_spaces_end(string.drop_end(s, 1))
    False -> s
  }
}

fn read_lines(
  lines: List(String),
  n: Int,
  file: String,
  doc: List(String),
  acc: List(Entry),
) -> Result(List(Entry), MapError) {
  case lines {
    [] -> Ok(list.reverse(acc))
    ["", ..rest] -> read_lines(rest, n + 1, file, [], acc)
    [s, ..rest] -> {
      let sc = Scan(s, 0, n, file)
      case
        string.starts_with(s, "#"),
        string.starts_with(s, " "),
        string.starts_with(s, "import ")
      {
        True, _, _ ->
          read_lines(
            rest,
            n + 1,
            file,
            [string.trim(string.drop_start(s, 1)), ..doc],
            acc,
          )
        _, True, _ ->
          Error(MapError("indented line outside a record or layout", file, n, 1))
        _, _, True ->
          err(
            sc,
            "there are no imports: a file sees its own folder, the folders above it, each subfolder's front file and the standard library",
          )
        _, _, _ -> {
          use #(name, sc) <- result.try(type_name(
            sc,
            "a type name (types start with an uppercase letter)",
          ))
          use sc <- result.try(spaces_then(sc))
          use #(bx, sc) <- result.try(box(sc))
          let #(bx, count) = uncount(bx)
          let docs = list.reverse(doc) |> string.join(" ")
          let d =
            Decl(name, model.Union, n, file, [], model.empty, [], [], "", docs)
          case bx {
            EmptyBox -> {
              use #(c, _) <- result.try(line_end(sc))
              use #(fields, rest2, n2) <- result.try(
                record_body(rest, n + 1, file, []),
              )
              let d = Decl(..d, kind: model.Record, comment: c, fields: fields)
              read_lines(rest2, n2, file, [], [DeclEntry(d), ..acc])
            }
            MapBox(..) -> err(sc, "a mapping is a field, not a top-level line")
            CountBox(..) -> err(sc, "internal: counted box")
            InterBox(its) -> {
              use #(c, _) <- result.try(line_end(sc))
              let d =
                Decl(..d, kind: model.Intersection, items: its, comment: c)
              read_lines(rest, n + 1, file, [], [DeclEntry(d), ..acc])
            }
            ItemsBox([one]) -> {
              use #(#(b, c), _) <- result.try(tail(sc))
              use b <- result.try(with_count(sc, b, count))
              use #(positions, rest2, n2) <- result.try(
                read_positions(rest, n + 1, file, []),
              )
              let kind = case positions {
                [] -> model.Refine
                _ -> model.Layout
              }
              let d =
                Decl(
                  ..d,
                  kind: kind,
                  items: [one],
                  preds: b,
                  comment: c,
                  positions: positions,
                )
              read_lines(rest2, n2, file, [], [DeclEntry(d), ..acc])
            }
            ItemsBox(its) -> {
              use #(c, _) <- result.try(line_end(sc))
              let d = Decl(..d, kind: model.Union, items: its, comment: c)
              read_lines(rest, n + 1, file, [], [DeclEntry(d), ..acc])
            }
          }
        }
      }
    }
  }
}

fn starts_position(s: String) -> Bool {
  string.starts_with(s, "  ") && is_digit(char_at(s, 2))
}

fn read_positions(
  lines: List(String),
  n: Int,
  file: String,
  acc: List(Position),
) -> Result(#(List(Position), List(String), Int), MapError) {
  case lines {
    [s, ..rest] ->
      case starts_position(s) {
        True -> {
          use p <- result.try(position(s, n, file))
          read_positions(rest, n + 1, file, [p, ..acc])
        }
        False -> Ok(#(list.reverse(acc), lines, n))
      }
    [] -> Ok(#(list.reverse(acc), lines, n))
  }
}

fn position(s: String, line: Int, file: String) -> Result(Position, MapError) {
  let sc = Scan(s, 0, line, file)
  use sc <- result.try(eat(sc, "  "))
  let #(digits, sc) = take_while(sc, is_digit)
  let assert Ok(num) = int.parse(digits)
  use sc <- result.try(eat(sc, ". "))
  use #(bx, sc) <- result.try(box(sc))
  let #(bx, count) = uncount(bx)
  case bx {
    ItemsBox([one]) -> {
      use #(#(b, _), _) <- result.try(tail(sc))
      use b <- result.try(with_count(sc, b, count))
      Ok(Position(num, [one], b, line))
    }
    ItemsBox(its) -> {
      use #(_, _) <- result.try(line_end(sc))
      Ok(Position(num, its, model.empty, line))
    }
    InterBox(_) -> err(sc, "an intersection is a top-level line")
    _ -> err(sc, "a position holds an item or a union")
  }
}

fn skip_blank(lines: List(String), n: Int) -> #(List(String), Int) {
  case lines {
    ["", ..rest] -> skip_blank(rest, n + 1)
    _ -> #(lines, n)
  }
}

fn record_body(
  lines: List(String),
  n: Int,
  file: String,
  acc: List(Field),
) -> Result(#(List(Field), List(String), Int), MapError) {
  let #(after, k) = skip_blank(lines, n)
  case after {
    [s, ..rest] ->
      case string.starts_with(s, "    "), string.starts_with(s, "  ") {
        True, _ ->
          Error(MapError(
            "a case line ('    | ...') must follow a mapping field",
            file,
            k,
            1,
          ))
        False, False -> Ok(#(list.reverse(acc), lines, n))
        False, True ->
          case string.starts_with(s, "  #") {
            True -> record_body(rest, k + 1, file, acc)
            False ->
              case is_digit(char_at(s, 2)) {
                True ->
                  Error(MapError(
                    "numbered positions belong to a layout, not a record",
                    file,
                    k,
                    3,
                  ))
                False -> {
                  use #(f, rest2, k2) <- result.try(field_line(s, rest, k, file))
                  record_body(rest2, k2, file, [f, ..acc])
                }
              }
          }
      }
    [] -> Ok(#(list.reverse(acc), lines, n))
  }
}

fn field_line(
  s: String,
  rest: List(String),
  line: Int,
  file: String,
) -> Result(#(Field, List(String), Int), MapError) {
  let sc = Scan(s, 0, line, file)
  use sc <- result.try(eat(sc, "  "))
  use #(name, sc) <- result.try(field_name(
    sc,
    "a field name (fields start with a lowercase letter)",
  ))
  use sc <- result.try(spaces_then(sc))
  use #(bx, sc) <- result.try(box(sc))
  let #(bx, count) = uncount(bx)
  let f = Field(name, [], model.empty, None, line, "", model.Stored)
  case bx {
    EmptyBox -> err(sc, "a field needs a base")
    InterBox(_) -> err(sc, "an intersection is a top-level line")
    MapBox(inputs, outs) -> {
      use #(c, _) <- result.try(line_end(sc))
      use #(cases, rest2, n2) <- result.try(
        read_cases(rest, line + 1, file, []),
      )
      case cases {
        [] ->
          Error(MapError(
            "mapping field '" <> name <> "' needs at least one case line",
            file,
            line,
            1,
          ))
        _ -> {
          let f =
            Field(
              ..f,
              items: outs,
              comment: c,
              mapping: Some(Mapping(inputs, outs, cases)),
            )
          Ok(#(Field(..f, role: model.classify(f)), rest2, n2))
        }
      }
    }
    CountBox(..) -> err(sc, "internal: counted box")
    ItemsBox([one]) -> {
      use #(#(b, c), _) <- result.try(tail(sc))
      use b <- result.try(with_count(sc, b, count))
      let f = Field(..f, items: [one], preds: b, comment: c)
      Ok(#(Field(..f, role: model.classify(f)), rest, line + 1))
    }
    ItemsBox(its) -> {
      use #(c, _) <- result.try(line_end(sc))
      let f = Field(..f, items: its, comment: c)
      Ok(#(Field(..f, role: model.classify(f)), rest, line + 1))
    }
  }
}

fn read_cases(
  lines: List(String),
  n: Int,
  file: String,
  acc: List(Case),
) -> Result(#(List(Case), List(String), Int), MapError) {
  case lines {
    [s, ..rest] ->
      case string.starts_with(s, "    ") {
        True -> {
          let sc = Scan(s, 0, n, file)
          use sc <- result.try(eat(sc, "    | "))
          use #(bx, sc) <- result.try(box(sc))
          case bx {
            ItemsBox([out]) -> {
              use sc <- result.try(case gap(sc) {
                Some(sc) -> Ok(sc)
                None -> err(sc, "expected a space after the case output")
              })
              use #(b, sc) <- result.try(block(sc))
              use #(_, _) <- result.try(line_end(sc))
              read_cases(rest, n + 1, file, [Case(out, b, n), ..acc])
            }
            _ ->
              err(sc, "a case output is a single item in braces, e.g. {True}")
          }
        }
        False -> Ok(#(list.reverse(acc), lines, n))
      }
    [] -> Ok(#(list.reverse(acc), lines, n))
  }
}

pub fn decls(entries: List(Entry)) -> List(Decl) {
  list.filter_map(entries, fn(e) {
    case e {
      DeclEntry(d) -> Ok(d)
    }
  })
}
