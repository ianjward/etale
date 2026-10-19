//// Evaluation: the values of texts, computed fields, rules, mappings and folds.
////
//// Every field evaluates to a value or to INVALID; anything computed from INVALID
//// is INVALID; a record with any INVALID field is rejected and every failed rule
//// is reported by name (Step 3). Fields are evaluated lazily, each at most once
//// (Step 8), and mappings follow Step 8's candidate-set procedure exactly.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import gleam/string
import sheaf/decimal.{type Decimal}
import sheaf/grammar.{
  type Cell, type Check, type Store, CheckPosition, CheckRecord, CheckRefine,
  CheckUnique,
}
import sheaf/model.{
  type Block, type Clause, type Decl, type Field, type Item, type Value, AndConn,
  NumItem, OrConn, Plain, StrItem, TypeItem, VArith, VMulti, VNum, VPath, VRange,
  VStr,
}
import sheaf/node.{type Node, NAlt, NRec, NSeq}

pub type Val {
  VNumber(Decimal)
  VText(String)
  VRecord(Rec)
  VSeqv(items: List(Val), hi: Option(Int), elem: Option(String))
  VInvalid
  /// Not known yet: the value reaches a record around this one (a path that
  /// starts with a type name), and the text is still being read. Such fields
  /// are worked out by 'settle' once the whole tree exists.
  VLater
}

pub type Rec {
  Rec(
    decl: Decl,
    node: Node,
    text: String,
    cache: Store(String, Val),
    busy: Store(String, Bool),
    failures: Cell(List(String)),
    trace: Cell(List(Trace)),
  )
}

pub type Trace {
  Trace(
    field: String,
    role: String,
    value: String,
    deps: List(String),
    detail: String,
  )
}

/// 'ctx' is the chain of records around the one being evaluated, innermost
/// first; 'after' is True once the whole text has been read.
pub type Ev {
  Ev(decls: Dict(String, Decl), ctx: List(Rec), after: Bool)
}

pub fn new(decls: Dict(String, Decl)) -> Ev {
  Ev(decls, [], False)
}

type Tri {
  Yes
  No
  Inv
  Later
}

@external(javascript, "./ffi.mjs", "same_ref")
fn same_ref(a: a, b: a) -> Bool

type Rhs {
  RVal(Val)
  RRange(low: Option(Decimal), high: Option(Decimal))
}

@external(javascript, "./ffi.mjs", "slice")
fn slice(s: String, a: Int, b: Int) -> String

@external(javascript, "./ffi.mjs", "node_rec_get")
fn node_rec_get(n: Node) -> Result(Rec, Nil)

@external(javascript, "./ffi.mjs", "node_rec_set")
fn node_rec_set(n: Node, r: Rec) -> Nil

/// The record for a parse node, made once and shared: every parent candidate
/// that contains this node reads the same cached field values.
pub fn rec_of(decl: Decl, n: Node, text: String) -> Rec {
  case node_rec_get(n) {
    Ok(r) -> r
    Error(_) -> {
      let r = new_rec(decl, n, text)
      node_rec_set(n, r)
      r
    }
  }
}

pub fn new_rec(decl: Decl, n: Node, text: String) -> Rec {
  Rec(
    decl,
    n,
    text,
    grammar.store_new(),
    grammar.store_new(),
    grammar.cell([]),
    grammar.cell([]),
  )
}

pub fn failures(r: Rec) -> List(String) {
  list.reverse(grammar.read(r.failures)) |> list.unique
}

pub fn trace(r: Rec) -> List(Trace) {
  list.reverse(grammar.read(r.trace))
}

fn fail(r: Rec, msg: String) -> Nil {
  grammar.write(r.failures, [msg, ..grammar.read(r.failures)])
}

fn note(r: Rec, t: Trace) -> Nil {
  grammar.write(r.trace, [t, ..grammar.read(r.trace)])
}

// ---------------------------------------------------------------- showing values

pub fn show(v: Val) -> String {
  case v {
    VInvalid -> "INVALID"
    VLater -> "(not known yet)"
    VNumber(d) -> decimal.to_string(d)
    VText("TRUE") -> "TRUE"
    VText("FALSE") -> "FALSE"
    VText(s) -> model.quote(s)
    VRecord(r) -> r.decl.name <> "{…}"
    VSeqv(items, _, _) -> "[" <> int.to_string(list.length(items)) <> " items]"
  }
}

// ---------------------------------------------------------------- types

pub fn is_numeric(ev: Ev, name: String) -> Bool {
  numeric_loop(ev, name, set.new())
}

fn numeric_loop(ev: Ev, name: String, seen) -> Bool {
  case
    list.contains(model.builtin_numeric, name)
    || list.contains(model.literal_numeric, name)
  {
    True -> True
    False ->
      case set.contains(seen, name), dict.get(ev.decls, name) {
        True, _ -> False
        _, Error(_) -> False
        _, Ok(d) -> {
          let seen = set.insert(seen, name)
          let num_item = fn(i: Item) {
            case i {
              NumItem(..) -> True
              TypeItem(n) -> numeric_loop(ev, n, seen)
              StrItem(_) -> False
            }
          }
          case d.kind {
            model.Union -> list.all(d.items, num_item)
            model.Refine | model.Intersection -> num_item(model.decl_base(d))
            model.Layout ->
              case model.decl_base(d) {
                TypeItem(b) -> list.contains(model.builtin_numeric, b)
                _ -> False
              }
            model.Record -> False
          }
        }
      }
  }
}

