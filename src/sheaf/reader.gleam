//// The line reader: the bootstrap seed. language.sheaf is read with it once; the
//// grammar it declares is compiled (grammar.gleam), and every file, language.sheaf
//// included, must then match File in exactly one way. The program cross-checks
//// the two block by block, so the reader cannot silently disagree with the spec.
////
//// Every line has the shape of the header of language.sheaf:
////   name {type} (what the value is) property: value, property: value
//// '...' after the type marks a list. The parentheses hold allowed values (a
//// range or a choice), a calculation, a condition (a rule, a claim, a kept
//// list) or a mapping's inputs. The reader turns lines into the model the
//// checker knows: allowed values and calculations become the line's own 'val'
//// predicates, count: becomes the qty setting, a method such as
//// 'late_stops.count' becomes a fold (a path ending in qty or sum, with the
//// kept list's condition as its filter), and a record's text shape orders its
//// stored fields, with each position that holds no field kept as a field named
//// by its number and a dot ("2."). Kept and collected lists are not fields of
//// the model: a fold reads through them to the stored list they come from.

import gleam/dict.{type Dict}
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
  Plain, Position, Setting, StrItem, TypeItem, VArith, VFilter, VMulti, VNum,
  VPath, VRange, VStr,
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

/// An operator that any number of spaces may surround: & | + - *
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

/// One or more spaces between a name and its type.
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

