//// The line reader: the bootstrap seed. language.sheaf is read with it once; the
//// grammar it declares is compiled (grammar.gleam), and every file, language.sheaf
//// included, must then match File in exactly one way. The program cross-checks
//// the two block by block, so the reader cannot silently disagree with the spec.
////
//// Lines have the form 'name {type} item: value, item: value' (the header of
//// language.sheaf). The reader turns them into the model the checker knows:
//// calc:, count:, sum: and value: become the line's own 'val' predicates, a
//// fold becomes a path ending in qty or sum, qty: becomes the qty setting, and
//// a record's text shape orders its stored fields, with each position that
//// holds no field kept as a field named by its number and a dot ("2.").

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
            "a path has at most one dot: to reach further, give the step its own field first",
          )
        _ -> {
          use #(n, sc) <- result.try(any_name(adv(sc, 1)))
          path_rest(sc, [n, ..acc])
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

/// What follows 'calc:': a term, a calculation with one operator kind, or a
/// quotient of exactly two terms.
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

/// A comparison, with any number of spaces around it.
fn op(sc: Scan) -> Option(#(String, Scan)) {
  let sc2 = skip_spaces(sc)
  case list.find(["<=", ">=", "=", "<", ">"], fn(o) { at(sc2, o) }) {
    Error(_) -> None
    Ok(o) -> Some(#(o, skip_spaces(adv(sc2, string.length(o)))))
  }
}

// ---------------------------------------------------------------- conditions

fn clause(sc: Scan) -> R(Clause) {
  use #(p, sc2) <- result.try(path(sc))
  case op(sc2) {
    None ->
      err(
        sc,
        "expected a condition: a path, a comparison (= < <= > >=) and a value",
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
  case has_sym(sc, "&"), has_sym(sc, "|") {
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

// ---------------------------------------------------------------- items

/// One named item after a line's type: 'name: value'.
type LineItem {
  ICalc(Value)
  ICount(List(String))
  ISum(List(String))
  IFilter(String)
  IIf(Block)
  IFrom(List(String))
  IQty(Value)
  IValue(Value)
  IPlaces(Value)
  IMod(Value)
  IUnique(Bool)
  IRound(String)
}

pub const item_names = [
  "from", "calc", "count", "sum", "filter", "if", "qty", "value", "places",
  "mod", "unique", "round",
]

/// The items of a line, joined by commas.
fn line_items(
  sc: Scan,
  acc: List(#(String, LineItem)),
) -> R(List(#(String, LineItem))) {
  let #(word, after) = take_while(sc, is_lower_name_char)
  case list.contains(item_names, word) && at(after, ":") {
    False ->
      err(
        sc,
        "expected an item, 'name: value', named one of "
          <> string.join(item_names, " "),
      )
    True -> {
      let sc2 = adv(after, 1)
      use sc3 <- result.try(case gap(sc2) {
        Some(s) -> Ok(s)
        None -> err(sc2, "expected a space after '" <> word <> ":'")
      })
      use #(it, sc4) <- result.try(item_value(sc3, word))
      let acc = [#(word, it), ..acc]
      // a comma straight after the item, then one or more spaces
      case at(sc4, ","), gap(adv(sc4, 1)) {
        True, Some(sc5) -> line_items(sc5, acc)
        True, None -> err(adv(sc4, 1), "expected a space after ','")
        False, _ -> Ok(#(list.reverse(acc), sc4))
      }
    }
  }
}

fn item_value(sc: Scan, word: String) -> R(LineItem) {
  case word {
    "calc" -> result.map(calculation(sc), fn(r) { #(ICalc(r.0), r.1) })
    "count" -> result.map(path(sc), fn(r) { #(ICount(r.0), r.1) })
    "sum" -> result.map(path(sc), fn(r) { #(ISum(r.0), r.1) })
    "filter" ->
      result.map(type_name(sc, "a type name (the filter's refinement)"), fn(r) {
        #(IFilter(r.0), r.1)
      })
    "round" ->
      result.map(type_name(sc, "a rounding rule's type name"), fn(r) {
        #(IRound(r.0), r.1)
      })
    "if" -> result.map(block(sc), fn(r) { #(IIf(r.0), r.1) })
    "from" -> {
      use #(a, sc) <- result.try(field_name(sc, "an input field"))
      case sym(sc, "&") {
        Some(sc2) -> {
          use #(b, sc3) <- result.try(field_name(sc2, "a second input field"))
          case has_sym(sc3, "&") {
            True -> err(sc3, "a mapping has one or two inputs")
            False -> Ok(#(IFrom([a, b]), sc3))
          }
        }
        None -> Ok(#(IFrom([a]), sc))
      }
    }
    "qty" -> {
      use #(v, sc2) <- result.try(value(sc))
      case v {
        VNum(_) | VRange(..) -> Ok(#(IQty(v), sc2))
        _ -> err(sc, "qty: takes a number or a range, e.g. qty: 2 or qty: 1..")
      }
    }
    "value" -> {
      use #(v, sc2) <- result.try(value(sc))
      choices(sc2, [v])
    }
    "places" -> result.map(natural(sc), fn(r) { #(IPlaces(VNum(r.0)), r.1) })
    "mod" -> result.map(natural(sc), fn(r) { #(IMod(VNum(r.0)), r.1) })
    _ -> {
      let #(w, sc2) = take_while(sc, is_name_char)
      case w {
        "True" -> Ok(#(IUnique(True), sc2))
        "False" -> Ok(#(IUnique(False), sc2))
        _ -> err(sc, "unique: names True or False")
      }
    }
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

/// 'value: 10 | 30 | 60': a choice of values.
fn choices(sc: Scan, acc: List(Value)) -> R(LineItem) {
  case sym(sc, "|") {
    Some(sc2) -> {
      use #(v, sc3) <- result.try(value(sc2))
      choices(sc3, [v, ..acc])
    }
    None -> Ok(#(IValue(multi(acc)), sc))
  }
}

/// Optional ' items', then the line end.
fn line_tail(sc: Scan) -> R(#(List(#(String, LineItem)), String)) {
  let #(spaces, sc2) = take_while(sc, fn(c) { c == " " })
  case spaces != "" && peek(sc2) != "#" && !done(sc2) {
    True -> {
      use #(its, sc3) <- result.try(line_items(sc2, []))
      use #(c, sc4) <- result.try(line_end(sc3))
      Ok(#(#(its, c), sc4))
    }
    False -> {
      use #(c, sc3) <- result.try(line_end(sc))
      Ok(#(#([], c), sc3))
    }
  }
}

fn first_duplicate(names: List(String)) -> Option(String) {
  case names {
    [] -> None
    [n, ..rest] ->
      case list.contains(rest, n) {
        True -> Some(n)
        False -> first_duplicate(rest)
      }
  }
}

fn ok_unless(cond: Bool, sc: Scan, msg: String) -> Result(Nil, MapError) {
  case cond {
    True -> err(sc, msg)
    False -> Ok(Nil)
  }
}

/// A line's items as the model's block: qty first, then the line's own
/// value ('val'), then the other restrictions, then its conditions.
fn assemble(
  sc: Scan,
  its: List(#(String, LineItem)),
) -> Result(Block, MapError) {
  let names = list.map(its, fn(p) { p.0 })
  let has = fn(n) { list.contains(names, n) }
  use _ <- result.try(case first_duplicate(names) {
    Some(n) -> err(sc, "the item '" <> n <> ":' appears twice on this line")
    None -> Ok(Nil)
  })
  use _ <- result.try(ok_unless(
    list.count(names, fn(n) { list.contains(["calc", "count", "sum", "if"], n) })
      > 1,
    sc,
    "a line takes at most one of calc:, count:, sum: and if:",
  ))
  use _ <- result.try(ok_unless(
    has("filter") && !has("count") && !has("sum"),
    sc,
    "filter: goes beside count: or sum:",
  ))
  use _ <- result.try(ok_unless(
    has("round") && !has("calc"),
    sc,
    "round: goes beside calc:, to round its calculation",
  ))
  let filter =
    list.find_map(its, fn(p) {
      case p.1 {
        IFilter(t) -> Ok([t])
        _ -> Error(Nil)
      }
    })
    |> result.unwrap([])
  use clauses <- result.try(
    list.try_map(its, fn(p) { item_clauses(sc, p.1, filter, has("round")) }),
  )
  let clauses = list.flatten(clauses)
  let #(qty, rest) =
    list.partition(clauses, fn(c) {
      case c {
        Setting("qty", _) -> True
        _ -> False
      }
    })
  let conditions =
    list.find_map(its, fn(p) {
      case p.1 {
        IIf(b) -> Ok(b)
        _ -> Error(Nil)
      }
    })
  case conditions {
    Ok(Block(OrConn, [_, _, ..] as ors)) ->
      case qty, rest {
        [], [] -> Ok(Block(OrConn, ors))
        _, _ ->
          err(
            sc,
            "conditions joined by '|' take no other items: name the choice as its own field",
          )
      }
    Ok(b) -> Ok(Block(AndConn, list.flatten([qty, rest, b.clauses])))
    Error(_) -> Ok(Block(AndConn, list.append(qty, rest)))
  }
}

fn item_clauses(
  sc: Scan,
  it: LineItem,
  filter: List(String),
  rounded: Bool,
) -> Result(List(Clause), MapError) {
  case it {
    ICalc(VArith("/", _)) if !rounded ->
      err(
        sc,
        "a quotient names its rounding rule, e.g. calc: total / 3, places: 2, round: Half_Even",
      )
    ICalc(v) -> Ok([Plain(["val"], "=", v)])
    ICount(p) ->
      Ok([Plain(["val"], "=", VPath(list.flatten([p, filter, ["qty"]])))])
    ISum([list_name, field]) ->
      Ok([
        Plain(
          ["val"],
          "=",
          VPath(list.flatten([[list_name], filter, [field, "sum"]])),
        ),
      ])
    ISum(_) ->
      err(
        sc,
        "sum: names a list and one field of its items, e.g. sum: lines.amount",
      )
    IQty(v) -> Ok([Setting("qty", v)])
    IValue(v) -> Ok([Plain(["val"], "=", v)])
    IPlaces(v) -> Ok([Setting("places", v)])
    IMod(v) -> Ok([Setting("mod", v)])
    IUnique(True) -> Ok([Flag("unique")])
    IRound(rule) -> Ok([Setting("round", VPath([rule]))])
    IUnique(False) | IFilter(_) | IIf(_) | IFrom(_) -> Ok([])
  }
}

// ---------------------------------------------------------------- boxes

type Box {
  EmptyBox
  ItemsBox(List(Item))
  InterBox(List(Item))
}

/// A type in braces: {}, {A}, {A | "b" | 5} or {A & B}. Braces hold only a type.
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
      case counted, its, has_sym(sc2, "&") {
        True, _, _ ->
          err(
            sc2,
            "braces hold only a type: a list's count is an item, e.g. {Digit} qty: 2",
          )
        False, [TypeItem(_) as first], True -> {
          use #(more, sc3) <- result.try(inter_rest(sc2, [first]))
          use sc4 <- result.try(eat(sc3, "}"))
          Ok(#(InterBox(more), sc4))
        }
        False, _, _ -> {
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

fn no_items(
  sc: Scan,
  its: List(#(String, LineItem)),
  what: String,
) -> Result(Nil, MapError) {
  case its {
    [] -> Ok(Nil)
    _ -> err(sc, what <> " takes no items")
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
          let docs = list.reverse(doc) |> string.join(" ")
          let d =
            Decl(name, model.Union, n, file, [], model.empty, [], [], "", docs)
          use #(#(its, c), _) <- result.try(line_tail(sc))
          use _ <- result.try(ok_unless(
            list.any(its, fn(p) { p.0 == "from" }),
            sc,
            "from: belongs to a mapping, which is a field of a record",
          ))
          case bx {
            EmptyBox -> {
              use _ <- result.try(no_items(sc, its, "a record line"))
              use #(fields, rest2, n2) <- result.try(
                record_body(rest, n + 1, file, [], []),
              )
              use fields <- result.try(with_shape(fields, file))
              let d = Decl(..d, kind: model.Record, comment: c, fields: fields)
              read_lines(rest2, n2, file, [], [DeclEntry(d), ..acc])
            }
            InterBox(its2) -> {
              use _ <- result.try(no_items(sc, its, "an intersection"))
              let d =
                Decl(..d, kind: model.Intersection, items: its2, comment: c)
              read_lines(rest, n + 1, file, [], [DeclEntry(d), ..acc])
            }
            ItemsBox([one]) -> {
              use b <- result.try(assemble(sc, its))
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
            ItemsBox(its2) -> {
              use _ <- result.try(no_items(
                sc,
                its,
                "a union (to restrict it, name it and refine the name)",
              ))
              let d = Decl(..d, kind: model.Union, items: its2, comment: c)
              read_lines(rest, n + 1, file, [], [DeclEntry(d), ..acc])
            }
          }
        }
      }
    }
  }
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

fn position(s: String, line: Int, file: String) -> Result(Position, MapError) {
  let sc = Scan(s, 0, line, file)
  use #(num, sc) <- result.try(position_number(sc, "  "))
  use #(bx, sc) <- result.try(box(sc))
  use #(#(its, _), _) <- result.try(line_tail(sc))
  case bx {
    ItemsBox([one]) -> {
      use b <- result.try(assemble(sc, its))
      Ok(Position(num, [one], b, line))
    }
    ItemsBox(its2) -> {
      use _ <- result.try(no_items(sc, its, "a union position"))
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
  FieldPosition(number: Int, field: String, line: Int)
  TypePosition(number: Int, item: Item, preds: Block, line: Int)
}

type Shape {
  Shape(positions: List(ShapePosition), line: Int)
}

fn record_body(
  lines: List(String),
  n: Int,
  file: String,
  acc: List(Field),
  shapes: List(Shape),
) -> Result(#(#(List(Field), List(Shape)), List(String), Int), MapError) {
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
              use #(_, _) <- result.try(line_end(sc))
              shape_positions(rest, n + 1, file, [
                FieldPosition(num, f, n),
                ..acc
              ])
            }
            False -> {
              use #(bx, sc) <- result.try(box(sc))
              use #(#(its, _), _) <- result.try(line_tail(sc))
              case bx {
                ItemsBox([one]) -> {
                  use _ <- result.try(ok_unless(
                    list.any(its, fn(p) { p.0 != "qty" }),
                    sc,
                    "a position of a text shape takes only qty:",
                  ))
                  use b <- result.try(assemble(sc, its))
                  shape_positions(rest, n + 1, file, [
                    TypePosition(num, one, b, n),
                    ..acc
                  ])
                }
                _ ->
                  err(
                    sc,
                    "a position of a text shape holds one field, type or literal",
                  )
              }
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

/// Order a record's fields by its text shape: the stored fields and the
/// positions that hold no field, in position order, then the other fields as
/// written. A record with no shape keeps its stored fields in order.
fn with_shape(
  parts: #(List(Field), List(Shape)),
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
            FieldPosition(num, _, l)
              | TypePosition(num, _, _, l)
              if num != expect
            ->
              Error(MapError(
                "positions are numbered 1, 2, 3 in order: expected "
                  <> int.to_string(expect),
                file,
                l,
                5,
              ))
            FieldPosition(_, name, l) ->
              case list.find(fields, fn(f) { f.name == name }) {
                Error(_) ->
                  Error(MapError(
                    "the text shape names '"
                      <> name
                      <> "', which is not a field of this record",
                    file,
                    l,
                    5,
                  ))
                Ok(f) ->
                  case model.is_stored(f) {
                    True -> Ok(f)
                    False ->
                      Error(MapError(
                        "'"
                          <> name
                          <> "' is computed, so it has no text: a shape names stored fields",
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
/// the folds), so no field may take them in this build.
const host_names = ["val", "qty", "sum"]

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
  use _ <- result.try(ok_unless(
    list.contains(host_names, name),
    Scan(..sc, i: 2),
    "'"
      <> name
      <> "' cannot name a field in this build: the checker still uses it",
  ))
  use sc <- result.try(spaces_then(sc))
  use #(bx, sc) <- result.try(box(sc))
  use #(#(its, c), _) <- result.try(line_tail(sc))
  let f = Field(name, [], model.empty, None, line, "", model.Stored)
  let inputs =
    list.find_map(its, fn(p) {
      case p.1 {
        IFrom(ins) -> Ok(ins)
        _ -> Error(Nil)
      }
    })
  case bx, inputs {
    EmptyBox, _ -> err(sc, "a field needs a type")
    InterBox(_), _ ->
      err(sc, "an intersection is a top-level line: name it, then use the name")
    ItemsBox(outs), Ok(ins) -> {
      use _ <- result.try(ok_unless(
        list.length(its) > 1,
        sc,
        "from: is the only item on its line",
      ))
      use #(cases, rest2, n2) <- result.try(
        read_cases(rest, line + 1, file, []),
      )
      case cases {
        [] ->
          Error(MapError(
            "the mapping '"
              <> name
              <> "' needs case lines, '    {output} if: conditions'",
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
              mapping: Some(Mapping(ins, outs, cases)),
            )
          Ok(#(Field(..f, role: model.classify(f)), rest2, n2))
        }
      }
    }
    ItemsBox([one]), Error(_) -> {
      use _ <- result.try(ok_unless(
        one == TypeItem("Claim") && list.any(its, fn(p) { p.0 != "if" }),
        sc,
        "a claim has one item, if:",
      ))
      use _ <- result.try(case one, its {
        StrItem(_), [] | NumItem(..), [] ->
          err(
            sc,
            "this field can hold only one text, so it holds no data: put the text in the record's text shape",
          )
        _, _ -> Ok(Nil)
      })
      use b <- result.try(assemble(sc, its))
      let f = Field(..f, items: [one], preds: b, comment: c)
      Ok(#(Field(..f, role: model.classify(f)), rest, line + 1))
    }
    ItemsBox(outs), Error(_) -> {
      use _ <- result.try(no_items(
        sc,
        its,
        "a union field (to restrict it, name the union as a type first)",
      ))
      let f = Field(..f, items: outs, comment: c)
      Ok(#(Field(..f, role: model.classify(f)), rest, line + 1))
    }
  }
}

/// '    {output} if: conditions', the cases under a mapping.
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
          use sc <- result.try(eat(sc, "    "))
          use #(bx, sc) <- result.try(box(sc))
          case bx {
            ItemsBox([out]) -> {
              use sc <- result.try(spaces_then(sc))
              use sc <- result.try(eat(sc, "if:"))
              use sc <- result.try(spaces_then(sc))
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