pub fn items_numeric(ev: Ev, items: List(Item)) -> Bool {
  list.all(items, fn(i) {
    case i {
      NumItem(..) -> True
      TypeItem(n) -> is_numeric(ev, n)
      StrItem(_) -> False
    }
  })
}

/// The value of a type with exactly one inhabitant, e.g. True -> "TRUE".
pub fn singleton(ev: Ev, name: String) -> Option(Val) {
  singleton_loop(ev, name, set.new())
}

fn singleton_loop(ev: Ev, name: String, seen) -> Option(Val) {
  case set.contains(seen, name), dict.get(ev.decls, name) {
    True, _ -> None
    _, Error(_) -> None
    _, Ok(d) ->
      case d.kind, d.items, d.preds.clauses {
        model.Union, [i], [] | model.Refine, [i], [] ->
          case i {
            StrItem(s) -> Some(VText(s))
            NumItem(v, _) -> Some(VNumber(v))
            TypeItem(n) -> singleton_loop(ev, n, set.insert(seen, name))
          }
        _, _, _ -> None
      }
  }
}

pub fn item_value(ev: Ev, it: Item) -> Option(Val) {
  case it {
    StrItem(s) -> Some(VText(s))
    NumItem(v, _) -> Some(VNumber(v))
    TypeItem(n) -> singleton(ev, n)
  }
}

/// All values of a finite union (literals and singletons), or None.
pub fn finite_values(ev: Ev, items: List(Item)) -> Option(List(Val)) {
  finite_loop(ev, items, set.new())
  |> option.map(fn(vs) { dedupe(vs) })
}

fn dedupe(vs: List(Val)) -> List(Val) {
  list.fold(vs, [], fn(acc, v) {
    case list.any(acc, fn(x) { same(x, v) }) {
      True -> acc
      False -> list.append(acc, [v])
    }
  })
}

fn finite_loop(ev: Ev, items: List(Item), seen) -> Option(List(Val)) {
  list.try_fold(items, [], fn(acc, it) {
    case it {
      StrItem(s) -> Ok(list.append(acc, [VText(s)]))
      NumItem(v, _) -> Ok(list.append(acc, [VNumber(v)]))
      TypeItem(n) ->
        case singleton(ev, n) {
          Some(v) -> Ok(list.append(acc, [v]))
          None ->
            case set.contains(seen, n), dict.get(ev.decls, n) {
              False, Ok(d) ->
                case d.kind, d.preds.clauses {
                  model.Union, _ | model.Refine, [] ->
                    case finite_loop(ev, d.items, set.insert(seen, n)) {
                      Some(sub) -> Ok(list.append(acc, sub))
                      None -> Error(Nil)
                    }
                  _, _ -> Error(Nil)
                }
              _, _ -> Error(Nil)
            }
        }
    }
  })
  |> option.from_result
}

// ---------------------------------------------------------------- node values

fn number(t: String) -> Val {
  case decimal.parse(t) {
    Ok(d) -> VNumber(d)
    Error(_) -> VInvalid
  }
}

pub fn value(
  ev: Ev,
  n: Node,
  text: String,
  items: Option(List(Item)),
  hi: Option(Int),
) -> Val {
  case n.kind, n.t {
    NSeq(_), Some(_) -> VText(slice(text, n.s, n.e))
    NSeq(_), None -> {
      let kids = node.items(n)
      let elem = case items {
        Some([TypeItem(t)]) ->
          case dict.get(ev.decls, t) {
            Ok(_) -> Some(t)
            Error(_) -> None
          }
        _ -> None
      }
      VSeqv(list.map(kids, fn(k) { value(ev, k, text, items, None) }), hi, elem)
    }
    _, _ -> {
      let #(chain, inner) = chain_of(n, [])
      case inner.kind, inner.t {
        NRec(_), Some(t) -> {
          let assert Ok(d) = dict.get(ev.decls, t)
          VRecord(rec_of(d, inner, text))
        }
        _, _ -> {
          let found =
            list.find_map(chain, fn(t) {
              case dict.get(ev.decls, t) {
                Ok(d) ->
                  case d.kind, model.decl_base(d) {
                    model.Layout, TypeItem(b) ->
                      case list.contains(model.builtin_numeric, b) {
                        True -> Ok(conversion(d, inner, text))
                        False -> numeric_text(ev, t, n, text)
                      }
                    _, _ -> numeric_text(ev, t, n, text)
                  }
                Error(_) -> numeric_text(ev, t, n, text)
              }
            })
          case found {
            Ok(v) -> v
            Error(_) ->
              case items {
                Some(its) ->
                  case items_numeric(ev, its) {
                    True -> number(slice(text, n.s, n.e))
                    False -> VText(slice(text, n.s, n.e))
                  }
                None -> VText(slice(text, n.s, n.e))
              }
          }
        }
      }
    }
  }
}