fn upper_first(s: String) -> Bool {
  is_upper(string.slice(s, 0, 1))
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

fn starts_term(sc: Scan) -> Bool {
  starts_number(sc) || is_upper(peek(sc)) || is_lower(peek(sc))
}

/// The characters from one to another in code-point order, both included:
/// '"A".."Z"' lists the 26 capital letters.
fn char_range(sc: Scan, a: String, z: String) -> Result(List(String), MapError) {
  case string.to_utf_codepoints(a), string.to_utf_codepoints(z) {
    [ca], [cz] -> {
      let lo = string.utf_codepoint_to_int(ca)
      let hi = string.utf_codepoint_to_int(cz)
      case lo < hi {
        True -> Ok(code_points(lo, hi, []))
        False ->
          err(
            sc,
            "a range of characters goes from a lower character to a higher one, e.g. \"A\"..\"Z\"",
          )
      }
    }
    _, _ ->
      err(
        sc,
        "a range of characters has one character at each end, e.g. \"A\"..\"Z\"",
      )
  }
}

fn code_points(lo: Int, hi: Int, acc: List(String)) -> List(String) {
  case hi < lo {
    True -> acc
    False -> {
      let assert Ok(cp) = string.utf_codepoint(hi)
      code_points(lo, hi - 1, [string.from_utf_codepoints([cp]), ..acc])
    }
  }
}

fn int_range(lo: Int, hi: Int, acc: List(Int)) -> List(Int) {
  case hi < lo {
    True -> acc
    False -> int_range(lo, hi - 1, [hi, ..acc])
  }
}

/// One item of a type in braces, or the items of a range of characters
/// ('"A".."Z"') or of whole numbers ('1..26').
fn item_group(sc: Scan) -> R(List(Item)) {
  case peek(sc) {
    "\"" -> {
      use #(s, sc2) <- result.try(string_lit(sc))
      case at(sc2, "..") {
        True -> {
          use #(z, sc3) <- result.try(string_lit(adv(sc2, 2)))
          use chars <- result.try(char_range(sc, s, z))
          Ok(#(list.map(chars, StrItem), sc3))
        }
        False -> Ok(#([StrItem(s)], sc2))
      }
    }
    _ ->
      case starts_number(sc) {
        True -> {
          use #(n, sc2) <- result.try(number(sc))
          case at(sc2, "..") && starts_number(adv(sc2, 2)) {
            True -> {
              use #(h, sc3) <- result.try(number(adv(sc2, 2)))
              case
                decimal.is_integral(n.value)
                && decimal.is_integral(h.value)
                && decimal.lt(n.value, h.value)
                && decimal.to_int(h.value) - decimal.to_int(n.value) < 10_000
              {
                True ->
                  Ok(#(
                    int_range(
                      decimal.to_int(n.value),
                      decimal.to_int(h.value),
                      [],
                    )
                      |> list.map(fn(k) {
                        NumItem(decimal.from_int(k), int.to_string(k))
                      }),
                    sc3,
                  ))
                False ->
                  err(
                    sc,
                    "a range in braces lists whole numbers from low to high, e.g. {1..26}",
                  )
              }
            }
            False -> Ok(#([NumItem(n.value, n.text)], sc2))
          }
        }
        False ->
          result.map(type_name(sc, "a type name, a string or a number"), fn(r) {
            #([TypeItem(r.0)], r.1)
          })
      }
  }
}

// ---------------------------------------------------------------- values

/// The methods of a list: the last step of a path.
pub const methods = ["count", "sum", "min", "max"]

/// A path has at most one dot (a field, or one field of that field). 'value'
/// is the line's own value, kept in the model as 'val'.
fn path(sc: Scan) -> R(List(String)) {
  use #(first, sc) <- result.try(any_name(sc))
  let first = case first {
    "value" -> "val"
    _ -> first
  }
  path_rest(sc, [first])
}

fn path_rest(sc: Scan, acc: List(String)) -> R(List(String)) {
  case at(sc, ".") && !at(sc, "..") {
    True ->
      case acc {
        [_, _, ..] ->
          err(
            sc,
            "a path has one dot: to reach further, collect first, e.g. delays {Integer...} (stops.delay), then delays.sum",
          )
        _ -> {
          use #(n, sc2) <- result.try(any_name(adv(sc, 1)))
          case upper_first(n) {
            True ->
              err(
                sc,
                "'"
                  <> string.join(list.reverse(acc), ".")
                  <> "."
                  <> n
                  <> "': a path holds only fields. To keep some of the items of a list, keep them on a line of their own, e.g. late_stops {Stop...} (stops.delay >= 2)",
              )
            False -> path_rest(sc2, [n, ..acc])
          }
        }
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

/// A range end: a number, a constant, or a calculation of them. Ranges whose
/// ends are not both written out are kept as 'VArith("..", ...)' until the
/// file's constants are known (settle_file).
fn range_end(sc: Scan) -> R(Value) {
  use #(t, sc2) <- result.try(term(sc))
  arith(sc2, t)
}

fn range_from(sc: Scan, lo: Value) -> R(Value) {
  case starts_term(sc) {
    True -> {
      use #(hi, sc2) <- result.try(range_end(sc))
      case lo, hi {
        VNum(l), VNum(h) ->
          case decimal.le(h.value, l.value) {
            True ->
              err(
                sc,
                "range "
                  <> l.text
                  <> ".."
                  <> h.text
                  <> case decimal.eq(h.value, l.value) {
                  True ->
                    " is a single value: a value that is always "
                    <> l.text
                    <> " is a constant, e.g. Limit {Integer} ("
                    <> l.text
                    <> ")"
                  False -> " is not ordered (high must be above low)"
                },
              )
            False -> Ok(#(VRange(Some(l), Some(h)), sc2))
          }
        _, _ -> Ok(#(VArith("..", [lo, hi]), sc2))
      }
    }
    False ->
      case lo {
        VNum(l) -> Ok(#(VRange(Some(l), None), sc))
        _ -> Ok(#(VArith("..from", [lo]), sc))
      }
  }
}

fn value(sc: Scan) -> R(Value) {
  case peek(sc) {
    "\"" -> {
      use #(s, sc2) <- result.try(string_lit(sc))
      case at(sc2, "..") {
        True -> {
          use #(z, sc3) <- result.try(string_lit(adv(sc2, 2)))
          use chars <- result.try(char_range(sc, s, z))
          Ok(#(VMulti(list.map(chars, VStr)), sc3))
        }
        False -> Ok(#(VStr(s), sc2))
      }
    }
    _ ->
      case at(sc, "..") {
        True -> {
          use #(hi, sc) <- result.try(range_end(adv(sc, 2)))
          case hi {
            VNum(h) -> Ok(#(VRange(None, Some(h)), sc))
            _ -> Ok(#(VArith("..to", [hi]), sc))
          }
        }
        False -> {
          use #(first, sc) <- result.try(term(sc))
          case at(sc, "..") {
            True -> range_from(adv(sc, 2), first)
            False -> arith(sc, first)
          }
        }
      }
  }
}

pub fn is_range(v: Value) -> Bool {
  case v {
    VRange(..) -> True
    VArith(op, _) -> string.starts_with(op, "..")
    _ -> False
  }
}

fn is_open(v: Value) -> Bool {
  case v {
    VRange(None, _) | VRange(_, None) -> True
    VArith("..from", _) | VArith("..to", _) -> True
    _ -> False
  }
}

const arith_ops = ["+", "-", "*"]

fn arith(sc: Scan, first: Value) -> R(Value) {
  case list.find(arith_ops, fn(op) { has_sym(sc, op) }) {
    Error(_) -> Ok(#(first, sc))
    Ok(op) -> {
      use #(terms, sc) <- result.try(arith_terms(sc, op, [first]))
      case list.find(arith_ops, fn(o) { o != op && has_sym(sc, o) }) {
        Ok(_) ->
          err(
            sc,
            "a calculation uses one operator kind only (there is no precedence): give the other part its own field",
          )
        Error(_) -> Ok(#(VArith(op, terms), sc))
      }
    }
  }
}

fn arith_terms(sc: Scan, op: String, acc: List(Value)) -> R(List(Value)) {
  case sym(sc, op) {
    Some(sc2) -> {
      use #(t, sc) <- result.try(term(sc2))
      arith_terms(sc, op, [t, ..acc])
    }
    None -> Ok(#(list.reverse(acc), sc))
  }
}

/// A calculation: a term, a calculation with one operator kind, or a quotient
/// of exactly two terms.
fn calculation(sc: Scan) -> R(Value) {
  use #(first, sc) <- result.try(term(sc))
  case sym(sc, "/") {
    Some(sc2) -> {
      use #(second, sc3) <- result.try(term(sc2))
      case list.any(["/", ..arith_ops], fn(o) { has_sym(sc3, o) }) {
        True ->
          err(
            sc3,
            "a quotient has exactly two terms: give it its own field to divide again or to add to it",
          )
        False -> Ok(#(VArith("/", [first, second]), sc3))
      }
    }
    None -> {
      use #(v, sc2) <- result.try(arith(sc, first))
      case has_sym(sc2, "/") {
        True ->
          err(
            sc2,
            "'/' does not mix with + - or *: give the quotient its own field",
          )
        False -> Ok(#(v, sc2))
      }
    }
  }
}

/// A comparison, with any number of spaces around it, or 'in' with at least
/// one space on each side.
fn op(sc: Scan) -> Option(#(String, Scan)) {
  let sc2 = skip_spaces(sc)
  case sc2.i > sc.i && at(sc2, "in ") {
    True -> Some(#("in", skip_spaces(adv(sc2, 3))))
    False ->
      case list.find(["<=", ">=", "=", "<", ">"], fn(o) { at(sc2, o) }) {
        Error(_) -> None
        Ok(o) -> Some(#(o, skip_spaces(adv(sc2, string.length(o)))))
      }
  }
}

// ---------------------------------------------------------------- conditions

fn clause(sc: Scan) -> R(Clause) {
  use #(p, sc2) <- result.try(path(sc))
  case op(sc2) {
    None ->
      err(
        sc,
        "expected a condition: a path, a comparison (= < <= > >= in) and a value",
      )
    Some(#(o, sc3)) -> {
      use #(v, sc4) <- result.try(value(sc3))
      Ok(#(Plain(p, o, v), sc4))
    }
  }
}

fn looks_like_condition(sc: Scan) -> Bool {
  case path(sc) {
    Ok(#(_, sc2)) -> option.is_some(op(sc2))
    Error(_) -> False
  }
}

/// Conditions joined by '&' or by '|', never both on one line.
fn block(sc: Scan) -> R(Block) {
  use #(first, sc) <- result.try(clause(sc))
  use #(b, sc) <- result.try(case has_sym(sc, "&"), has_sym(sc, "|") {
    True, _ -> {
      use #(cs, sc) <- result.try(and_rest(sc, [first]))
      case has_sym(sc, "|") {
        True -> err(sc, "conditions use only '&' or only '|' on one line")
        False -> Ok(#(Block(AndConn, cs), sc))
      }
    }
    _, True ->
      case first {
        Plain(p, o, v) -> {
          use #(preds, sc) <- result.try(or_rest(sc, p, o, [v], []))
          case has_sym(sc, "&") {
            True -> err(sc, "conditions use only '&' or only '|' on one line")
            False -> Ok(#(Block(OrConn, preds), sc))
          }
        }
        _ -> err(sc, "only comparisons can be joined by '|'")
      }
    _, _ -> Ok(#(Block(AndConn, [first]), sc))
  })
  use b <- result.try(settle_block(sc, b))
  Ok(#(b, sc))
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
      case looks_like_condition(sc) {
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

/// 'in' asks whether a value is one of a set (a list, a closed range or a
/// choice); '=' compares one value with one value. 'in' stays until the file
/// is settled, then becomes the model's '=', its membership comparison.
fn settle_block(sc: Scan, b: Block) -> Result(Block, MapError) {
  use clauses <- result.try(
    list.try_map(b.clauses, fn(c) {
      case c {
        Plain(p, "in", v) -> {
          let left = string.join(p, ".")
          case is_open(v), v {
            True, _ ->
              err(
                sc,
                model.value_text(v)
                  <> " is open, so it has no end to be in: compare instead, e.g. ("
                  <> left
                  <> " >= 1)",
              )
            _, VRange(..) | _, VMulti(..) -> Ok(c)
            _, VArith(o, _) if o == ".." -> Ok(c)
            _, VPath([_, _]) -> Ok(c)
            _, VPath([t]) ->
              case upper_first(t) {
                True ->
                  err(
                    sc,
                    t
                      <> " is one value: compare with =, e.g. ("
                      <> left
                      <> " = "
                      <> t
                      <> ")",
                  )
                False -> Ok(c)
              }
            _, VNum(n) ->
              err(
                sc,
                n.text
                  <> " is one value: ("
                  <> left
                  <> " = "
                  <> n.text
                  <> ")",
              )
            _, VStr(s) ->
              err(
                sc,
                model.quote(s)
                  <> " is one value: ("
                  <> left
                  <> " = "
                  <> model.quote(s)
                  <> ")",
              )
            _, _ ->
              err(sc, "in takes a list, a closed range or a choice of values")
          }
        }
        Plain(p, "=", v) -> {
          let left = string.join(p, ".")
          case is_range(v), v {
            True, _ ->
              err(
                sc,
                "a range is a set of values: ("
                  <> left
                  <> " in "
                  <> range_text(v)
                  <> ")",
              )
            _, VMulti(_) ->
              err(
                sc,
                "a choice is a set of values: ("
                  <> left
                  <> " in "
                  <> model.value_text(v)
                  <> ")",
              )
            _, _ -> Ok(c)
          }
        }
        Plain(p, o, v) ->
          case is_range(v), v {
            True, _ | _, VMulti(_) ->
              err(
                sc,
                "a range or a choice is a set of values: compare it with in, e.g. ("
                  <> string.join(p, ".")
                  <> " in "
                  <> model.value_text(v)
                  <> ")",
              )
            _, _ -> Ok(Plain(p, o, v))
          }
        other -> Ok(other)
      }
    }),
  )
  Ok(Block(b.conn, clauses))
}

fn range_text(v: Value) -> String {
  case v {
    VArith("..", [lo, hi]) -> model.value_text(lo) <> ".." <> model.value_text(hi)
    VArith("..from", [lo]) -> model.value_text(lo) <> ".."
    VArith("..to", [hi]) -> ".." <> model.value_text(hi)
    _ -> model.value_text(v)
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

// ---------------------------------------------------------------- parentheses

/// What a line's parentheses hold.
type Paren {
  PCond(Block)
  PInputs(List(String))
  /// Allowed values: a range, or a choice of numbers, texts and ranges.
  PAllowed(Value)
  /// A calculation, a path (with a method), or one fixed value.
  PCalc(Value)
}

/// The inside of '( ... )', from just after '(' to just after ')'.
fn paren(sc: Scan) -> R(Paren) {
  use _ <- result.try(case peek(sc) {
    " " -> no_space_inside(sc)
    _ -> Ok(Nil)
  })
  use #(p, sc2) <- result.try(case looks_like_condition(sc) {
    True -> result.map(block(sc), fn(r) { #(PCond(r.0), r.1) })
    False -> {
      let #(word, after) = take_while(sc, is_lower_name_char)
      case word != "" && is_lower(peek(sc)) && at(after, ",") {
        True -> inputs(sc)
        False -> {
          use #(v, sc2) <- result.try(value(sc))
          case is_range(v), v, has_sym(sc2, "|") {
            _, _, True -> choices(sc2, [v])
            True, _, _ | _, VMulti(_), _ -> Ok(#(PAllowed(v), sc2))
            _, _, _ ->
              result.map(calculation(sc), fn(r) { #(PCalc(r.0), r.1) })
          }
        }
      }
    }
  })
  case peek(sc2), peek(skip_spaces(sc2)) {
    ")", _ -> Ok(#(p, adv(sc2, 1)))
    " ", ")" -> no_space_inside(sc2)
    _, _ ->
      err(
        sc2,
        "expected ')': parentheses hold one thing, a range, a choice, a calculation, a condition or a mapping's inputs",
      )
  }
}

fn no_space_inside(sc: Scan) -> Result(a, MapError) {
  err(
    sc,
    "no space goes just inside parentheses, e.g. (0..120) or (kind, late_stop_count)",
  )
}

/// 'a, b': a mapping's two inputs.
fn inputs(sc: Scan) -> R(Paren) {
  use #(a, sc) <- result.try(field_name(sc, "an input field"))
  use sc <- result.try(eat(sc, ","))
  use sc <- result.try(case gap(sc) {
    Some(s) -> Ok(s)
    None -> err(sc, "expected a space after ','")
  })
  use #(b, sc) <- result.try(field_name(sc, "a second input field"))
  case peek(sc) {
    "," -> err(sc, "a mapping has one or two inputs")
    _ -> Ok(#(PInputs([a, b]), sc))
  }
}

/// '10 | 30 | 60': a choice of values.
fn choices(sc: Scan, acc: List(Value)) -> R(Paren) {
  case sym(sc, "|") {
    Some(sc2) -> {
      use #(v, sc3) <- result.try(value(sc2))
      choices(sc3, [v, ..acc])
    }
    None -> Ok(#(PAllowed(multi(acc)), sc))
  }
}

// ---------------------------------------------------------------- properties

/// One property after a line's parentheses: 'name: value'.
type Prop {
  PCount(Value)
  PPlaces(Num)
  PRound(Num, String)
  PWrap(Value)
  PUnique(String)
  POrder(List(String))
  PDigits(Num)
}

pub const prop_names = [
  "count", "places", "round", "wrap_at", "unique", "order", "digits",
]

const round_words = ["away", "lower", "higher"]

/// Words that used to be items, and what to write instead.
fn gone_item(word: String) -> Option(String) {
  case word {
    "qty" ->
      Some(
        "a list is written {Stop...}, and count: says how many items it holds: stops {Stop...} count: 1..",
      )
    "value" ->
      Some(
        "value: is gone: allowed values and calculations go in parentheses after the type, e.g. delay {Integer} (0..120) or minutes {Integer} (hour_minutes + minute)",
      )
    "calc" ->
      Some(
        "calc: is gone: a calculation goes in parentheses after the type, e.g. (a * b)",
      )
    "from" ->
      Some(
        "from: is gone: a mapping's inputs go in parentheses after the type, e.g. refund {True | False} (kind, late_stop_count)",
      )
    "filter" ->
      Some(
        "filter: is gone: a kept list holds the items that meet a condition, e.g. late_stops {Stop...} (stops.delay >= 2)",
      )
    "sum" ->
      Some(
        "collect the field, then sum it: delays {Integer...} (stops.delay), then total_delay {Integer} (delays.sum)",
      )
    "mod" ->
      Some(
        "mod: is gone: a wrap goes after the calculation, e.g. arrives {Minute_Of_Day} (due.minutes + delay) wrap_at: Minutes_Per_Day",
      )
    "if" ->
      Some(
        "if: is gone: a case is its output, then when it applies in parentheses, e.g. {True} (>= 500.00)",
      )
    "sorted" -> Some("ordering a list is written order: station")
    _ -> None
  }
}

fn props(sc: Scan, acc: List(#(String, Prop))) -> R(List(#(String, Prop))) {
  let #(word, after) = take_while(sc, is_lower_name_char)
  case list.contains(prop_names, word) && at(after, ":"), gone_item(word) {
    False, Some(msg) if word != "" -> err(sc, msg)
    False, _ ->
      case peek(sc) {
        "(" ->
          err(
            sc,
            "parentheses come straight after the type, before any property",
          )
        _ ->
          err(
            sc,
            "expected a property, 'name: value', named one of "
              <> string.join(prop_names, " "),
          )
      }
    True, _ -> {
      let sc2 = adv(after, 1)
      use sc3 <- result.try(case gap(sc2) {
        Some(s) -> Ok(s)
        None -> err(sc2, "expected a space after '" <> word <> ":'")
      })
      use #(pr, sc4) <- result.try(prop_value(sc3, word))
      use _ <- result.try(case list.key_find(acc, word) {
        Ok(_) -> err(sc, "the property '" <> word <> ":' appears twice on this line")
        Error(_) -> Ok(Nil)
      })
      let acc = [#(word, pr), ..acc]
      // a comma straight after the property, then one or more spaces
      case at(sc4, ","), gap(adv(sc4, 1)) {
        True, Some(sc5) -> props(sc5, acc)
        True, None -> err(adv(sc4, 1), "expected a space after ','")
        False, _ ->
          case gap(sc4) {
            Some(sc5) -> {
              let #(w, a) = take_while(sc5, is_lower_name_char)
              case w != "" && at(a, ":") {
                True ->
                  err(
                    sc4,
                    "properties are separated by commas, e.g. count: 1.., unique: station",
                  )
                False -> Ok(#(list.reverse(acc), sc4))
              }
            }
            None -> Ok(#(list.reverse(acc), sc4))
          }
      }
    }
  }
}

fn prop_value(sc: Scan, word: String) -> R(Prop) {
  case word {
    "count" ->
      case is_lower(peek(sc)) || is_upper(peek(sc)) {
        True ->
          err(
            sc,
            "count: now limits how many items a list holds. Keep the items first and read their count: late_stops {Stop...} (stops.delay >= 2), then late_stop_count {Integer} (late_stops.count)",
          )
        False -> {
          use #(v, sc2) <- result.try(value(sc))
          case v {
            VNum(n) ->
              case decimal.is_integral(n.value) && !decimal.is_negative(n.value) {
                True -> Ok(#(PCount(v), sc2))
                False -> err(sc, "count: takes a whole number or a range of them")
              }
            VRange(..) -> Ok(#(PCount(v), sc2))
            _ ->
              err(sc, "count: takes a number or a range, e.g. count: 2 or count: 1..")
          }
        }
      }
    "places" -> result.map(natural(sc), fn(r) { #(PPlaces(r.0), r.1) })
    "digits" -> {
      use #(n, sc2) <- result.try(natural(sc))
      case at(sc2, "..") {
        True ->
          err(sc, "a fixed form has one width, so each value prints one way")
        False -> Ok(#(PDigits(n), sc2))
      }
    }
    "round" -> {
      case is_upper(peek(sc)) {
        True ->
          err(
            sc,
            "round: takes the unit to round to and at most one word, away, lower or higher, e.g. round: 0.01 away",
          )
        False -> {
          use #(u, sc2) <- result.try(number(sc))
          use _ <- result.try(
            case decimal.lt(decimal.zero(), u.value) {
              True -> Ok(Nil)
              False -> err(sc, "round: takes a unit above 0, e.g. round: 0.1")
            },
          )
          case gap(sc2) {
            Some(sc3) -> {
              let #(w, sc4) = take_while(sc3, is_lower)
              case list.contains(round_words, w) {
                True -> Ok(#(PRound(u, w), sc4))
                False -> Ok(#(PRound(u, ""), sc2))
              }
            }
            None -> Ok(#(PRound(u, ""), sc2))
          }
        }
      }
    }
    "wrap_at" -> result.map(range_end(sc), fn(r) { #(PWrap(r.0), r.1) })
    "unique" -> {
      let #(w, sc2) = take_while(sc, is_name_char)
      case w {
        "True" | "False" ->
          err(
            sc,
            "unique: goes on a list and names a field: customers {Customer...} unique: code",
          )
        _ ->
          case is_lower(string.slice(w, 0, 1)) {
            True -> Ok(#(PUnique(w), sc2))
            False -> err(sc, "unique: names a field of the list's items")
          }
      }
    }
    _ -> result.map(path(sc), fn(r) { #(POrder(r.0), r.1) })
  }
}

/// A natural number, written out: digits only.
fn natural(sc: Scan) -> R(Num) {
  let #(digits, sc2) = take_while(sc, is_digit)
  case decimal.parse(digits) {
    Ok(v) if digits != "" -> Ok(#(Num(v, digits), sc2))
    _ -> err(sc, "expected a number written out in digits, e.g. 24")
  }
}

/// What follows a line's type: optional parentheses, optional properties, and
/// the line end.
type Tail {
  Tail(paren: Option(Paren), props: List(#(String, Prop)), comment: String)
}

fn line_tail(sc: Scan) -> R(Tail) {
  let #(spaces, sc2) = take_while(sc, fn(c) { c == " " })
  case spaces != "" && peek(sc2) == "(" {
    True -> {
      use #(p, sc3) <- result.try(paren(adv(sc2, 1)))
      use #(#(ps, c), sc4) <- result.try(props_tail(sc3))
      Ok(#(Tail(Some(p), ps, c), sc4))
    }
    False -> {
      use #(#(ps, c), sc3) <- result.try(props_tail(sc))
      Ok(#(Tail(None, ps, c), sc3))
    }
  }
}

fn props_tail(sc: Scan) -> R(#(List(#(String, Prop)), String)) {
  let #(spaces, sc2) = take_while(sc, fn(c) { c == " " })
  case spaces != "" && peek(sc2) != "#" && !done(sc2) {
    True -> {
      use #(ps, sc3) <- result.try(props(sc2, []))
      use #(c, sc4) <- result.try(line_end(sc3))
      Ok(#(#(ps, c), sc4))
    }
    False -> {
      use #(c, sc3) <- result.try(line_end(sc))
      Ok(#(#([], c), sc3))
    }
  }
}

fn only_props(
  sc: Scan,
  ps: List(#(String, Prop)),
  allowed: List(String),
  where: String,
) -> Result(Nil, MapError) {
  case list.find(ps, fn(p) { !list.contains(allowed, p.0) }) {
    Ok(#(name, _)) -> err(sc, prop_misplaced(name, where))
    Error(_) -> Ok(Nil)
  }
}

fn prop_misplaced(name: String, where: String) -> String {
  case name {
    "wrap_at" ->
      "a wrap goes on a calculation: arrives {Minute_Of_Day} (due.minutes + delay) wrap_at: Minutes_Per_Day"
    "round" -> "round: goes after a calculation, to round it"
    "unique" ->
      "unique: goes on a list and names a field: customers {Customer...} unique: code"
    "digits" ->
      "a number's text shape goes on the position that writes it: 1. {hour} digits: 2"
    "count" -> "count: says how many items a list holds: stops {Stop...} count: 1.."
    "order" -> "order: goes on a list or on a text field"
    _ -> name <> ": does not go on " <> where
  }
}

fn count_value(ps: List(#(String, Prop))) -> Option(Value) {
  case list.key_find(ps, "count") {
    Ok(PCount(v)) -> Some(v)
    _ -> None
  }
}

/// A count on a single item: only 'count: 0..1', an item that may be absent.
fn single_count(sc: Scan, v: Value) -> Result(Nil, MapError) {
  case v {
    VRange(Some(lo), Some(hi)) ->
      case
        decimal.eq(lo.value, decimal.zero())
        && decimal.eq(hi.value, decimal.from_int(1))
      {
        True -> Ok(Nil)
        False -> count_needs_list(sc)
      }
    _ -> count_needs_list(sc)
  }
}

fn count_needs_list(sc: Scan) -> Result(Nil, MapError) {
  err(
    sc,
    "count: above 1 needs a list: write the type with ..., e.g. stops {Stop...} count: 1..",
  )
}

const not_built = " is not built yet in this build"

fn order_not_built(sc: Scan, ps: List(#(String, Prop))) -> Result(Nil, MapError) {
  case list.key_find(ps, "order") {
    Ok(_) -> err(sc, "order:" <> not_built)
    Error(_) -> Ok(Nil)
  }
}

// ---------------------------------------------------------------- boxes

type Box {
  EmptyBox
  ItemsBox(List(Item))
  /// '{Stop...}': a list of one type.
  ListBox(Item)
  InterBox(List(Item))
}

/// A type in braces: {}, {A}, {A...}, {A | "b" | 5} or {A & B}. Braces hold
/// only a type.
fn box(sc: Scan) -> R(Box) {
  case at(sc, "{}") {
    True -> Ok(#(EmptyBox, adv(sc, 2)))
    False -> {
      use sc <- result.try(eat(sc, "{"))
      use #(its, sc2) <- result.try(items(sc))
      let counted = case gap(sc2) {
        Some(sc3) -> starts_number(sc3) || at(sc3, "..")
        None -> False
      }
      case counted, its, has_sym(sc2, "&"), at(sc2, "...") {
        True, _, _, _ ->
          err(
            sc2,
            "braces hold only a type: a list's count goes after it, e.g. {Digit...} count: 2",
          )
        False, [TypeItem(_) as one], _, True | False, [StrItem(_) as one], _, True -> {
          use sc3 <- result.try(eat(adv(sc2, 3), "}"))
          Ok(#(ListBox(one), sc3))
        }
        False, _, _, True ->
          err(
            sc2,
            "a list holds one type: name the union first, then write {Name...}",
          )
        False, [TypeItem(_) as first], True, _ -> {
          use #(more, sc3) <- result.try(inter_rest(sc2, [first]))
          use sc4 <- result.try(eat(sc3, "}"))
          Ok(#(InterBox(more), sc4))
        }
        False, _, _, _ -> {
          use sc3 <- result.try(eat(sc2, "}"))
          Ok(#(ItemsBox(its), sc3))
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
  use #(first, sc) <- result.try(item_group(sc))
  items_rest(sc, list.reverse(first))
}

fn items_rest(sc: Scan, acc: List(Item)) -> R(List(Item)) {
  case sym(sc, "|") {
    Some(sc2) -> {
      use #(is, sc) <- result.try(item_group(sc2))
      items_rest(sc, list.append(list.reverse(is), acc))
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
  use entries <- result.try(read_lines(lines, 1, file, [], []))
  settle_file(entries, file)
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

fn no_tail(sc: Scan, t: Tail, what: String) -> Result(Nil, MapError) {
  case t.paren, t.props {
    None, [] -> Ok(Nil)
    _, _ -> err(sc, what <> " takes nothing after its type")
  }
}

fn new_decl(name: String, line: Int, file: String, doc: String) -> Decl {
  Decl(name, model.Union, line, file, [], model.empty, [], [], "", doc, [])
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
          let docs = list.reverse(doc) |> string.join(" ")
          let d = new_decl(name, n, file, docs)
          use #(t, _) <- result.try(line_tail(sc))
          case bx {
            EmptyBox -> {
              use _ <- result.try(no_tail(sc, t, "a record line"))
              use #(#(outs, shapes), rest2, n2) <- result.try(
                record_body(rest, n + 1, file, [], []),
              )
              use #(fields, worked) <- result.try(settle_record(outs, file))
              use fields <- result.try(with_shape(#(fields, shapes), worked, file))
              let d =
                Decl(
                  ..d,
                  kind: model.Record,
                  comment: t.comment,
                  fields: fields,
                  worked: worked,
                )
              read_lines(rest2, n2, file, [], [DeclEntry(d), ..acc])
            }
            InterBox(its2) -> {
              use _ <- result.try(no_tail(sc, t, "an intersection"))
              let d =
                Decl(..d, kind: model.Intersection, items: its2, comment: t.comment)
              read_lines(rest, n + 1, file, [], [DeclEntry(d), ..acc])
            }
            ItemsBox([one]) | ListBox(one) -> {
              let is_list = case bx {
                ListBox(_) -> True
                _ -> False
              }
              use #(positions, rest2, n2) <- result.try(
                read_positions(rest, n + 1, file, []),
              )
              use b <- result.try(type_block(sc, name, one, is_list, t, positions))
              use _ <- result.try(bare_alias(sc, name, one, b, positions))
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
                  comment: t.comment,
                  positions: positions,
                )
              read_lines(rest2, n2, file, [], [DeclEntry(d), ..acc])
            }
            ItemsBox(its2) -> {
              use _ <- result.try(no_tail(
                sc,
                t,
                "a union (to restrict it, name it and refine the name)",
              ))
              let d = Decl(..d, kind: model.Union, items: its2, comment: t.comment)
              read_lines(rest, n + 1, file, [], [DeclEntry(d), ..acc])
            }
          }
        }
      }
    }
  }
}

fn is_number_type(i: Item) -> Bool {
  case i {
    TypeItem(t) -> list.contains(model.builtin_numeric, t)
    _ -> False
  }
}

/// A top-level line with a base of one type: a refinement, a named list, a
/// layout's head or a constant.
fn type_block(
  sc: Scan,
  name: String,
  one: Item,
  is_list: Bool,
  t: Tail,
  positions: List(Position),
) -> Result(Block, MapError) {
  use _ <- result.try(only_props(sc, t.props, ["count", "places"], "a type"))
  use _ <- result.try(case is_number_type(one), positions {
    True, [_, ..] ->
      err(
        sc,
        "a layout's base is Text: a number's written form goes on the position that writes it, e.g. 1. {hour} digits: 2",
      )
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(case one, t.paren, t.props, is_list {
    NumItem(_, text), None, [], False ->
      err(sc, "a constant is written " <> name <> " {Integer} (" <> text <> ")")
    _, _, _, _ -> Ok(Nil)
  })
  use qty <- result.try(case count_value(t.props), is_list {
    Some(v), True -> Ok([Setting("qty", v)])
    None, True -> Ok([Setting("qty", VRange(Some(Num(decimal.zero(), "0")), None))])
    Some(v), False -> {
      use _ <- result.try(single_count(sc, v))
      Ok([Setting("qty", v)])
    }
    None, False -> Ok([])
  })
  use val <- result.try(case t.paren {
    None -> Ok([])
    Some(PAllowed(v)) ->
      case is_list {
        True ->
          err(sc, "a list takes count:, not allowed values: give its items a type")
        False -> Ok([Plain(["val"], "=", v)])
      }
    Some(PCalc(v)) ->
      case is_number_type(one), is_list, positions, t.props {
        True, False, [], [] -> Ok([Plain(["val"], "=", v)])
        _, _, _, _ ->
          err(
            sc,
            "parentheses after a type hold its allowed values, e.g. (0..100); a constant is Name {Integer} (25)",
          )
      }
    Some(PCond(_)) ->
      err(
        sc,
        "a rule names fields, and a named type has none: restrict it with its values, e.g. "
          <> name
          <> " {Integer} (0..100), or make a record with fields",
      )
    Some(PInputs(_)) ->
      err(sc, "inputs in parentheses belong to a mapping: a field of a record")
  })
  let places = case list.key_find(t.props, "places") {
    Ok(PPlaces(n)) -> [Setting("places", VNum(n))]
    _ -> []
  }
  Ok(Block(AndConn, list.flatten([qty, val, places])))
}

fn starts_position(s: String, indent: String) -> Bool {
  string.starts_with(s, indent) && is_digit(char_at(s, string.length(indent)))
}

fn read_positions(
  lines: List(String),
  n: Int,
  file: String,
  acc: List(Position),
) -> Result(#(List(Position), List(String), Int), MapError) {
  case lines {
    [s, ..rest] ->
      case starts_position(s, "  ") {
        True -> {
          use p <- result.try(position(s, n, file))
          read_positions(rest, n + 1, file, [p, ..acc])
        }
        False -> Ok(#(list.reverse(acc), lines, n))
      }
    [] -> Ok(#(list.reverse(acc), lines, n))
  }
}

/// 'N. ' after the indent: the position's number.
fn position_number(sc: Scan, indent: String) -> R(Int) {
  use sc <- result.try(eat(sc, indent))
  let #(digits, sc) = take_while(sc, is_digit)
  let assert Ok(num) = int.parse(digits)
  use sc <- result.try(eat(sc, ". "))
  Ok(#(num, sc))
}

/// The count of a position: '{Digit...} count: 2', '{"-"} count: 0..1'.
fn position_block(sc: Scan, is_list: Bool, t: Tail) -> Result(Block, MapError) {
  use _ <- result.try(case t.paren {
    None -> Ok(Nil)
    Some(_) -> err(sc, "a position takes no parentheses, only count:")
  })
  use _ <- result.try(only_props(sc, t.props, ["count"], "a position"))
  case count_value(t.props), is_list {
    Some(v), True -> Ok(Block(AndConn, [Setting("qty", v)]))
    None, True ->
      Ok(Block(AndConn, [Setting("qty", VRange(Some(Num(decimal.zero(), "0")), None))]))
    Some(v), False -> {
      use _ <- result.try(single_count(sc, v))
      Ok(Block(AndConn, [Setting("qty", v)]))
    }
    None, False -> Ok(model.empty)
  }
}

fn position(s: String, line: Int, file: String) -> Result(Position, MapError) {
  let sc = Scan(s, 0, line, file)
  use #(num, sc) <- result.try(position_number(sc, "  "))
  use #(bx, sc) <- result.try(box(sc))
  use #(t, _) <- result.try(line_tail(sc))
  case bx {
    ItemsBox([one]) -> {
      use b <- result.try(position_block(sc, False, t))
      Ok(Position(num, [one], b, line))
    }
    ListBox(one) -> {
      use b <- result.try(position_block(sc, True, t))
      Ok(Position(num, [one], b, line))
    }
    ItemsBox(its2) -> {
      use _ <- result.try(no_tail(sc, t, "a union position"))
      Ok(Position(num, its2, model.empty, line))
    }
    InterBox(_) -> err(sc, "an intersection is a top-level line")
    EmptyBox -> err(sc, "a position holds an item or a union")
  }
}

fn skip_blank(lines: List(String), n: Int) -> #(List(String), Int) {
  case lines {
    ["", ..rest] -> skip_blank(rest, n + 1)
    _ -> #(lines, n)
  }
}

/// A position of a record's text shape: one of its fields, or a type or
/// literal that holds no field.
type ShapePosition {
  FieldPosition(number: Int, field: String, digits: Option(Num), line: Int)
  TypePosition(number: Int, item: Item, preds: Block, line: Int)
}

type Shape {
  Shape(positions: List(ShapePosition), line: Int)
}

/// A line of a record body, as read: a field of the model, or a list worked
/// out from another list, which the model does not hold.
type FieldOut {
  FieldDone(Field)
  ListDone(name: String, def: ListDef, line: Int)
}

type ListDef {
  /// 'late_stops {Stop...} (stops.delay >= 2)': the conditions name the
  /// fields of the items ('delay').
  Kept(source: String, conditions: Block)
  /// 'delays {Integer...} (stops.delay)'.
  Collected(source: String, field: String)
}

fn record_body(
  lines: List(String),
  n: Int,
  file: String,
  acc: List(FieldOut),
  shapes: List(Shape),
) -> Result(#(#(List(FieldOut), List(Shape)), List(String), Int), MapError) {
  let #(after, k) = skip_blank(lines, n)
  let finish = Ok(#(#(list.reverse(acc), list.reverse(shapes)), lines, n))
  case after {
    [s, ..rest] ->
      case string.starts_with(s, "    "), string.starts_with(s, "  ") {
        True, _ ->
          Error(MapError(
            "a line four spaces in follows a mapping (its cases) or 'text {Text}' (its positions)",
            file,
            k,
            1,
          ))
        False, False -> finish
        False, True ->
          case string.starts_with(s, "  #"), is_digit(char_at(s, 2)) {
            True, _ -> record_body(rest, k + 1, file, acc, shapes)
            _, True ->
              Error(MapError(
                "numbered positions belong to a layout; a record lays out its text under 'text {Text}'",
                file,
                k,
                3,
              ))
            _, _ ->
              case string.starts_with(s, "  text ") {
                True -> {
                  use #(sh, rest2, k2) <- result.try(shape(s, rest, k, file))
                  record_body(rest2, k2, file, acc, [sh, ..shapes])
                }
                False -> {
                  use #(f, rest2, k2) <- result.try(field_line(s, rest, k, file))
                  record_body(rest2, k2, file, [f, ..acc], shapes)
                }
              }
          }
      }
    [] -> finish
  }
}

/// 'text {Text}' and its positions, four spaces in.
fn shape(
  s: String,
  rest: List(String),
  line: Int,
  file: String,
) -> Result(#(Shape, List(String), Int), MapError) {
  let sc = Scan(s, 0, line, file)
  use sc <- result.try(eat(sc, "  text"))
  use sc <- result.try(spaces_then(sc))
  use sc <- result.try(eat(sc, "{Text}"))
  use #(_, _) <- result.try(line_end(sc))
  use #(positions, rest2, n2) <- result.try(
    shape_positions(rest, line + 1, file, []),
  )
  case positions {
    [] ->
      Error(MapError(
        "'text {Text}' lays out the record's text: give its positions four spaces in",
        file,
        line,
        3,
      ))
    _ -> Ok(#(Shape(positions, line), rest2, n2))
  }
}

fn shape_positions(
  lines: List(String),
  n: Int,
  file: String,
  acc: List(ShapePosition),
) -> Result(#(List(ShapePosition), List(String), Int), MapError) {
  case lines {
    [s, ..rest] ->
      case starts_position(s, "    ") {
        True -> {
          let sc = Scan(s, 0, n, file)
          use #(num, sc) <- result.try(position_number(sc, "    "))
          case at(sc, "{") && is_lower(char_at(sc.s, sc.i + 1)) {
            True -> {
              use #(f, sc) <- result.try(field_name(adv(sc, 1), "a field name"))
              use sc <- result.try(eat(sc, "}"))
              use #(t, _) <- result.try(line_tail(sc))
              use _ <- result.try(case t.paren {
                None -> Ok(Nil)
                Some(_) -> err(sc, "a position takes no parentheses")
              })
              use _ <- result.try(only_props(
                sc,
                t.props,
                ["digits"],
                "a field's position",
              ))
              let digits = case list.key_find(t.props, "digits") {
                Ok(PDigits(d)) -> Some(d)
                _ -> None
              }
              shape_positions(rest, n + 1, file, [
                FieldPosition(num, f, digits, n),
                ..acc
              ])
            }
            False -> {
              use #(bx, sc) <- result.try(box(sc))
              use #(t, _) <- result.try(line_tail(sc))
              use #(one, is_list) <- result.try(case bx {
                ItemsBox([one]) -> Ok(#(one, False))
                ListBox(one) -> Ok(#(one, True))
                _ ->
                  err(
                    sc,
                    "a position of a text shape holds one field, type or literal",
                  )
              })
              use b <- result.try(position_block(sc, is_list, t))
              shape_positions(rest, n + 1, file, [
                TypePosition(num, one, b, n),
                ..acc
              ])
            }
          }
        }
        False -> Ok(#(list.reverse(acc), lines, n))
      }
    [] -> Ok(#(list.reverse(acc), lines, n))
  }
}

/// The name a position that holds no field takes in the model: its number and
/// a dot, which no field name can be.
pub fn position_field_name(number: Int) -> String {
  int.to_string(number) <> "."
}

pub fn is_position_field(name: String) -> Bool {
  string.ends_with(name, ".")
}

/// A field the reader adds for a method read inside a calculation or a
/// condition, named by its path: 'stops.count'.
pub fn is_hidden_field(name: String) -> Bool {
  string.contains(name, ".") && !is_position_field(name)
}

/// Order a record's fields by its text shape: the stored fields and the
/// positions that hold no field, in position order, then the other fields as
/// written. A record with no shape keeps its stored fields in order.
fn with_shape(
  parts: #(List(Field), List(Shape)),
  worked: List(String),
  file: String,
) -> Result(List(Field), MapError) {
  let #(fields, shapes) = parts
  case shapes {
    [] -> Ok(fields)
    [_, Shape(_, line), ..] ->
      Error(MapError("a record has at most one text shape", file, line, 3))
    [Shape(positions, line)] -> {
      let stored = list.filter(fields, model.is_stored)
      use placed <- result.try(
        list.index_map(positions, fn(p, i) { #(p, i + 1) })
        |> list.try_map(fn(pair) {
          let #(p, expect) = pair
          case p {
            FieldPosition(num, _, _, l) | TypePosition(num, _, _, l)
              if num != expect
            ->
              Error(MapError(
                "positions are numbered 1, 2, 3 in order: expected "
                  <> int.to_string(expect),
                file,
                l,
                5,
              ))
            FieldPosition(_, name, digits, l) ->
              case list.find(fields, fn(f) { f.name == name }) {
                Error(_) ->
                  case list.contains(worked, name) {
                    True ->
                      Error(MapError(
                        "'"
                          <> name
                          <> "' is worked out from another list, so it has no text: a shape names stored fields",
                        file,
                        l,
                        5,
                      ))
                    False ->
                      Error(MapError(
                        "the text shape names '"
                          <> name
                          <> "', which is not a field of this record",
                        file,
                        l,
                        5,
                      ))
                  }
                Ok(f) ->
                  case model.is_stored(f) {
                    True ->
                      case digits {
                        None -> Ok(f)
                        Some(d) ->
                          Ok(
                            Field(
                              ..f,
                              preds: Block(f.preds.conn, [
                                Setting("digits", VNum(d)),
                                ..f.preds.clauses
                              ]),
                            ),
                          )
                      }
                    False ->
                      Error(MapError(
                        "'"
                          <> name
                          <> "' is worked out, so it has no text: a shape names stored fields",
                        file,
                        l,
                        5,
                      ))
                  }
              }
            TypePosition(num, it, b, l) ->
              Ok(Field(
                position_field_name(num),
                [it],
                b,
                None,
                l,
                "",
                model.Stored,
              ))
          }
        }),
      )
      let named = list.filter(placed, fn(f) { !is_position_field(f.name) })
      use _ <- result.try(
        list.try_map(stored, fn(f) {
          case list.count(named, fn(g) { g.name == f.name }) {
            1 -> Ok(Nil)
            0 ->
              Error(MapError(
                "the stored field '"
                  <> f.name
                  <> "' is missing from the record's text shape",
                file,
                line,
                3,
              ))
            _ ->
              Error(MapError(
                "the text shape names '" <> f.name <> "' more than once",
                file,
                line,
                3,
              ))
          }
        }),
      )
      Ok(list.append(placed, list.filter(fields, fn(f) { !model.is_stored(f) })))
    }
  }
}

/// Names the host still uses for itself in the model ('val' for 'value', and
/// the folds), and the methods of lists, so no field may take them.
const host_names = ["val", "qty", "sum", "count", "min", "max"]

fn starts_case(lines: List(String)) -> Bool {
  case lines {
    [s, ..] -> string.starts_with(s, "    {")
    [] -> False
  }
}

fn field_line(
  s: String,
  rest: List(String),
  line: Int,
  file: String,
) -> Result(#(FieldOut, List(String), Int), MapError) {
  let sc = Scan(s, 0, line, file)
  use sc <- result.try(eat(sc, "  "))
  use #(name, sc) <- result.try(field_name(
    sc,
    "a field name (fields start with a lowercase letter)",
  ))
  use _ <- result.try(case list.contains(host_names, name) {
    True ->
      err(
        Scan(..sc, i: 2),
        case list.contains(methods, name) {
          True -> name <> " is a method of lists and cannot name a field"
          False ->
            "'" <> name <> "' cannot name a field in this build: the checker still uses it"
        },
      )
    False -> Ok(Nil)
  })
  use sc <- result.try(spaces_then(sc))
  use #(bx, sc) <- result.try(box(sc))
  let f = Field(name, [], model.empty, None, line, "", model.Stored)
  let done = fn(f: Field) {
    Ok(#(FieldDone(Field(..f, role: model.classify(f))), rest, line + 1))
  }
  case bx {
    EmptyBox -> err(sc, "a field needs a type")
    InterBox(_) ->
      err(sc, "an intersection is a top-level line: name it, then use the name")
    ItemsBox([TypeItem(kind)]) if kind == "Needs" || kind == "Claims" -> {
      let example = case kind {
        "Needs" -> "plausible {Needs} (delay <= 60)"
        _ -> "nonnegative {Claims} (total >= 0)"
      }
      let after = skip_spaces(sc)
      use _ <- result.try(case peek(after) == "(" && after.i > sc.i {
        True -> Ok(Nil)
        False ->
          err(
            sc,
            "{"
              <> kind
              <> "} takes its condition in parentheses straight after it, e.g. "
              <> example,
          )
      })
      use #(t, _) <- result.try(line_tail(sc))
      use _ <- result.try(case t.props {
        [] -> Ok(Nil)
        _ -> err(sc, "{" <> kind <> "} takes a condition and nothing else")
      })
      case t.paren, kind {
        Some(PCond(Block(AndConn, [Plain(..)]) as b)), "Claims"
        | Some(PCond(b)), "Needs"
        -> done(Field(..f, items: [TypeItem(kind)], preds: b, comment: t.comment))
        Some(PCond(_)), _ ->
          err(sc, "a claim holds one comparison, e.g. " <> example)
        _, _ ->
          err(
            sc,
            "{" <> kind <> "} takes a condition, e.g. " <> example,
          )
      }
    }
    ItemsBox(outs) ->
      case starts_case(rest) {
        True -> mapping_line(f, outs, sc, rest, line, file)
        False -> single_line(f, bx, sc, rest, line)
      }
    ListBox(_) -> single_line(f, bx, sc, rest, line)
  }
}

/// A field line that is not a rule, a claim or a mapping.
fn single_line(
  f: Field,
  bx: Box,
  sc: Scan,
  rest: List(String),
  line: Int,
) -> Result(#(FieldOut, List(String), Int), MapError) {
  use #(t, _) <- result.try(line_tail(sc))
  let done = fn(f: Field) {
    Ok(#(FieldDone(Field(..f, role: model.classify(f))), rest, line + 1))
  }
  case bx {
    ListBox(one) ->
      case t.paren {
        None -> {
          use _ <- result.try(only_props(
            sc,
            t.props,
            ["count", "unique", "order"],
            "a list",
          ))
          use _ <- result.try(order_not_built(sc, t.props))
          let qty = case count_value(t.props) {
            Some(v) -> [Setting("qty", v)]
            None -> []
          }
          let unique = case list.key_find(t.props, "unique") {
            Ok(PUnique(u)) -> [Setting("unique", VPath([u]))]
            _ -> []
          }
          done(
            Field(
              ..f,
              items: [one],
              preds: Block(AndConn, list.flatten([qty, [Flag("list")], unique])),
              comment: t.comment,
            ),
          )
        }
        Some(PCond(b)) -> {
          use _ <- result.try(case t.props {
            [] -> Ok(Nil)
            _ ->
              err(
                sc,
                "a kept list may hold fewer items than its source, and takes no properties. To limit it, write a rule: has_late {Needs} ("
                  <> f.name
                  <> ".count >= 1)",
              )
          })
          use #(source, conditions) <- result.try(kept_conditions(sc, b))
          Ok(#(ListDone(f.name, Kept(source, conditions), line), rest, line + 1))
        }
        Some(PCalc(VPath([l, fld]))) -> {
          use _ <- result.try(case t.props {
            [] -> Ok(Nil)
            _ ->
              err(
                sc,
                "a collected list holds as many items as its source, and takes no properties",
              )
          })
          case upper_first(l) || list.contains(methods, fld) {
            True ->
              err(sc, "a collected list takes one field of each item of a list of this record, e.g. (stops.delay)")
            False ->
              Ok(#(ListDone(f.name, Collected(l, fld), line), rest, line + 1))
          }
        }
        Some(PCalc(VPath([l]))) ->
          err(
            sc,
            "("
              <> l
              <> ") only copies the list: keep some of its items with a condition, e.g. ("
              <> l
              <> ".delay >= 2), or collect one field, e.g. ("
              <> l
              <> ".delay)",
          )
        _ ->
          err(
            sc,
            "a list's parentheses hold a condition (a kept list, e.g. (stops.delay >= 2)) or one field of each item (a collected list, e.g. (stops.delay))",
          )
      }
    ItemsBox([one]) -> {
      use _ <- result.try(old_forms(sc, [one]))
      case t.paren {
        None | Some(PAllowed(_)) -> {
          use _ <- result.try(case one, t.paren, t.props {
            StrItem(_), None, [] | NumItem(..), None, [] ->
              err(
                sc,
                "this field can hold only one text, so it holds no data: put the text in the record's text shape",
              )
            _, _, _ -> Ok(Nil)
          })
          use _ <- result.try(only_props(
            sc,
            t.props,
            ["count", "places", "order"],
            "a field read from the text",
          ))
          use _ <- result.try(order_not_built(sc, t.props))
          use qty <- result.try(case count_value(t.props) {
            Some(v) -> {
              use _ <- result.try(single_count(sc, v))
              Ok([Setting("qty", v)])
            }
            None -> Ok([])
          })
          let val = case t.paren {
            Some(PAllowed(v)) -> [Plain(["val"], "=", v)]
            _ -> []
          }
          let places = case list.key_find(t.props, "places") {
            Ok(PPlaces(n)) -> [Setting("places", VNum(n))]
            _ -> []
          }
          done(
            Field(
              ..f,
              items: [one],
              preds: Block(AndConn, list.flatten([qty, val, places])),
              comment: t.comment,
            ),
          )
        }
        Some(PCalc(v)) -> {
          use b <- result.try(worked_out(sc, f.name, one, v, t.props))
          done(Field(..f, items: [one], preds: b, comment: t.comment))
        }
        Some(PCond(_)) ->
          err(
            sc,
            "a condition makes a rule, name {Needs} (condition), or a kept list, name {Item...} (condition)",
          )
        Some(PInputs(_)) ->
          err(
            sc,
            "inputs in parentheses belong to a mapping, with its cases below, four spaces in",
          )
      }
    }
    ItemsBox(outs) ->
      case t.paren, t.props {
        None, [] -> done(Field(..f, items: outs, comment: t.comment))
        Some(PInputs(_)), _ | Some(PCalc(VPath([_]))), _ ->
          err(
            sc,
            "a mapping needs case lines below it, four spaces in, e.g.     {True} (>= 10)",
          )
        _, _ ->
          err(
            sc,
            "a union field takes nothing after its type: to restrict it, name the union as a type first",
          )
      }
    _ -> err(sc, "a field needs a type")
  }
}

/// The conditions of a kept list, written through its source list
/// ('stops.delay >= 2'), as conditions on the fields of the items ('delay').
fn kept_conditions(sc: Scan, b: Block) -> Result(#(String, Block), MapError) {
  let sources =
    list.filter_map(b.clauses, fn(c) {
      case c {
        Plain([l, _], _, _) -> Ok(l)
        _ -> Error(Nil)
      }
    })
    |> list.unique
  case sources {
    [source] -> {
      use clauses <- result.try(
        list.try_map(b.clauses, fn(c) {
          case c {
            Plain([_, fld], o, v) -> {
              use _ <- result.try(kept_value(sc, source, v))
              Ok(Plain([fld], o, v))
            }
            Plain(p, _, _) ->
              err(
                sc,
                "a kept list's condition names each field through its list, e.g. "
                  <> source
                  <> ".delay >= 2, not "
                  <> string.join(p, "."),
              )
            other -> Ok(other)
          }
        }),
      )
      case upper_first(source) {
        True ->
          err(
            sc,
            "a kept list keeps items of a list of this record, e.g. (stops.delay >= 2)",
          )
        False -> Ok(#(source, Block(b.conn, clauses)))
      }
    }
    [] ->
      err(
        sc,
        "a kept list's condition names the fields of the list it keeps from, e.g. (stops.delay >= 2)",
      )
    _ ->
      err(
        sc,
        "every path in a kept list's condition goes through the same list",
      )
  }
}

/// The right side of a kept list's comparison: a value written out, a
/// constant, or the one value of a type such as True.
fn kept_value(sc: Scan, source: String, v: Value) -> Result(Nil, MapError) {
  case v {
    VNum(_) | VStr(_) | VRange(..) -> Ok(Nil)
    VArith(o, _) if o == ".." || o == "..from" || o == "..to" -> Ok(Nil)
    VPath([t]) ->
      case upper_first(t) {
        True -> Ok(Nil)
        False -> kept_field_error(sc, source)
      }
    VPath([l, _]) if l == source ->
      err(sc, "comparing two fields of one item" <> not_built)
    VMulti(vs) -> list.try_each(vs, fn(x) { kept_value(sc, source, x) })
    _ -> kept_field_error(sc, source)
  }
}

fn kept_field_error(sc: Scan, source: String) -> Result(Nil, MapError) {
  err(
    sc,
    "a kept list compares each item of "
      <> source
      <> " with a value written out or a constant. To compare with something elsewhere, give the item a field first",
  )
}

/// No raw numbers in a calculation: name them, except 0 and 1.
fn raw_number(v: Value) -> Option(String) {
  case v {
    VNum(n) ->
      case decimal.eq(n.value, decimal.zero()) || decimal.eq(n.value, decimal.from_int(1)) {
        True -> None
        False -> Some(n.text)
      }
    VArith(_, ts) -> list.find_map(ts, fn(t) { option.to_result(raw_number(t), Nil) }) |> option.from_result
    _ -> None
  }
}

fn no_raw(sc: Scan, v: Value, what: String) -> Result(Nil, MapError) {
  case raw_number(v) {
    Some(n) ->
      err(
        sc,
        "name the number "
          <> n
          <> " in "
          <> what
          <> ": give it a constant, e.g. Minutes_Per_Hour {Integer} (60)",
      )
    None -> Ok(Nil)
  }
}

/// A worked-out single value: '(calculation)' with 'round:', 'wrap_at:' and
/// 'places:'.
fn worked_out(
  sc: Scan,
  name: String,
  one: Item,
  v: Value,
  ps: List(#(String, Prop)),
) -> Result(Block, MapError) {
  use _ <- result.try(only_props(
    sc,
    ps,
    ["places", "round", "wrap_at"],
    "a worked-out value",
  ))
  use _ <- result.try(case v {
    VNum(_) ->
      err(
        sc,
        "a worked-out value that is always one number is a constant: name it at the top level, e.g. Limit {Integer} (25)",
      )
    _ -> no_raw(sc, v, "a calculation")
  })
  let round = list.key_find(ps, "round")
  let wrap = list.key_find(ps, "wrap_at")
  use _ <- result.try(case v, round, wrap {
    VPath([l, m]), _, _ ->
      case list.contains(methods, m) || upper_first(l) {
        True -> Ok(Nil)
        False ->
          case round, wrap {
            Error(_), Error(_) ->
              err(
                sc,
                "("
                  <> l
                  <> "."
                  <> m
                  <> ") only copies a value one dot away: use "
                  <> l
                  <> "."
                  <> m
                  <> " where it is needed",
              )
            _, _ -> Ok(Nil)
          }
      }
    VPath([x]), Error(_), Error(_) ->
      case upper_first(x) {
        True -> Ok(Nil)
        False ->
          err(sc, "(" <> x <> ") only copies " <> x <> ": use " <> x <> " where it is needed")
      }
    _, _, _ -> Ok(Nil)
  })
  use _ <- result.try(case v, round {
    VArith("/", _), Error(_) ->
      err(
        sc,
        "a quotient can need any number of places: add round: 0.1, or the unit you need",
      )
    _, _ -> Ok(Nil)
  })
  use rounding <- result.try(case round {
    Ok(PRound(u, word)) -> {
      use _ <- result.try(case list.key_find(ps, "places") {
        Ok(_) ->
          err(sc, "a rounded value takes its places from its round: unit")
        Error(_) -> Ok(Nil)
      })
      use places <- result.try(unit_places(sc, u))
      let rule = case word {
        "away" -> "Half_Up"
        "lower" -> "Half_Lower"
        "higher" -> "Half_Higher"
        _ -> "Half_Even"
      }
      Ok([
        Setting("places", VNum(Num(decimal.from_int(places), int.to_string(places)))),
        Setting("round", VPath([rule])),
      ])
    }
    _ -> Ok([])
  })
  use wrapping <- result.try(case wrap {
    Ok(PWrap(w)) -> {
      use _ <- result.try(case w {
        VNum(n) ->
          err(
            sc,
            "name the number: wrap_at: takes a constant, e.g. wrap_at: Minutes_Per_Day (not "
              <> n.text
              <> ")",
          )
        _ -> no_raw(sc, w, "wrap_at:")
      })
      Ok([Setting("mod", w)])
    }
    _ -> Ok([])
  })
  let places = case list.key_find(ps, "places") {
    Ok(PPlaces(n)) -> [Setting("places", VNum(n))]
    _ -> []
  }
  Ok(
    Block(
      AndConn,
      list.flatten([[Plain(["val"], "=", v)], rounding, places, wrapping]),
    ),
  )
}

/// The places of a rounding unit: 1 gives 0, 0.1 gives 1, 0.01 gives 2.
fn unit_places(sc: Scan, u: Num) -> Result(Int, MapError) {
  let places = case string.split_once(u.text, ".") {
    Ok(#(_, frac)) -> string.length(frac)
    Error(_) -> 0
  }
  case decimal.eq(u.value, decimal.unit(places)) {
    True -> Ok(places)
    False -> err(sc, "round: to a unit other than 1, 0.1, 0.01 and so on" <> not_built)
  }
}

/// A field line that is not a rule, a claim or a mapping: refuse a field that
/// could only ever be TRUE or FALSE.
fn old_forms(sc: Scan, outs: List(Item)) -> Result(Nil, MapError) {
  case outs {
    [TypeItem("True")] | [TypeItem("False")] ->
      err(
        sc,
        "a field whose whole type is {True} or {False} always holds that value, so it says nothing: a rule is name {Needs} (condition), and a TRUE or FALSE value is {True | False}",
      )
    _ -> Ok(Nil)
  }
}

/// '(a)' or '(a, b)' after a mapping's output type, then its cases.
fn mapping_line(
  f: Field,
  outs: List(Item),
  sc: Scan,
  rest: List(String),
  line: Int,
  file: String,
) -> Result(#(FieldOut, List(String), Int), MapError) {
  use #(t, _) <- result.try(line_tail(sc))
  use ins <- result.try(case t.paren {
    Some(PCalc(VPath([a]))) ->
      case upper_first(a) {
        True -> err(sc, "a mapping's inputs are fields of this record")
        False -> Ok([a])
      }
    Some(PInputs(ins)) -> Ok(ins)
    None ->
      err(
        sc,
        "a mapping names its inputs in parentheses after its type, e.g. status {Status} (delay)",
      )
    _ ->
      err(
        sc,
        "a mapping's parentheses hold one or two input fields, e.g. (kind, late_stop_count)",
      )
  })
  use _ <- result.try(case t.props {
    [] -> Ok(Nil)
    _ -> err(sc, "nothing follows a mapping's inputs on its line")
  })
  use _ <- result.try(case outs {
    [TypeItem("True")] | [TypeItem("False")] ->
      err(
        sc,
        "a mapping whose only output is {True} or {False} always gives that value, so it says nothing",
      )
    _ -> Ok(Nil)
  })
  use #(cases, rest2, n2) <- result.try(read_cases(rest, line + 1, file, ins, []))
  let f =
    Field(
      ..f,
      items: outs,
      comment: t.comment,
      mapping: Some(Mapping(ins, outs, cases)),
    )
  Ok(#(FieldDone(Field(..f, role: model.classify(f))), rest2, n2))
}

/// A top-level 'Name {Other}' with nothing after it adds no constraint, so two
/// names would mean one thing. Needs and Claims, the two names for TRUE that
/// language.sheaf declares, are the only exceptions.
fn bare_alias(
  sc: Scan,
  name: String,
  one: Item,
  b: Block,
  positions: List(Position),
) -> Result(Nil, MapError) {
  case one, b.clauses, positions {
    TypeItem("True"), [], [] if name == "Needs" || name == "Claims" -> Ok(Nil)
    TypeItem(t), [], [] ->
      err(
        sc,
        "'"
          <> name
          <> " {"
          <> t
          <> "}' adds nothing to "
          <> t
          <> ", so two names would mean one thing: use "
          <> t
          <> ", or add allowed values or a count",
      )
    _, _, _ -> Ok(Nil)
  }
}

/// '    {output} (when)', the cases under a mapping. With one input, a case
/// gives only its values: '(2..9)', '(>= 10)', '("fast")'. With two, it names
/// them. A range of outputs, '{1..26}', maps to a range of characters of the
/// same size, first to first.
fn read_cases(
  lines: List(String),
  n: Int,
  file: String,
  ins: List(String),
  acc: List(Case),
) -> Result(#(List(Case), List(String), Int), MapError) {
  case lines {
    [s, ..rest] ->
      case string.starts_with(s, "    ") {
        True -> {
          let sc = Scan(s, 0, n, file)
          use sc <- result.try(eat(sc, "    "))
          use #(bx, sc) <- result.try(box(sc))
          use outs <- result.try(case bx {
            ItemsBox([_, ..] as outs) -> Ok(outs)
            _ ->
              err(sc, "a case output is a single item in braces, e.g. {True}")
          })
          use sc <- result.try(spaces_then(sc))
          use _ <- result.try(case at(sc, "if:") {
            True -> err(sc, "if: is gone: a case is its output, then when it applies in parentheses, e.g. {True} (>= 500.00)")
            False -> Ok(Nil)
          })
          use sc <- result.try(eat(sc, "("))
          use #(b, sc) <- result.try(case_condition(sc, ins))
          use sc <- result.try(eat(sc, ")"))
          use #(_, _) <- result.try(line_end(sc))
          use new <- result.try(case outs, b {
            [out], _ -> Ok([Case(out, b, n)])
            _, Block(_, [Plain(p, "=", VMulti(vs))]) ->
              case list.length(vs) == list.length(outs) {
                True ->
                  Ok(
                    list.zip(outs, vs)
                    |> list.map(fn(pair) {
                      Case(pair.0, Block(AndConn, [Plain(p, "=", pair.1)]), n)
                    }),
                  )
                False ->
                  err(
                    sc,
                    "the output holds "
                      <> int.to_string(list.length(outs))
                      <> " values and the input "
                      <> int.to_string(list.length(vs)),
                  )
              }
            _, _ ->
              err(
                sc,
                "a range of outputs maps to a range of characters of the same size, e.g. {1..26} (\"A\"..\"Z\")",
              )
          })
          read_cases(rest, n + 1, file, ins, list.append(list.reverse(new), acc))
        }
        False -> done_cases(acc, lines, n, file)
      }
    [] -> done_cases(acc, lines, n, file)
  }
}

fn done_cases(
  acc: List(Case),
  lines: List(String),
  n: Int,
  file: String,
) -> Result(#(List(Case), List(String), Int), MapError) {
  case acc {
    [] ->
      Error(MapError(
        "a mapping needs case lines, '    {output} (when)'",
        file,
        n,
        1,
      ))
    _ -> Ok(#(list.reverse(acc), lines, n))
  }
}

fn case_condition(sc: Scan, ins: List(String)) -> R(Block) {
  case ins {
    [input] ->
      case looks_like_condition(sc) {
        True ->
          err(
            sc,
            input
              <> " is the one input, so a case gives only its values, e.g. (2..9) or (>= 10)",
          )
        False -> {
          let sc2 = skip_spaces(sc)
          case list.find(["<=", ">=", "<", ">"], fn(o) { at(sc2, o) }) {
            Ok(o) -> {
              use #(v, sc3) <- result.try(value(
                skip_spaces(adv(sc2, string.length(o))),
              ))
              use b <- result.try(settle_block(sc, Block(AndConn, [Plain([input], o, v)])))
              Ok(#(b, sc3))
            }
            Error(_) -> {
              use #(v, sc3) <- result.try(value(sc))
              use #(v, sc4) <- result.try(case has_sym(sc3, "|") {
                True -> case_choices(sc3, [v])
                False -> Ok(#(v, sc3))
              })
              Ok(#(Block(AndConn, [Plain([input], "=", v)]), sc4))
            }
          }
        }
      }
    _ ->
      case looks_like_condition(sc) {
        True -> block(sc)
        False ->
          err(
            sc,
            "this mapping has two inputs, so a case names them, e.g. (kind = \"fast\" & late_stop_count >= 1)",
          )
      }
  }
}

fn case_choices(sc: Scan, acc: List(Value)) -> R(Value) {
  case sym(sc, "|") {
    Some(sc2) -> {
      use #(v, sc3) <- result.try(value(sc2))
      case_choices(sc3, [v, ..acc])
    }
    None -> Ok(#(multi(acc), sc))
  }
}

// ---------------------------------------------------------------- records

/// A list reached through kept and collected lists: the stored list it comes
/// from, the conditions on its items, and the field collected from them.
type Base {
  Base(list: String, conditions: Option(Block), field: Option(String))
}

fn base_of(lists: Dict(String, ListDef), name: String) -> Result(Base, String) {
  case dict.get(lists, name) {
    Error(_) -> Ok(Base(name, None, None))
    Ok(Kept(source, b)) -> {
      use src <- result.try(base_of(lists, source))
      case src.field {
        Some(_) ->
          Error(
            "a condition keeps records: keep first, then collect, e.g. late_stops {Stop...} (stops.delay >= 2) and late_delays {Integer...} (late_stops.delay)",
          )
        None ->
          case src.conditions, b.conn {
            None, _ -> Ok(Base(src.list, Some(b), None))
            Some(Block(AndConn, cs)), AndConn ->
              Ok(Base(src.list, Some(Block(AndConn, list.append(cs, b.clauses))), None))
            Some(Block(_, [one])), AndConn ->
              Ok(Base(src.list, Some(Block(AndConn, [one, ..b.clauses])), None))
            Some(_), _ -> Error("a kept list of a kept list whose condition uses |" <> not_built)
          }
      }
    }
    Ok(Collected(source, fld)) -> {
      use src <- result.try(base_of(lists, source))
      case src.field {
        Some(_) -> Error("a path has one dot: collect from a list of records")
        None -> Ok(Base(src.list, src.conditions, Some(fld)))
      }
    }
  }
}

fn folded(path: List(String), b: Option(Block)) -> Value {
  case b {
    Some(b) -> VFilter(path, b)
    None -> VPath(path)
  }
}

/// The fold a method reads: 'late_stops.count' is the count of the stops that
/// meet late_stops' condition.
fn method_fold(
  lists: Dict(String, ListDef),
  x: String,
  m: String,
) -> Result(Value, String) {
  use b <- result.try(base_of(lists, x))
  case m, b.field {
    "count", _ -> Ok(folded([b.list, "qty"], b.conditions))
    "sum", Some(fld) -> Ok(folded([b.list, fld, "sum"], b.conditions))
    "sum", None ->
      case dict.has_key(lists, x) {
        True ->
          Error(
            x
            <> " holds records: .sum adds numbers. Collect a number field first, e.g. delays {Integer...} ("
            <> x
            <> ".delay)",
          )
        False -> Ok(VPath([x, "sum"]))
      }
    _, _ -> Error("." <> m <> not_built)
  }
}

type RecordState {
  RecordState(
    lists: Dict(String, ListDef),
    fields: List(Field),
    hidden: List(String),
  )
}

/// Turn a record's lines into the model's fields: kept and collected lists
/// leave the model, and every method that reads them becomes a fold. A method
/// inside a calculation or a condition gets a field of its own, named by its
/// path ('stops.count'), just above the line that reads it.
fn settle_record(
  outs: List(FieldOut),
  file: String,
) -> Result(#(List(Field), List(String)), MapError) {
  use st <- result.try(
    list.try_fold(outs, RecordState(dict.new(), [], []), fn(st, o) {
      case o {
        ListDone(name, def, line) -> {
          let st2 = RecordState(..st, lists: dict.insert(st.lists, name, def))
          case base_of(st2.lists, name) {
            Ok(_) -> Ok(st2)
            Error(msg) -> Error(MapError(msg, file, line, 3))
          }
        }
        FieldDone(f) -> {
          use #(f, st) <- result.try(settle_field(st, f, file))
          Ok(RecordState(..st, fields: [f, ..st.fields]))
        }
      }
    }),
  )
  Ok(#(list.reverse(st.fields), dict.keys(st.lists)))
}

fn settle_field(
  st: RecordState,
  f: Field,
  file: String,
) -> Result(#(Field, RecordState), MapError) {
  let fail = fn(msg) { fail_line(msg, file, f.line) }
  // a field whose whole value is a method: the fold itself
  let whole = case model.definition(f) {
    Some(VPath([x, m])) ->
      case list.contains(methods, m) {
        True -> Some(#(x, m))
        False -> None
      }
    _ -> None
  }
  case whole {
    Some(#(x, m)) ->
      case method_fold(st.lists, x, m) {
        Ok(v) -> {
          let clauses =
            list.map(f.preds.clauses, fn(c) {
              case c {
                Plain(["val"], "=", VPath([a, b])) if a == x && b == m ->
                  Plain(["val"], "=", v)
                other -> other
              }
            })
          Ok(#(Field(..f, preds: Block(f.preds.conn, clauses)), st))
        }
        Error(msg) -> fail(msg)
      }
    None -> {
      let is_rule = f.items == [TypeItem("Needs")]
      use #(clauses, st) <- result.try(
        list.try_fold(f.preds.clauses, #([], st), fn(acc, c) {
          let #(out, st) = acc
          case c {
            Plain([l1, f1], "=", VPath([l2, f2])) ->
              case is_rule && is_list_name(st, l1) && is_list_name(st, l2) {
                True ->
                  fail_line(
                    "two lists are related with in: ("
                    <> l1
                    <> "."
                    <> f1
                    <> " in "
                    <> l2
                    <> "."
                    <> f2
                    <> ")",
                    file,
                    f.line,
                  )
                False -> {
                  use #(p, st) <- result.try(settle_path(st, [l1, f1], f, file))
                  use #(v, st) <- result.try(settle_value(st, VPath([l2, f2]), f, file))
                  Ok(#([Plain(p, "=", v), ..out], st))
                }
              }
            Plain(p, o, v) -> {
              use #(p, st) <- result.try(settle_path(st, p, f, file))
              use #(v, st) <- result.try(settle_value(st, v, f, file))
              Ok(#([Plain(p, o, v), ..out], st))
            }
            other -> Ok(#([other, ..out], st))
          }
        }),
      )
      Ok(#(Field(..f, preds: Block(f.preds.conn, list.reverse(clauses))), st))
    }
  }
}

fn fail_line(msg: String, file: String, line: Int) -> Result(a, MapError) {
  Error(MapError(msg, file, line, 3))
}

fn is_list_name(st: RecordState, name: String) -> Bool {
  list.any(st.fields, fn(g) {
    g.name == name && model.has_flag(g.preds, "list")
  })
}

fn settle_value(
  st: RecordState,
  v: Value,
  f: Field,
  file: String,
) -> Result(#(Value, RecordState), MapError) {
  case v {
    VPath(p) -> {
      use #(p, st) <- result.try(settle_path(st, p, f, file))
      Ok(#(VPath(p), st))
    }
    VArith(o, ts) -> {
      use #(ts, st) <- result.try(
        list.try_fold(ts, #([], st), fn(acc, t) {
          let #(out, st) = acc
          use #(t, st) <- result.try(settle_value(st, t, f, file))
          Ok(#([t, ..out], st))
        }),
      )
      Ok(#(VArith(o, list.reverse(ts)), st))
    }
    other -> Ok(#(other, st))
  }
}

/// A path inside a calculation or a condition. A method gets its own field,
/// added once; a path into a worked-out list is refused.
fn settle_path(
  st: RecordState,
  p: List(String),
  f: Field,
  file: String,
) -> Result(#(List(String), RecordState), MapError) {
  case p {
    [x, m] ->
      case list.contains(methods, m), dict.has_key(st.lists, x) {
        True, _ -> {
          let name = x <> "." <> m
          case list.contains(st.hidden, name) {
            True -> Ok(#([name], st))
            False ->
              case m == "count" {
                False ->
                  fail_line(
                    "."
                    <> m
                    <> " inside a calculation or a condition"
                    <> not_built
                    <> ": give it its own field first, e.g. total {Integer} ("
                    <> name
                    <> ")",
                    file,
                    f.line,
                  )
                True ->
                  case method_fold(st.lists, x, m) {
                    Error(msg) -> fail_line(msg, file, f.line)
                    Ok(v) -> {
                      let h =
                        Field(
                          name,
                          [TypeItem("Integer")],
                          Block(AndConn, [Plain(["val"], "=", v)]),
                          None,
                          f.line,
                          "",
                          model.Computed,
                        )
                      Ok(#(
                        [name],
                        RecordState(
                          ..st,
                          fields: [h, ..st.fields],
                          hidden: [name, ..st.hidden],
                        ),
                      ))
                    }
                  }
              }
          }
        }
        False, True ->
          fail_line(
            x
            <> " is worked out from another list: read it with a method such as "
            <> x
            <> ".count. Comparing through it"
            <> not_built,
            file,
            f.line,
          )
        False, False -> Ok(#(p, st))
      }
    _ -> Ok(#(p, st))
  }
}

// ---------------------------------------------------------------- files: constants, named lists, unique, digits

/// The whole file at once: constants are worked out, range ends that name
/// them become numbers, a field typed by a named list of records holds that
/// list, 'unique:' on a list marks the field of its items, and a field written
/// with 'digits:' gets a fixed-width form of its number type.
fn settle_file(entries: List(Entry), file: String) -> Result(List(Entry), MapError) {
  let ds = decls(entries)
  use consts <- result.try(
    list.try_fold(ds, dict.new(), fn(acc, d) {
      case constant_value(d) {
        Some(v) ->
          case eval_fixed(acc, v) {
            Ok(n) -> Ok(dict.insert(acc, d.name, n))
            Error(msg) -> Error(MapError(msg, file, d.line, 1))
          }
        None -> Ok(acc)
      }
    }),
  )
  let by_name = list.fold(ds, dict.new(), fn(acc, d) { dict.insert(acc, d.name, d) })
  use ds <- result.try(
    list.try_map(ds, fn(d) {
      case dict.get(consts, d.name) {
        Ok(n) ->
          Ok(Decl(..d, kind: model.Refine, items: [NumItem(n, decimal.to_string(n))], preds: model.empty))
        Error(_) -> resolve_decl(consts, by_name, d)
      }
    }),
  )
  // unique: on a list marks the field of its items
  let uniques =
    list.flat_map(ds, fn(d) {
      list.filter_map(d.fields, fn(f) {
        case model.setting(f.preds, "unique"), f.items {
          Some(VPath([u])), [TypeItem(t)] -> Ok(#(t, u, d, f))
          _, _ -> Error(Nil)
        }
      })
    })
  use ds <- result.try(
    list.try_fold(uniques, ds, fn(ds, q) {
      let #(t, u, d, f) = q
      case list.find(ds, fn(x) { x.name == t && x.kind == model.Record }) {
        Error(_) ->
          Error(MapError(
            "unique: on a list of " <> t <> ", which is not a record of this file," <> not_built,
            file,
            f.line,
            3,
          ))
        Ok(item) ->
          case model.field(item, u) {
            None ->
              Error(MapError(t <> " has no field " <> u, file, f.line, 3))
            Some(_) -> {
              let _ = d
              Ok(
                list.map(ds, fn(x) {
                  case x.name == t {
                    True ->
                      Decl(
                        ..x,
                        fields: list.map(x.fields, fn(g) {
                          case g.name == u && !model.has_flag(g.preds, "unique") {
                            True ->
                              Field(
                                ..g,
                                preds: Block(g.preds.conn, list.append(g.preds.clauses, [Flag("unique")])),
                              )
                            False -> g
                          }
                        }),
                      )
                    False -> x
                  }
                }),
              )
            }
          }
      }
    }),
  )
  // drop the reader's own markers, and add the fixed-width forms
  let #(out, _) =
    list.fold(ds, #([], []), fn(acc, d) {
      let #(out, made) = acc
      let fields =
        list.map(d.fields, fn(f) {
          Field(
            ..f,
            preds: Block(
              f.preds.conn,
              list.filter(f.preds.clauses, fn(c) {
                case c {
                  Flag("list") -> False
                  Setting("unique", _) -> False
                  _ -> True
                }
              }),
            ),
          )
        })
      let wanted =
        list.filter_map(fields, fn(f) {
          case model.setting(f.preds, "digits"), f.items {
            Some(VNum(n)), [TypeItem(t)] -> Ok(#(t, n))
            _, _ -> Error(Nil)
          }
        })
      let #(extra, made) =
        list.fold(wanted, #([], made), fn(acc2, w) {
          let #(extra, made) = acc2
          let name = digits_name(w.0, w.1)
          case list.contains(made, name) {
            True -> #(extra, made)
            False -> #([digits_decl(ds, w.0, w.1, d), ..extra], [name, ..made])
          }
        })
      let fields =
        list.map(fields, fn(f) {
          case model.setting(f.preds, "digits"), f.items {
            Some(VNum(n)), [TypeItem(t)] ->
              Field(
                ..f,
                items: [TypeItem(digits_name(t, n))],
                preds: Block(
                  f.preds.conn,
                  list.filter(f.preds.clauses, fn(c) {
                    case c {
                      Setting("digits", _) -> False
                      _ -> True
                    }
                  }),
                ),
              )
            _, _ -> f
          }
        })
      #([Decl(..d, fields: fields), ..list.append(extra, out)], made)
    })
  Ok(list.map(list.reverse(out), DeclEntry))
}

fn digits_name(t: String, n: Num) -> String {
  t <> "." <> n.text
}

/// A fixed-width form of a number type: its allowed values, written in exactly
/// n digits with leading zeros.
fn digits_decl(ds: List(Decl), t: String, n: Num, at: Decl) -> Decl {
  let preds = case list.find(ds, fn(d) { d.name == t && d.kind == model.Refine }) {
    Ok(d) -> d.preds
    Error(_) -> model.empty
  }
  let base = case list.find(ds, fn(d) { d.name == t }) {
    Ok(d) ->
      case d.items {
        [TypeItem(b)] -> b
        _ -> "Integer"
      }
    Error(_) -> t
  }
  Decl(
    digits_name(t, n),
    model.Layout,
    at.line,
    at.file,
    [TypeItem(base)],
    preds,
    [Position(1, [TypeItem("Digit")], Block(AndConn, [Setting("qty", VNum(n))]), at.line)],
    [],
    "",
    "",
    [],
  )
}

/// The calculation of a constant line: 'Name {Integer} (25)'.
fn constant_value(d: Decl) -> Option(Value) {
  case d.kind, d.items, d.preds.clauses {
    model.Refine, [TypeItem(t)], [Plain(["val"], "=", v)] ->
      case list.contains(model.builtin_numeric, t) && !is_range(v) {
        True ->
          case v {
            VMulti(_) -> None
            _ -> Some(v)
          }
        False -> None
      }
    _, _, _ -> None
  }
}

/// A value of fixed numbers and constants declared above, worked out.
fn eval_fixed(
  consts: Dict(String, decimal.Decimal),
  v: Value,
) -> Result(decimal.Decimal, String) {
  case v {
    VNum(n) -> Ok(n.value)
    VPath([c]) ->
      case dict.get(consts, c) {
        Ok(n) -> Ok(n)
        Error(_) ->
          Error(c <> " is not a constant declared above in this file")
      }
    VPath(p) ->
      Error(
        string.join(p, ".")
        <> " is not a fixed value: a constant or a range end uses only numbers and constants",
      )
    VArith(o, [first, ..rest]) if o == "+" || o == "-" || o == "*" -> {
      use a <- result.try(eval_fixed(consts, first))
      list.try_fold(rest, a, fn(acc, t) {
        use b <- result.try(eval_fixed(consts, t))
        Ok(case o {
          "+" -> decimal.add(acc, b)
          "-" -> decimal.sub(acc, b)
          _ -> decimal.mul(acc, b)
        })
      })
    }
    _ -> Error("a constant uses only numbers, constants and + - *")
  }
}

fn num_of(n: decimal.Decimal) -> Num {
  Num(n, decimal.to_string(n))
}

/// Replace constants and range ends that name them by numbers, everywhere
/// outside a calculation.
fn resolve(
  consts: Dict(String, decimal.Decimal),
  v: Value,
  in_calc: Bool,
) -> Result(Value, String) {
  case v {
    VPath([c]) ->
      case dict.get(consts, c), in_calc {
        Ok(n), False -> Ok(VNum(num_of(n)))
        _, _ -> Ok(v)
      }
    VArith("..", [lo, hi]) -> {
      use l <- result.try(eval_fixed(consts, lo))
      use h <- result.try(eval_fixed(consts, hi))
      case decimal.lt(l, h) {
        True -> Ok(VRange(Some(num_of(l)), Some(num_of(h))))
        False ->
          Error(
            "the range "
            <> range_text(v)
            <> " works out to "
            <> decimal.to_string(l)
            <> ".."
            <> decimal.to_string(h)
            <> ": high must be above low",
          )
      }
    }
    VArith("..from", [lo]) -> {
      use l <- result.try(eval_fixed(consts, lo))
      Ok(VRange(Some(num_of(l)), None))
    }
    VArith("..to", [hi]) -> {
      use h <- result.try(eval_fixed(consts, hi))
      Ok(VRange(None, Some(num_of(h))))
    }
    VArith(o, ts) -> {
      use ts <- result.try(list.try_map(ts, fn(t) { resolve(consts, t, True) }))
      Ok(VArith(o, ts))
    }
    VMulti(vs) -> {
      use vs <- result.try(list.try_map(vs, fn(t) { resolve(consts, t, in_calc) }))
      Ok(VMulti(vs))
    }
    VFilter(p, b) -> {
      use b <- result.try(resolve_block(consts, b))
      Ok(VFilter(p, b))
    }
    _ -> Ok(v)
  }
}

fn resolve_block(
  consts: Dict(String, decimal.Decimal),
  b: Block,
) -> Result(Block, String) {
  use cs <- result.try(
    list.try_map(b.clauses, fn(c) {
      case c {
        Plain(["val"], "=", v) -> {
          // a field's own calculation keeps its constants by name
          let in_calc = case v {
            VArith(o, _) -> !string.starts_with(o, "..")
            VPath([_]) -> True
            _ -> False
          }
          use v <- result.try(resolve(consts, v, in_calc))
          Ok(Plain(["val"], "=", v))
        }
        Plain(p, o, v) -> {
          use v <- result.try(resolve(consts, v, False))
          let o = case o {
            "in" -> "="
            _ -> o
          }
          Ok(Plain(p, o, v))
        }
        Setting("mod", v) -> {
          use n <- result.try(eval_fixed(consts, v))
          Ok(Setting("mod", VNum(num_of(n))))
        }
        other -> Ok(other)
      }
    }),
  )
  Ok(Block(b.conn, cs))
}

fn resolve_decl(
  consts: Dict(String, decimal.Decimal),
  by_name: Dict(String, Decl),
  d: Decl,
) -> Result(Decl, MapError) {
  use preds <- result.try(case resolve_block(consts, d.preds) {
    Ok(b) -> Ok(b)
    Error(msg) -> fail_line(msg, d.file, d.line)
  })
  use fields <- result.try(
    list.try_map(d.fields, fn(f) {
      use preds <- result.try(case resolve_block(consts, f.preds) {
        Ok(b) -> Ok(b)
        Error(msg) -> fail_line(msg, d.file, f.line)
      })
      use mapping <- result.try(case f.mapping {
        None -> Ok(None)
        Some(m) -> {
          use cases <- result.try(
            list.try_map(m.cases, fn(c) {
              case resolve_block(consts, c.preds) {
                Ok(b) -> Ok(Case(..c, preds: b))
                Error(msg) -> fail_line(msg, d.file, c.line)
              }
            }),
          )
          Ok(Some(Mapping(..m, cases: cases)))
        }
      })
      let f = Field(..f, preds: preds, mapping: mapping)
      named_list(by_name, f, d.file)
    }),
  )
  Ok(Decl(..d, preds: preds, fields: fields))
}

/// A field typed by a named list of records holds that list:
/// 'stops {Stops...}' with 'Stops {Stop...} count: 1..' is a list of Stops
/// with Stops' count.
fn named_list(
  by_name: Dict(String, Decl),
  f: Field,
  file: String,
) -> Result(Field, MapError) {
  let is_list = model.has_flag(f.preds, "list")
  case f.items {
    [TypeItem(t)] ->
      case dict.get(by_name, t) {
        Ok(nd) ->
          case nd.kind, nd.items, model.setting(nd.preds, "qty") {
            model.Refine, [TypeItem(item)], Some(q) ->
              case dict.get(by_name, item) |> result.map(fn(it) { it.kind }) {
                Ok(model.Record) ->
                  case is_list {
                    False ->
                      Error(MapError(
                        t <> " is a list: write " <> f.name <> " {" <> t <> "...}",
                        file,
                        f.line,
                        3,
                      ))
                    True -> {
                      let own = model.setting(f.preds, "qty")
                      let clauses =
                        list.filter(f.preds.clauses, fn(c) {
                          case c {
                            Setting("qty", _) -> False
                            _ -> True
                          }
                        })
                      let q = option.unwrap(own, q)
                      Ok(
                        Field(
                          ..f,
                          items: [TypeItem(item)],
                          preds: Block(f.preds.conn, [Setting("qty", q), ..clauses]),
                        ),
                      )
                    }
                  }
                _ -> default_count(f, is_list)
              }
            _, _, _ -> default_count(f, is_list)
          }
        Error(_) -> default_count(f, is_list)
      }
    _ -> default_count(f, is_list)
  }
}

/// A list with no count holds any number of items, none included.
fn default_count(f: Field, is_list: Bool) -> Result(Field, MapError) {
  case is_list, model.setting(f.preds, "qty") {
    True, None ->
      Ok(
        Field(
          ..f,
          preds: Block(f.preds.conn, [
            Setting("qty", VRange(Some(Num(decimal.zero(), "0")), None)),
            ..f.preds.clauses
          ]),
        ),
      )
    _, _ -> Ok(f)
  }
}

pub fn decls(entries: List(Entry)) -> List(Decl) {
  list.filter_map(entries, fn(e) {
    case e {
      DeclEntry(d) -> Ok(d)
    }
  })
}

/// A declaration the reader adds for a fixed-width number form, named with a
/// dot ('Hour.2'), which no written type name can hold.
pub fn is_hidden_decl(name: String) -> Bool {
  string.contains(name, ".")
}