fn numeric_text(ev: Ev, t: String, n: Node, text: String) -> Result(Val, Nil) {
  case is_numeric(ev, t) {
    True -> Ok(number(slice(text, n.s, n.e)))
    False -> Error(Nil)
  }
}

fn chain_of(n: Node, acc: List(String)) -> #(List(String), Node) {
  let acc = case n.t {
    Some(t) -> list.append(acc, [t])
    None -> acc
  }
  case n.kind {
    NAlt(c) -> chain_of(c, acc)
    _ -> #(acc, n)
  }
}

/// A layout whose base is Integer or Decimal reads its Digit positions in base
/// 10; literal positions contribute nothing (Step 3).
fn conversion(d: Decl, n: Node, text: String) -> Val {
  let digits =
    list.map(d.positions, fn(p) {
      case
        list.all(p.items, fn(i) {
          case i {
            StrItem(_) -> True
            _ -> False
          }
        })
      {
        True -> ""
        False ->
          case node.kid(n, int.to_string(p.number)) {
            Ok(k) ->
              slice(text, k.s, k.e)
              |> string.to_graphemes
              |> list.filter(fn(c) { string.contains("0123456789", c) })
              |> string.concat
            Error(_) -> ""
          }
      }
    })
    |> string.concat
  let v = case digits {
    "" -> decimal.zero()
    _ ->
      case decimal.parse(strip_zeros(digits)) {
        Ok(x) -> x
        Error(_) -> decimal.zero()
      }
  }
  // a "-" position that is present makes the number negative (Step 3)
  let negative =
    list.any(d.positions, fn(p) {
      p.items == [StrItem("-")]
      && case node.kid(n, int.to_string(p.number)) {
        Ok(k) -> k.e > k.s
        Error(_) -> False
      }
    })
  case negative {
    True -> VNumber(decimal.negate(v))
    False -> VNumber(v)
  }
}

fn strip_zeros(s: String) -> String {
  case s {
    "0" <> rest if rest != "" -> strip_zeros(rest)
    _ -> s
  }
}

// ---------------------------------------------------------------- fields

pub fn get(ev: Ev, r: Rec, name: String) -> Val {
  case grammar.store_get(r.cache, name) {
    Ok(v) -> v
    Error(_) ->
      case model.field(r.decl, name), grammar.store_get(r.busy, name) {
        None, _ -> VInvalid
        _, Ok(True) -> VInvalid
        Some(f), _ -> {
          grammar.store_set(r.busy, name, True)
          let inner = case ev.ctx {
            [top, ..] ->
              case same_ref(top, r) {
                True -> ev
                False -> Ev(..ev, ctx: [r, ..ev.ctx])
              }
            [] -> Ev(..ev, ctx: [r])
          }
          let v = field_value(inner, r, f)
          case v {
            VLater -> grammar.store_set(r.busy, name, False)
            _ -> grammar.store_set(r.cache, name, v)
          }
          v
        }
      }
  }
}

pub fn evaluate_all(ev: Ev, r: Rec) -> Bool {
  list.fold(r.decl.fields, True, fn(ok, f) {
    case get(ev, r, f.name) {
      VInvalid -> False
      _ -> ok
    }
  })
}

/// After the text is read: work out the fields that reach a record around
/// their own, now that every record has the chain of records holding it.
pub fn settle(ev: Ev, v: Val) -> Nil {
  settle_loop(Ev(..ev, ctx: [], after: True), v)
}

fn settle_loop(ev: Ev, v: Val) -> Nil {
  case v {
    VRecord(r) -> {
      evaluate_all(ev, r)
      let inner = Ev(..ev, ctx: [r, ..ev.ctx])
      list.each(r.decl.fields, fn(f) {
        case model.is_stored(f) {
          True -> settle_loop(inner, get(inner, r, f.name))
          False -> Nil
        }
      })
    }
    VSeqv(xs, _, _) -> list.each(xs, fn(x) { settle_loop(ev, x) })
    _ -> Nil
  }
}

pub fn stored_text(r: Rec, name: String) -> String {
  case node.kid(r.node, name) {
    Ok(k) -> slice(r.text, k.s, k.e)
    Error(_) -> ""
  }
}

fn field_value(ev: Ev, r: Rec, f: Field) -> Val {
  case f.role {
    model.Stored -> stored_value(ev, r, f)
    model.Constant -> {
      note(r, Trace(f.name, "constant", "TRUE", [], ""))
      VText("TRUE")
    }
    model.Claim ->
      // A claim was proved for every value, so it narrows nothing. It is
      // still evaluated here: if it ever fails, the proof was wrong, and the
      // text is refused rather than shown with a false TRUE.
      case eval_block(ev, Some(r), f.preds, VInvalid) {
        Later -> VLater
        No -> {
          fail(
            r,
            f.name
              <> ": "
              <> model.block_text(f.preds)
              <> " was proved but is false here (a checker bug; please report it)",
          )
          note(
            r,
            Trace(
              f.name,
              "claim",
              "INVALID",
              deps(f.preds),
              "proved, but false here: " <> model.block_text(f.preds),
            ),
          )
          VInvalid
        }
        _ -> {
          note(
            r,
            Trace(
              f.name,
              "claim",
              "TRUE",
              deps(f.preds),
              "proved for every value: " <> model.block_text(f.preds),
            ),
          )
          VText("TRUE")
        }
      }
    model.Rule -> {
      let ds = deps(f.preds)
      case eval_block(ev, Some(r), f.preds, VInvalid) {
        Yes -> {
          note(r, Trace(f.name, "rule", "TRUE", ds, model.block_text(f.preds)))
          VText("TRUE")
        }
        Later -> VLater
        res -> {
          let extra = case res {
            Inv -> " (an input is INVALID)"
            _ -> ""
          }
          fail(r, f.name <> ": " <> model.block_text(f.preds) <> extra)
          note(
            r,
            Trace(
              f.name,
              "rule",
              "INVALID",
              ds,
              "failed: " <> model.block_text(f.preds),
            ),
          )
          VInvalid
        }
      }
    }
    model.Computed -> {
      let assert Some(def) = model.definition(f)
      let v = case eval_value(ev, Some(r), def, VInvalid) {
        RVal(v) -> v
        RRange(..) -> VInvalid
      }
      use <- later_first(v)
      let v = case v, model.setting(f.preds, "mod") {
        VNumber(x), Some(m) ->
          case eval_value(ev, Some(r), m, VInvalid) {
            RVal(VNumber(mv)) ->
              case decimal.is_zero(mv) {
                True -> v
                False -> VNumber(decimal.modulo(x, mv))
              }
            _ -> v
          }
        _, _ -> v
      }
      constrain(ev, r, f, v, "computed")
    }
    model.MappingRole -> eval_mapping(ev, r, f)
  }
}

fn later_first(v: Val, then: fn() -> Val) -> Val {
  case v {
    VLater -> VLater
    _ -> then()
  }
}

fn stored_value(ev: Ev, r: Rec, f: Field) -> Val {
  case node.kid(r.node, f.name) {
    Error(_) -> VInvalid
    Ok(k) -> {
      let hi = case model.qty(f) {
        Some(#(_, Some(h))) -> Some(decimal.to_int(h.value))
        _ -> None
      }
      let v = value(ev, k, r.text, Some(f.items), hi)
      let places_bad = case v, model.field_places(ev.decls, f) {
        VNumber(_), Some(VNum(pl)) -> {
          let txt = slice(r.text, k.s, k.e)
          let got = case string.split_once(txt, ".") {
            Ok(#(_, frac)) -> string.length(frac)
            Error(_) -> 0
          }
          case got == decimal.to_int(pl.value) {
            True -> None
            False -> Some(#(pl.text, txt, got))
          }
        }
        _, _ -> None
      }
      case places_bad {
        Some(#(pl, txt, got)) -> {
          fail(
            r,
            f.name
              <> ": places = "
              <> pl
              <> " (value "
              <> txt
              <> " has "
              <> int.to_string(got)
              <> ")",
          )
          note(
            r,
            Trace(f.name, "stored", "INVALID", [], "failed: places = " <> pl),
          )
          VInvalid
        }
        None -> {
          let violation = case v, model.base(f), model.qty(f) {
            VInvalid, _, _ -> ""
            _, TypeItem(t), None -> type_violation(ev, t, v)
            _, _, _ -> ""
          }
          case violation {
            "" -> constrain(ev, r, f, v, "stored")
            bad -> {
              fail(r, f.name <> ": " <> bad <> " (value " <> show(v) <> ")")
              note(r, Trace(f.name, "stored", "INVALID", [], "failed: " <> bad))
              VInvalid
            }
          }
        }
      }
    }
  }
}

/// For values read without rule enforcement: the first type-level predicate they break.
pub fn type_violation(ev: Ev, name: String, v: Val) -> String {
  violation_loop(ev, name, v, set.new())
}

fn violation_loop(ev: Ev, name: String, v: Val, seen) -> String {
  case set.contains(seen, name), dict.get(ev.decls, name) {
    False, Ok(d) ->
      case d.kind {
        model.Refine | model.Layout -> {
          let broken = case model.plains(d.preds), v {
            [], _ -> False
            _, VRecord(_) -> False
            _, _ ->
              case eval_block(ev, None, d.preds, v) {
                No | Inv -> True
                _ -> False
              }
          }
          case broken, model.decl_base(d) {
            True, _ -> name <> " requires " <> model.block_text(d.preds)
            False, TypeItem(b) ->
              violation_loop(ev, b, v, set.insert(seen, name))
            False, _ -> ""
          }
        }
        _ -> ""
      }
    _, _ -> ""
  }
}

fn constrain(ev: Ev, r: Rec, f: Field, v: Val, role: String) -> Val {
  let ds = deps(f.preds)
  case v {
    VLater -> VLater
    VInvalid -> {
      note(r, Trace(f.name, role, "INVALID", ds, ""))
      VInvalid
    }
    _ -> {
      let checks = case f.preds.conn {
        AndConn ->
          list.map(model.constraints(f), fn(c) {
            #(model.clause_text(c), eval_plain(ev, Some(r), c, v))
          })
        OrConn ->
          case model.plains(f.preds) {
            [] -> []
            _ -> [
              #(model.block_text(f.preds), eval_block(ev, Some(r), f.preds, v)),
            ]
          }
      }
      let later = list.any(checks, fn(c) { c.1 == Later })
      case list.find(checks, fn(c) { c.1 == No || c.1 == Inv }), later {
        Error(_), True -> VLater
        Ok(#(txt, _)), _ -> {
          fail(r, f.name <> ": " <> txt <> " (value " <> show(v) <> ")")
          note(
            r,
            Trace(
              f.name,
              role,
              "INVALID",
              ds,
              "failed: " <> txt <> " with val = " <> show(v),
            ),
          )
          VInvalid
        }
        Error(_), False -> {
          let detail = case role, model.definition(f) {
            "computed", Some(d) -> "val = " <> model.value_text(d)
            _, _ -> ""
          }
          note(r, Trace(f.name, role, show(v), ds, detail))
          v
        }
      }
    }
  }
}

// ---------------------------------------------------------------- mappings (Step 8)

fn mentions(b: Block, name: String) -> Bool {
  list.any(b.clauses, fn(c) {
    case c {
      Plain([first, ..], _, _) -> first == name
      _ -> False
    }
  })
}

fn eval_mapping(ev: Ev, r: Rec, f: Field) -> Val {
  let assert Some(mp) = f.mapping
  let later = grammar.cell(False)
  let yes = fn(t: Tri) {
    case t {
      Later -> {
        grammar.write(later, True)
        True
      }
      _ -> t == Yes
    }
  }
  let result =
    list.fold_until(mp.inputs, #(mp.cases, [], False), fn(acc, inp) {
      let #(cands, evaluated, _) = acc
      case list.any(cands, fn(c) { mentions(c.preds, inp) }) {
        False -> list.Stop(acc)
        True -> {
          let v = get(ev, r, inp)
          let evaluated = list.append(evaluated, [inp])
          case v {
            VLater -> {
              grammar.write(later, True)
              list.Stop(#(cands, evaluated, False))
            }
            VInvalid -> list.Stop(#(cands, evaluated, True))
            _ -> {
              let keep =
                list.filter(cands, fn(c) {
                  case mentions(c.preds, inp) {
                    False -> True
                    True ->
                      case c.preds.conn {
                        AndConn ->
                          list.all(c.preds.clauses, fn(p) {
                            case p {
                              Plain([first, ..], _, _) if first == inp ->
                                yes(eval_plain(ev, Some(r), p, VInvalid))
                              _ -> True
                            }
                          })
                        OrConn ->
                          yes(eval_block(ev, Some(r), c.preds, VInvalid))
                      }
                  }
                })
              list.Continue(#(keep, evaluated, False))
            }
          }
        }
      }
    })
  let #(cands, evaluated, invalid) = result
  use <- later_first(case grammar.read(later) {
    True -> VLater
    False -> VInvalid
  })
  case invalid {
    True -> {
      note(
        r,
        Trace(f.name, "mapping", "INVALID", mp.inputs, "an input is INVALID"),
      )
      VInvalid
    }
    False ->
      case cands {
        [c] -> {
          let v = option.unwrap(item_value(ev, c.output), VInvalid)
          let skipped =
            list.filter(mp.inputs, fn(i) { !list.contains(evaluated, i) })
          let detail =
            "case {"
            <> model.item_text(c.output)
            <> "} "
            <> model.block_text(c.preds)
            <> case skipped {
              [] -> ""
              _ -> "; never evaluated: " <> string.join(skipped, ", ")
            }
          note(r, Trace(f.name, "mapping", show(v), evaluated, detail))
          v
        }
        _ -> {
          fail(
            r,
            f.name
              <> ": "
              <> int.to_string(list.length(cands))
              <> " cases apply (coverage or disjointness broken)",
          )
          VInvalid
        }
      }
  }
}

// ---------------------------------------------------------------- predicates and values

fn eval_block(ev: Ev, r: Option(Rec), b: Block, cur: Val) -> Tri {
  let ps = model.plains(b)
  case ps {
    [] -> Yes
    _ ->
      case b.conn {
        AndConn -> {
          let rs = list.map(ps, fn(c) { eval_plain(ev, r, c, cur) })
          case
            list.contains(rs, Inv),
            list.contains(rs, No),
            list.contains(rs, Later)
          {
            True, _, _ -> Inv
            _, True, _ -> No
            _, _, True -> Later
            _, _, _ -> Yes
          }
        }
        OrConn -> {
          let rs = list.map(ps, fn(c) { eval_plain(ev, r, c, cur) })
          case
            list.contains(rs, Yes),
            list.contains(rs, Inv),
            list.contains(rs, Later)
          {
            True, _, _ -> Yes
            _, True, _ -> Inv
            _, _, True -> Later
            _, _, _ -> No
          }
        }
      }
  }
}

fn eval_plain(ev: Ev, r: Option(Rec), c: Clause, cur: Val) -> Tri {
  case c {
    Plain(path, op, v) ->
      case eval_path(ev, r, path, cur) {
        VInvalid -> Inv
        VLater -> Later
        left -> {
          let values = case v {
            VMulti(vs) -> vs
            _ -> [v]
          }
          list.fold_until(values, No, fn(_, vv) {
            case eval_value(ev, r, vv, cur) {
              RVal(VInvalid) -> list.Stop(Inv)
              RVal(VLater) -> list.Stop(Later)
              right ->
                case compare(left, op, right) {
                  True -> list.Stop(Yes)
                  False -> list.Continue(No)
                }
            }
          })
        }
      }
    _ -> Yes
  }
}

fn eval_value(ev: Ev, r: Option(Rec), v: Value, cur: Val) -> Rhs {
  case v {
    VNum(n) -> RVal(VNumber(n.value))
    VStr(s) -> RVal(VText(s))
    VRange(lo, hi) ->
      RRange(
        option.map(lo, fn(n) { n.value }),
        option.map(hi, fn(n) { n.value }),
      )
    VPath(parts) -> RVal(eval_path(ev, r, parts, cur))
    VMulti(_) -> RVal(VInvalid)
    VArith(op, terms) -> {
      let rs = list.map(terms, fn(t) { eval_value(ev, r, t, cur) })
      let vals =
        list.map(rs, fn(x) {
          case x {
            RVal(VNumber(d)) -> Ok(d)
            _ -> Error(Nil)
          }
        })
      case result_all(vals), list.contains(rs, RVal(VLater)) {
        Error(_), True -> RVal(VLater)
        res, _ ->
          case res {
            Error(_) -> RVal(VInvalid)
            Ok([first, ..rest]) ->
              RVal(
                VNumber(
                  list.fold(rest, first, fn(acc, x) {
                    case op {
                      "+" -> decimal.add(acc, x)
                      "-" -> decimal.sub(acc, x)
                      _ -> decimal.mul(acc, x)
                    }
                  }),
                ),
              )
            Ok([]) -> RVal(VInvalid)
          }
      }
    }
  }
}

fn result_all(xs: List(Result(a, Nil))) -> Result(List(a), Nil) {
  list.try_map(xs, fn(x) { x })
}

pub fn eval_path(ev: Ev, r: Option(Rec), parts: List(String), cur: Val) -> Val {
  let assert [head, ..steps] = parts
  let #(start, walk) = case head, r {
    "val", _ -> #(cur, ev)
    _, Some(rec) ->
      case model.field(rec.decl, head) {
        Some(_) -> #(get(ev, rec, head), ev)
        None -> outer(ev, head, steps)
      }
    _, None -> outer(ev, head, steps)
  }
  let v =
    list.fold(steps, start, fn(v, step) {
      case v {
        VInvalid -> VInvalid
        VLater -> VLater
        VSeqv(items, hi, elem) ->
          case list.contains(model.folds, step), is_type_name(step) {
            True, _ -> fold(ev, v, step)
            False, True -> filter(ev, items, hi, elem, step)
            False, False -> {
              let vals =
                list.try_fold(items, [], fn(acc, it) {
                  case it {
                    VRecord(rec) ->
                      case get(walk, rec, step) {
                        VInvalid -> Error(Nil)
                        VSeqv(xs, _, _) ->
                          Ok(list.append(list.reverse(xs), acc))
                        x -> Ok([x, ..acc])
                      }
                    _ -> Error(Nil)
                  }
                })
              case vals {
                Ok(xs) -> VSeqv(list.reverse(xs), hi, None)
                Error(_) -> VInvalid
              }
            }
          }
        VRecord(rec) -> get(walk, rec, step)
        _ -> VInvalid
      }
    })
  case v {
    VSeqv(items, Some(h), _) if h <= 1 ->
      case items {
        [x, ..] -> x
        [] -> VNumber(decimal.zero())
      }
    VSeqv(..) -> VInvalid
    _ -> v
  }
}

/// A path head that is not a field here: a type with one value ('True'),
/// or, with steps after it, the nearest record of that type around this
/// one ('Order.customer'). Steps after it walk with the context that
/// record had, so 'Book.customers' sees each customer inside the book.
fn outer(ev: Ev, head: String, steps: List(String)) -> #(Val, Ev) {
  case steps {
    [] -> #(type_constant(ev, head), ev)
    _ ->
      case find_outer(ev.ctx, head) {
        Ok(#(rec, above)) -> #(VRecord(rec), Ev(..ev, ctx: above))
        Error(_) ->
          case ev.after, ev.ctx, steps {
            True, [top, ..], [step, ..] -> {
              fail(
                top,
                "there is no "
                  <> head
                  <> " around this "
                  <> top.decl.name
                  <> ", so "
                  <> head
                  <> "."
                  <> step
                  <> " names nothing",
              )
              #(VInvalid, ev)
            }
            True, _, _ -> #(VInvalid, ev)
            False, _, _ -> #(VLater, ev)
          }
      }
  }
}

fn find_outer(ctx: List(Rec), name: String) -> Result(#(Rec, List(Rec)), Nil) {
  case ctx {
    [] -> Error(Nil)
    [r, ..above] ->
      case r.decl.name == name {
        True -> Ok(#(r, above))
        False -> find_outer(above, name)
      }
  }
}

fn type_constant(ev: Ev, head: String) -> Val {
  case string.first(head) {
    Ok(c) ->
      case string.uppercase(c) == c {
        True -> option.unwrap(singleton(ev, head), VInvalid)
        False -> VInvalid
      }
    Error(_) -> VInvalid
  }
}

@external(javascript, "./ffi.mjs", "first_is_upper")
fn is_type_name(s: String) -> Bool

/// A filter step: the items that inhabit a refinement of the item type
/// (Step 3). An item whose predicates are INVALID makes the result INVALID.
fn filter(
  ev: Ev,
  items: List(Val),
  hi: Option(Int),
  elem: Option(String),
  name: String,
) -> Val {
  case dict.get(ev.decls, name) {
    Error(_) -> VInvalid
    Ok(d) -> {
      let kept =
        list.try_fold(items, [], fn(acc, it) {
          case it, d.kind {
            VRecord(rec), _ if rec.decl.name == name -> Ok([it, ..acc])
            VRecord(rec), model.Refine ->
              case eval_block(ev, Some(rec), d.preds, it) {
                Yes -> Ok([it, ..acc])
                No -> Ok(acc)
                Inv -> Error(False)
                Later -> Error(True)
              }
            _, _ -> Error(False)
          }
        })
      case kept {
        Ok(xs) -> VSeqv(list.reverse(xs), hi, elem)
        Error(True) -> VLater
        Error(False) -> VInvalid
      }
    }
  }
}

fn fold(_ev: Ev, s: Val, kind: String) -> Val {
  let assert VSeqv(items, _, _) = s
  case kind {
    "qty" -> VNumber(decimal.from_int(list.length(items)))
    "sum" ->
      list.try_fold(items, decimal.zero(), fn(acc, x) {
        case x {
          VNumber(d) -> Ok(decimal.add(acc, d))
          _ -> Error(Nil)
        }
      })
      |> fn(r) {
        case r {
          Ok(d) -> VNumber(d)
          Error(_) -> VInvalid
        }
      }
    _ -> VInvalid
  }
}

pub fn same(a: Val, b: Val) -> Bool {
  case a, b {
    VNumber(x), VNumber(y) -> decimal.eq(x, y)
    VText(x), VText(y) -> x == y
    _, _ -> False
  }
}

fn compare(a: Val, op: String, b: Rhs) -> Bool {
  case b {
    RRange(lo, hi) ->
      case op, a {
        "=", VNumber(x) ->
          case lo {
            Some(l) -> decimal.le(l, x)
            None -> True
          }
          && case hi {
            Some(h) -> decimal.le(x, h)
            None -> True
          }
        _, _ -> False
      }
    RVal(VNumber(y)) ->
      case a {
        VNumber(x) ->
          case op {
            "=" -> decimal.eq(x, y)
            "<" -> decimal.lt(x, y)
            "<=" -> decimal.le(x, y)
            ">" -> decimal.lt(y, x)
            _ -> decimal.le(y, x)
          }
        _ -> False
      }
    RVal(VText(y)) ->
      case a {
        VText(x) -> op == "=" && x == y
        _ -> False
      }
    _ -> False
  }
}

pub fn deps(b: Block) -> List(String) {
  list.fold(b.clauses, [], fn(acc, c) {
    case c {
      Plain(p, _, v) -> add_dep(add_dep(acc, VPath(p)), v)
      _ -> acc
    }
  })
}

fn add_dep(acc: List(String), v: Value) -> List(String) {
  case v {
    VPath([first, ..]) ->
      case
        first != "val" && is_lower_start(first) && !list.contains(acc, first)
      {
        True -> list.append(acc, [first])
        False -> acc
      }
    VArith(_, ts) -> list.fold(ts, acc, add_dep)
    VMulti(vs) -> list.fold(vs, acc, add_dep)
    _ -> acc
  }
}

@external(javascript, "./ffi.mjs", "first_is_lower")
fn is_lower_start(s: String) -> Bool

// ---------------------------------------------------------------- hooks used by the parser

/// A number written with exactly the places its refinement line asks for.
fn places_fit(d: Decl, v: Val, written: String) -> Bool {
  case model.setting(d.preds, "places"), v {
    Some(model.VNum(n)), VNumber(_) -> {
      let got = case string.split_once(written, ".") {
        Ok(#(_, frac)) -> string.length(frac)
        Error(_) -> 0
      }
      got == decimal.to_int(n.value)
    }
    _, _ -> True
  }
}

pub fn checker(ev: Ev, text: String) -> fn(Check, Node) -> Bool {
  fn(c: Check, n: Node) -> Bool {
    case c {
      CheckRecord(name) -> {
        let assert Ok(d) = dict.get(ev.decls, name)
        evaluate_all(ev, rec_of(d, n, text))
      }
      CheckRefine(name) -> {
        let assert Ok(d) = dict.get(ev.decls, name)
        let v = value(ev, n, text, None, None)
        case v {
          VRecord(r) ->
            case evaluate_all(ev, r) {
              False -> False
              True -> passes(eval_block(ev, Some(r), d.preds, v))
            }
          _ ->
            passes(eval_block(ev, None, d.preds, v))
            && places_fit(d, v, slice(text, n.s, n.e))
        }
      }
      CheckPosition(name, number) -> {
        let assert Ok(d) = dict.get(ev.decls, name)
        let assert Ok(p) = list.find(d.positions, fn(p) { p.number == number })
        passes(eval_block(
          ev,
          None,
          p.preds,
          value(ev, n, text, Some(p.items), None),
        ))
      }
      CheckUnique(name) -> {
        let assert Ok(d) = dict.get(ev.decls, name)
        let kids = node.items(n)
        unique_ok(ev, d, kids, text)
      }
    }
  }
}

/// While reading, a predicate that reaches a record around this one cannot be
/// decided yet; it does not reject the text.
fn passes(t: Tri) -> Bool {
  t == Yes || t == Later
}

fn unique_ok(ev: Ev, d: Decl, kids: List(Node), text: String) -> Bool {
  case d.kind {
    model.Record -> {
      let flagged =
        list.filter(d.fields, fn(f) { model.has_flag(f.preds, "unique") })
      let recs =
        list.filter_map(kids, fn(k) {
          case value(ev, k, text, None, None) {
            VRecord(r) -> Ok(r)
            _ -> Error(Nil)
          }
        })
      list.all(flagged, fn(f) {
        let keys = list.map(recs, fn(r) { unique_key(ev, r, f) })
        list.length(list.unique(keys)) == list.length(keys)
      })
    }
    _ -> True
  }
}

/// Rows are equal when their values are equal, as with '=': numbers by
/// value (1.50 = 1.5), everything else by its text.
fn unique_key(ev: Ev, r: Rec, f: Field) -> String {
  case get(ev, r, f.name) {
    VNumber(x) -> decimal.to_short(x)
    v ->
      case model.is_stored(f) {
        True -> stored_text(r, f.name)
        False -> show(v)
      }
  }
}

/// Every record inside a value, the value first.
pub fn records(v: Val) -> List(Rec) {
  records_loop(v, []) |> list.reverse
}

fn records_loop(v: Val, acc: List(Rec)) -> List(Rec) {
  case v {
    VRecord(r) -> [r, ..acc]
    VSeqv(xs, _, _) -> list.fold(xs, acc, fn(a, x) { records_loop(x, a) })
    _ -> acc
  }
}

/// All records reachable through stored fields (evaluating them), outermost first.
pub fn all_records(ev: Ev, v: Val) -> List(Rec) {
  all_loop(ev, v, []) |> list.reverse
}

fn all_loop(ev: Ev, v: Val, acc: List(Rec)) -> List(Rec) {
  case v {
    VRecord(r) ->
      list.fold(r.decl.fields, [r, ..acc], fn(acc, f) {
        case model.is_stored(f) {
          True -> all_loop(ev, get(ev, r, f.name), acc)
          False -> acc
        }
      })
    VSeqv(xs, _, _) -> list.fold(xs, acc, fn(a, x) { all_loop(ev, x, a) })
    _ -> acc
  }
}

/// Every 'unique' field with two rows of equal value.
pub fn unique_violations(ev: Ev, v: Val) -> List(String) {
  uv_loop(ev, v, []) |> list.reverse
}

fn uv_loop(ev: Ev, v: Val, acc: List(String)) -> List(String) {
  case v {
    VRecord(r) ->
      list.fold(r.decl.fields, acc, fn(acc, f) {
        case model.is_stored(f) {
          True -> uv_loop(ev, get(ev, r, f.name), acc)
          False -> acc
        }
      })
    VSeqv(xs, _, _) -> {
      let recs =
        list.filter_map(xs, fn(x) {
          case x {
            VRecord(r) -> Ok(r)
            _ -> Error(Nil)
          }
        })
      let acc = case recs {
        [first, ..] ->
          list.fold(first.decl.fields, acc, fn(acc, f) {
            case model.has_flag(f.preds, "unique") {
              False -> acc
              True -> {
                let #(_, acc) =
                  list.index_fold(recs, #(dict.new(), acc), fn(st, r, i) {
                    let #(seen, acc) = st
                    let key = unique_key(ev, r, f)
                    case dict.get(seen, key) {
                      Ok(j) -> #(seen, [
                        first.decl.name
                          <> "."
                          <> f.name
                          <> " is unique, but rows "
                          <> int.to_string(j)
                          <> " and "
                          <> int.to_string(i + 1)
                          <> " both have "
                          <> string.inspect(key),
                        ..acc
                      ])
                      Error(_) -> #(dict.insert(seen, key, i + 1), acc)
                    }
                  })
                acc
              }
            }
          })
        [] -> acc
      }
      list.fold(xs, acc, fn(a, x) { uv_loop(ev, x, a) })
    }
    _ -> acc
  }
}
