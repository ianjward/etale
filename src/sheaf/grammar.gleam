//// The grammar engine: compiles declarations into matchers and parses text.
////
//// "A text inhabits a type when some way of matching it succeeds." The parser
//// explores every way of matching, memoized, keeping at most two parse trees per
//// (matcher, start, end): enough to see ambiguity without blowing up. Rules are
//// part of inhabitation: with enforce on, a record whose rules fail, a refinement
//// whose predicates fail, or a sequence that breaks 'unique' does not match.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import sheaf/decimal
import sheaf/model.{type Decl, type Item, NumItem, StrItem, TypeItem}
import sheaf/node.{type Node, NAlt, NChar, NLay, NLit, NRec, NSeq, Node}

pub const cap = 2

pub type Check {
  CheckRecord(decl: String)
  CheckRefine(decl: String)
  CheckPosition(decl: String, number: Int)
  CheckUnique(decl: String)
}

pub type M {
  Lit(text: String, name: Option(String))
  Chars(name: Option(String), chars: Dict(String, Int))
  Alt(name: Option(String), alts: List(Int))
  Seq(
    name: Option(String),
    elem: Int,
    lo: Int,
    hi: Option(Int),
    elem_decl: Option(String),
  )
  Cat(name: String, record: Bool, parts: List(#(String, Int)))
  Filt(name: Option(String), base: Int, check: Check, what: String)
  Ref(name: String)
  /// Matches of 'first' whose exact span every one of 'others' also matches.
  Inter(name: String, first: Int, others: List(Int))
}

pub type Grammar {
  Grammar(table: Dict(Int, M), types: Dict(String, Int))
}

type St {
  St(
    table: Dict(Int, M),
    types: Dict(String, Int),
    next: Int,
    building: Set(String),
  )
}

// ---------------------------------------------------------------- compiling

pub fn compile(decls: Dict(String, Decl)) -> Grammar {
  let st = St(dict.new(), dict.new(), 0, set.new())
  let st =
    dict.keys(decls)
    |> list.fold(st, fn(st, name) { type_id(decls, st, name).1 })
  let st = case
    dict.has_key(decls, "Integer_Literal")
    && dict.has_key(decls, "Decimal_Literal")
  {
    True ->
      list.fold(model.builtin_numeric, st, fn(st, n) { type_id(decls, st, n).1 })
    False -> st
  }
  Grammar(st.table, st.types)
}

fn put(st: St, m: M) -> #(Int, St) {
  #(
    st.next,
    St(..st, table: dict.insert(st.table, st.next, m), next: st.next + 1),
  )
}

fn get(st: St, id: Int) -> M {
  let assert Ok(m) = dict.get(st.table, id)
  m
}

fn type_id(decls: Dict(String, Decl), st: St, name: String) -> #(Int, St) {
  case dict.get(st.types, name) {
    Ok(id) -> #(id, st)
    Error(_) ->
      case set.contains(st.building, name) {
        True -> put(st, Ref(name))
        False -> {
          let st = St(..st, building: set.insert(st.building, name))
          let #(id, st) = compile_type(decls, st, name)
          #(
            id,
            St(
              ..st,
              types: dict.insert(st.types, name, id),
              building: set.delete(st.building, name),
            ),
          )
        }
      }
  }
}

fn item(decls, st: St, it: Item) -> #(Int, St) {
  case it {
    TypeItem(n) -> type_id(decls, st, n)
    StrItem(s) -> put(st, Lit(s, None))
    NumItem(_, t) -> put(st, Lit(t, None))
  }
}

fn items(decls, st: St, its: List(Item), name: Option(String)) -> #(Int, St) {
  case its, name {
    [one], None -> item(decls, st, one)
    _, _ -> {
      let #(ids, st) =
        list.fold(its, #([], st), fn(acc, it) {
          let #(ids, st) = acc
          let #(id, st) = item(decls, st, it)
          #([id, ..ids], st)
        })
      alt(st, name, list.reverse(ids))
    }
  }
}

fn charlike(st: St, id: Int) -> Option(Dict(String, Int)) {
  case get(st, id) {
    Lit(t, _) ->
      case text_length(t) == 1 {
        True -> Some(dict.from_list([#(t, 1)]))
        False -> None
      }
    Chars(_, cs) -> Some(cs)
    _ -> None
  }
}

fn alt(st: St, name: Option(String), ids: List(Int)) -> #(Int, St) {
  let sets = list.map(ids, charlike(st, _))
  case list.all(sets, option.is_some) {
    True -> {
      let merged =
        list.fold(sets, dict.new(), fn(acc, s) {
          let assert Some(cs) = s
          dict.fold(cs, acc, fn(acc, c, k) {
            let now = case dict.get(acc, c) {
              Ok(x) -> x
              Error(_) -> 0
            }
            dict.insert(acc, c, int.min(cap, now + k))
          })
        })
      put(st, Chars(name, merged))
    }
    False -> put(st, Alt(name, ids))
  }
}

pub fn qty_bounds(
  q: Option(#(Option(model.Num), Option(model.Num))),
) -> #(Int, Option(Int)) {
  case q {
    None -> #(1, Some(1))
    Some(#(lo, hi)) -> #(
      case lo {
        Some(n) -> decimal.to_int(n.value)
        None -> 0
      },
      case hi {
        Some(n) -> Some(decimal.to_int(n.value))
        None -> None
      },
    )
  }
}

/// The record whose 'unique' fields a sequence of this item must respect, if any.
fn elem_decl(decls: Dict(String, Decl), it: Item) -> Option(String) {
  case it {
    TypeItem(n) ->
      case dict.get(decls, n) {
        Ok(d) ->
          case list.any(d.fields, fn(f) { model.has_flag(f.preds, "unique") }) {
            True -> Some(n)
            False -> None
          }
        Error(_) -> None
      }
    _ -> None
  }
}

fn compile_type(decls: Dict(String, Decl), st: St, name: String) -> #(Int, St) {
  case name {
    "Integer" -> {
      let #(i, st) = type_id(decls, st, "Integer_Literal")
      put(st, Alt(Some(name), [i]))
    }
    "Decimal" -> {
      let #(i, st) = type_id(decls, st, "Decimal_Literal")
      put(st, Alt(Some(name), [i]))
    }
    _ ->
      case dict.get(decls, name) {
        // an undeclared name matches nothing; the checker reports it
        Error(_) -> put(st, Alt(Some(name), []))
        Ok(d) -> compile_decl(decls, st, name, d)
      }
  }
}

fn compile_decl(
  decls: Dict(String, Decl),
  st: St,
  name: String,
  d: Decl,
) -> #(Int, St) {
  {
    {
      case d.kind {
        model.Union -> items(decls, st, d.items, Some(name))
        model.Intersection -> {
          let assert [first, ..others] = d.items
          let #(f, st) = item(decls, st, first)
          let #(os, st) =
            list.fold(others, #([], st), fn(acc, it) {
              let #(ids, st) = acc
              let #(id, st) = item(decls, st, it)
              #([id, ..ids], st)
            })
          put(st, Inter(name, f, list.reverse(os)))
        }
        model.Refine -> {
          let b = model.decl_base(d)
          let #(base, st) = item(decls, st, b)
          let #(m, st) = case model.qty_of(d.preds) {
            Some(_) -> {
              let #(lo, hi) = qty_bounds(model.qty_of(d.preds))
              put(st, Seq(Some(name), base, lo, hi, elem_decl(decls, b)))
            }
            None ->
              case charlike(st, base) {
                Some(cs) -> put(st, Chars(Some(name), cs))
                None -> put(st, Alt(Some(name), [base]))
              }
          }
          case model.plains(d.preds), model.setting(d.preds, "places") {
            [], None -> #(m, st)
            _, _ ->
              put(
                st,
                Filt(Some(name), m, CheckRefine(name), "predicates of " <> name),
              )
          }
        }
        model.Layout -> {
          let #(parts, st) =
            list.fold(d.positions, #([], st), fn(acc, p) {
              let #(parts, st) = acc
              let #(pm, st) = items(decls, st, p.items, None)
              let #(pm, st) = case model.qty_of(p.preds) {
                Some(_) -> {
                  let #(lo, hi) = qty_bounds(model.qty_of(p.preds))
                  put(st, Seq(None, pm, lo, hi, None))
                }
                None -> #(pm, st)
              }
              let #(pm, st) = case model.plains(p.preds) {
                [] -> #(pm, st)
                _ ->
                  put(
                    st,
                    Filt(
                      None,
                      pm,
                      CheckPosition(name, p.number),
                      "position " <> int.to_string(p.number) <> " of " <> name,
                    ),
                  )
              }
              #([#(int.to_string(p.number), pm), ..parts], st)
            })
          let #(m, st) = put(st, Cat(name, False, list.reverse(parts)))
          case model.plains(d.preds) {
            [] -> #(m, st)
            _ ->
              put(
                st,
                Filt(Some(name), m, CheckRefine(name), "predicates of " <> name),
              )
          }
        }
        model.Record -> {
          let #(parts, st) =
            list.fold(d.fields, #([], st), fn(acc, f) {
              let #(parts, st) = acc
              case model.is_stored(f) {
                False -> #(parts, st)
                True -> {
                  let #(fm, st) = items(decls, st, f.items, None)
                  let #(fm, st) = case model.qty(f) {
                    Some(_) -> {
                      let #(lo, hi) = qty_bounds(model.qty(f))
                      put(
                        st,
                        Seq(None, fm, lo, hi, elem_decl(decls, model.base(f))),
                      )
                    }
                    None -> #(fm, st)
                  }
                  #([#(f.name, fm), ..parts], st)
                }
              }
            })
          let #(m, st) = put(st, Cat(name, True, list.reverse(parts)))
          put(st, Filt(Some(name), m, CheckRecord(name), "rules of " <> name))
        }
      }
    }
  }
}

// ---------------------------------------------------------------- parsing

pub type Store(k, v)

pub type Cell(v)

@external(javascript, "./ffi.mjs", "store_new")
pub fn store_new() -> Store(k, v)

@external(javascript, "./ffi.mjs", "store_get")
pub fn store_get(s: Store(k, v), k: k) -> Result(v, Nil)

@external(javascript, "./ffi.mjs", "store_set")
pub fn store_set(s: Store(k, v), k: k, v: v) -> Nil

@external(javascript, "./ffi.mjs", "ref_new")
pub fn cell(v: v) -> Cell(v)

@external(javascript, "./ffi.mjs", "ref_get")
pub fn read(c: Cell(v)) -> v

@external(javascript, "./ffi.mjs", "ref_set")
pub fn write(c: Cell(v), v: v) -> Nil

@external(javascript, "./ffi.mjs", "char_at")
fn char_at(s: String, i: Int) -> String

@external(javascript, "./ffi.mjs", "starts_with_at")
fn starts_with_at(s: String, lit: String, i: Int) -> Bool

@external(javascript, "./ffi.mjs", "length")
pub fn text_length(s: String) -> Int

@external(javascript, "./ffi.mjs", "count_newlines")
fn count_newlines(s: String, a: Int, b: Int) -> Int

@external(javascript, "./ffi.mjs", "last_index_of_before")
fn last_index_of_before(s: String, sub: String, i: Int) -> Int

pub type Results =
  List(#(Int, List(Node)))

pub type Parser {
  Parser(
    g: Grammar,
    text: String,
    len: Int,
    enforce: Bool,
    check: fn(Check, Node) -> Bool,
    memo: Store(Int, Results),
    exact: Store(Int, Store(Int, List(Node))),
    far: Cell(Int),
    expected: Cell(List(String)),
    rejected: Cell(List(String)),
  )
}

pub fn parser(
  g: Grammar,
  text: String,
  enforce: Bool,
  check: fn(Check, Node) -> Bool,
) -> Parser {
  Parser(
    g,
    text,
    text_length(text),
    enforce,
    check,
    store_new(),
    store_new(),
    cell(0),
    cell([]),
    cell([]),
  )
}

fn fail(p: Parser, pos: Int, what: String) -> Nil {
  let far = read(p.far)
  case pos > far, pos == far {
    True, _ -> {
      write(p.far, pos)
      write(p.expected, [what])
    }
    _, True -> write(p.expected, [what, ..read(p.expected)])
    _, _ -> Nil
  }
}

fn m_of(p: Parser, id: Int) -> M {
  let assert Ok(m) = dict.get(p.g.table, id)
  m
}

pub fn run(p: Parser, id: Int, pos: Int) -> Results {
  let key = id * { p.len + 2 } + pos
  case store_get(p.memo, key) {
    Ok(r) -> r
    Error(_) -> {
      store_set(p.memo, key, [])
      let r = run_m(p, m_of(p, id), pos)
      store_set(p.memo, key, r)
      r
    }
  }
}

fn add_result(rs: Results, e: Int, n: Node) -> Results {
  case rs {
    [] -> [#(e, [n])]
    [#(e2, ns), ..rest] if e2 == e ->
      case list.length(ns) < cap {
        True -> [#(e2, list.append(ns, [n])), ..rest]
        False -> rs
      }
    [first, ..rest] -> [first, ..add_result(rest, e, n)]
  }
}

fn run_m(p: Parser, m: M, pos: Int) -> Results {
  case m {
    Lit(t, name) ->
      case starts_with_at(p.text, t, pos) {
        True -> {
          let e = pos + text_length(t)
          [#(e, [Node(name, pos, e, NLit)])]
        }
        False -> {
          fail(p, pos, string.inspect(t))
          []
        }
      }
    Chars(name, cs) -> {
      let c = char_at(p.text, pos)
      case c, dict.get(cs, c) {
        "", _ -> {
          fail(p, pos, option.unwrap(name, "a character"))
          []
        }
        _, Ok(k) -> [
          #(pos + 1, list.repeat(Node(name, pos, pos + 1, NChar), k)),
        ]
        _, Error(_) -> {
          fail(p, pos, option.unwrap(name, "a character"))
          []
        }
      }
    }
    Ref(name) -> {
      let assert Ok(id) = dict.get(p.g.types, name)
      run(p, id, pos)
    }
    Alt(name, alts) ->
      list.fold(alts, [], fn(acc, a) {
        list.fold(run(p, a, pos), acc, fn(acc, r) {
          let #(e, nodes) = r
          list.fold(nodes, acc, fn(acc, n) {
            let n2 = case name {
              Some(_) -> Node(name, pos, e, NAlt(n))
              None -> n
            }
            add_result(acc, e, n2)
          })
        })
      })
    Filt(_, base, check, what) -> {
      let rs = run(p, base, pos)
      case p.enforce {
        False -> rs
        True ->
          list.filter_map(rs, fn(r) {
            let #(e, nodes) = r
            let keep =
              list.filter(nodes, fn(n) {
                let ok = p.check(check, n)
                case ok {
                  False -> write(p.rejected, [what, ..read(p.rejected)])
                  True -> Nil
                }
                ok
              })
            case keep {
              [] -> Error(Nil)
              _ -> Ok(#(e, keep))
            }
          })
      }
    }
    Cat(name, record, parts) -> {
      let front = cat_front(p, parts, pos, None)
      list.map(front, fn(f) {
        let #(e, partials) = f
        #(
          e,
          list.map(partials, fn(ps) {
            let kids = list.reverse(ps)
            case record {
              True -> Node(Some(name), pos, e, NRec(kids))
              False -> Node(Some(name), pos, e, NLay(kids))
            }
          }),
        )
      })
    }
    Seq(name, elem, lo, hi, edecl) -> run_seq(p, name, elem, lo, hi, edecl, pos)
    Inter(name, first, others) ->
      list.filter_map(run(p, first, pos), fn(r) {
        let #(e, nodes) = r
        case inter_ok(p, name, others, pos, e) {
          False -> Error(Nil)
          True ->
            Ok(#(
              e,
              list.map(nodes, fn(n) { Node(Some(name), pos, e, NAlt(n)) }),
            ))
        }
      })
  }
}

/// Every other type of an intersection matches exactly text[pos, e). Only the
/// first type's readings count as parses, so the others need not be unambiguous.
fn inter_ok(
  p: Parser,
  name: String,
  others: List(Int),
  pos: Int,
  e: Int,
) -> Bool {
  let ok = list.all(others, fn(o) { run_exact(p, o, pos, e) != [] })
  case ok {
    False -> {
      write(p.rejected, ["every part of " <> name, ..read(p.rejected)])
      fail(p, e, "the rest of " <> name)
    }
    True -> Nil
  }
  ok
}

/// Partial records after each part in turn: for every end position reached,
/// up to cap lists of (label, node), last part first. Kept by end in a dict,
/// so a part with many possible ends costs one step per end.
fn cat_front(
  p: Parser,
  parts: List(#(String, Int)),
  pos: Int,
  upto: Option(Int),
) -> List(#(Int, List(List(#(String, Node))))) {
  list.fold(parts, [#(pos, [[]])], fn(front, part) {
    let #(label, pid) = part
    list.fold(front, dict.new(), fn(acc, f) {
      let #(at, partials) = f
      list.fold(run(p, pid, at), acc, fn(acc, r) {
        let #(e, nodes) = r
        let keep = case upto {
          Some(u) -> e <= u
          None -> True
        }
        case keep {
          False -> acc
          True ->
            list.fold(partials, acc, fn(acc, partial) {
              list.fold(nodes, acc, fn(acc, n) {
                add_to(acc, e, [#(label, n), ..partial])
              })
            })
        }
      })
    })
    |> dict.to_list
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  })
}

fn run_seq(
  p: Parser,
  name,
  elem: Int,
  lo: Int,
  hi: Option(Int),
  edecl: Option(String),
  pos: Int,
) -> Results {
  // Partial sequences are item lists, last item first. Results are kept by
  // end position in a dict, so a long sequence costs one step per item.
  let start = [#(pos, [[]])]
  let results = case lo {
    0 -> dict.from_list([#(pos, [[]])])
    _ -> dict.new()
  }
  let results = seq_loop(p, elem, lo, hi, start, results, 0)
  dict.to_list(results)
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.filter_map(fn(r) {
    let #(e, partials) = r
    case seq_nodes(p, name, edecl, pos, e, partials) {
      [] -> Error(Nil)
      nodes -> Ok(#(e, nodes))
    }
  })
}

fn seq_nodes(
  p: Parser,
  name,
  edecl: Option(String),
  pos: Int,
  e: Int,
  partials: List(List(Node)),
) -> List(Node) {
  list.filter_map(partials, fn(items) {
    let n = Node(name, pos, e, NSeq(items))
    case p.enforce, edecl {
      True, Some(d) ->
        case p.check(CheckUnique(d), n) {
          True -> Ok(n)
          False -> {
            write(p.rejected, ["unique fields of " <> d, ..read(p.rejected)])
            Error(Nil)
          }
        }
      _, _ -> Ok(n)
    }
  })
}

fn add_to(d: Dict(Int, List(a)), e: Int, x: a) -> Dict(Int, List(a)) {
  case dict.get(d, e) {
    Ok(xs) ->
      case list.length(xs) < cap {
        True -> dict.insert(d, e, [x, ..xs])
        False -> d
      }
    Error(_) -> dict.insert(d, e, [x])
  }
}

/// One step per item: extend every partial sequence in the frontier by one
/// more item. Stops when the frontier is empty or hi is reached.
fn seq_loop(
  p: Parser,
  elem,
  lo,
  hi: Option(Int),
  front: List(#(Int, List(List(Node)))),
  results: Dict(Int, List(List(Node))),
  count: Int,
) -> Dict(Int, List(List(Node))) {
  let more = case hi {
    Some(h) -> count < h
    None -> True
  }
  case front, more {
    [], _ -> results
    _, False -> results
    _, True -> {
      let count = count + 1
      let next = step(p, elem, front, None)
      let results = case count >= lo {
        True ->
          list.fold(next, results, fn(acc, f) {
            let #(e, partials) = f
            list.fold(partials, acc, fn(acc, x) { add_to(acc, e, x) })
          })
        False -> results
      }
      case count > p.len + 1 {
        True -> results
        False -> seq_loop(p, elem, lo, hi, next, results, count)
      }
    }
  }
}

/// Extend each partial in the frontier by one item. With 'upto', items that
/// would end past that position are dropped.
fn step(
  p: Parser,
  elem: Int,
  front: List(#(Int, List(List(Node)))),
  upto: Option(Int),
) -> List(#(Int, List(List(Node)))) {
  let next =
    list.fold(front, dict.new(), fn(acc, f) {
      let #(at, partials) = f
      list.fold(run(p, elem, at), acc, fn(acc, r) {
        let #(e, nodes) = r
        let keep = case upto {
          Some(u) -> e <= u
          None -> True
        }
        case e == at || !keep {
          True -> acc
          False ->
            list.fold(partials, acc, fn(acc, partial) {
              list.fold(nodes, acc, fn(acc, n) {
                add_to(acc, e, [n, ..partial])
              })
            })
        }
      })
    })
  dict.to_list(next)
}

// ---------------------------------------------------------------- exact spans

/// Every way (at most two) that matcher id matches exactly text[pos, end).
/// Parsing towards a known end avoids building a result for every possible
/// end: the last part of a record or sequence is asked for its exact span, so
/// right-recursive data (a chain whose tail is optional) parses in linear time.
pub fn run_exact(p: Parser, id: Int, pos: Int, end: Int) -> List(Node) {
  let key = id * { p.len + 2 } + pos
  let row = case store_get(p.exact, key) {
    Ok(row) -> row
    Error(_) -> {
      let row = store_new()
      store_set(p.exact, key, row)
      row
    }
  }
  case store_get(row, end) {
    Ok(r) -> r
    Error(_) -> {
      store_set(row, end, [])
      let r = exact_m(p, m_of(p, id), pos, end)
      store_set(row, end, r)
      r
    }
  }
}

fn take(nodes: List(Node)) -> List(Node) {
  list.take(nodes, cap)
}

fn exact_m(p: Parser, m: M, pos: Int, end: Int) -> List(Node) {
  case m {
    Lit(_, _) | Chars(_, _) ->
      case list.key_find(run_m(p, m, pos), end) {
        Ok(nodes) -> nodes
        Error(_) -> []
      }
    Ref(name) -> {
      let assert Ok(id) = dict.get(p.g.types, name)
      run_exact(p, id, pos, end)
    }
    Alt(name, alts) ->
      list.flat_map(alts, fn(a) {
        list.map(run_exact(p, a, pos, end), fn(n) {
          case name {
            Some(_) -> Node(name, pos, end, NAlt(n))
            None -> n
          }
        })
      })
      |> take
    Filt(_, base, check, what) -> {
      let nodes = run_exact(p, base, pos, end)
      case p.enforce {
        False -> nodes
        True ->
          list.filter(nodes, fn(n) {
            let ok = p.check(check, n)
            case ok {
              False -> write(p.rejected, [what, ..read(p.rejected)])
              True -> Nil
            }
            ok
          })
      }
    }
    Cat(name, record, parts) -> {
      let #(init, last) = split_last(parts)
      let front = cat_front(p, init, pos, Some(end))
      let finished = case last {
        None ->
          case list.key_find(front, end) {
            Ok(ps) -> ps
            Error(_) -> []
          }
        Some(#(label, pid)) ->
          list.flat_map(front, fn(f) {
            let #(at, partials) = f
            list.flat_map(run_exact(p, pid, at, end), fn(n) {
              list.map(partials, fn(partial) { [#(label, n), ..partial] })
            })
          })
      }
      list.map(finished, fn(ps) {
        let kids = list.reverse(ps)
        case record {
          True -> Node(Some(name), pos, end, NRec(kids))
          False -> Node(Some(name), pos, end, NLay(kids))
        }
      })
      |> take
    }
    Seq(name, elem, lo, hi, edecl) -> {
      let partials = exact_seq(p, elem, lo, hi, pos, end)
      seq_nodes(p, name, edecl, pos, end, partials)
    }
    Inter(name, first, others) ->
      case run_exact(p, first, pos, end) {
        [] -> []
        nodes ->
          case inter_ok(p, name, others, pos, end) {
            False -> []
            True ->
              list.map(nodes, fn(n) { Node(Some(name), pos, end, NAlt(n)) })
          }
      }
  }
}

fn split_last(xs: List(a)) -> #(List(a), Option(a)) {
  case list.reverse(xs) {
    [] -> #([], None)
    [last, ..rest] -> #(list.reverse(rest), Some(last))
  }
}

/// Partial item lists (last item first) of lo..hi items covering pos..end
/// exactly: earlier items by forward steps, the last one asked for its span.
fn exact_seq(
  p: Parser,
  elem: Int,
  lo: Int,
  hi: Option(Int),
  pos: Int,
  end: Int,
) -> List(List(Node)) {
  let empty = case lo == 0 && pos == end {
    True -> [[]]
    False -> []
  }
  case pos == end {
    True -> empty
    False -> exact_loop(p, elem, lo, hi, [#(pos, [[]])], end, 0, empty)
  }
}

fn exact_loop(
  p: Parser,
  elem: Int,
  lo: Int,
  hi: Option(Int),
  front: List(#(Int, List(List(Node)))),
  end: Int,
  count: Int,
  found: List(List(Node)),
) -> List(List(Node)) {
  let room = case hi {
    Some(h) -> count < h
    None -> True
  }
  case front, room, list.length(found) >= cap {
    [], _, _ | _, False, _ | _, _, True -> list.take(found, cap)
    _, True, False -> {
      // finish here: this item is the last one and must end exactly at end
      let found = case count + 1 >= lo {
        True ->
          list.fold(front, found, fn(acc, f) {
            let #(at, partials) = f
            list.fold(run_exact(p, elem, at, end), acc, fn(acc, n) {
              case at == end {
                True -> acc
                False ->
                  list.fold(partials, acc, fn(acc, partial) {
                    [[n, ..partial], ..acc]
                  })
              }
            })
          })
        False -> found
      }
      // or continue: this item ends before end and more follow (only when
      // hi leaves room for another item after it)
      let another = case hi {
        Some(h) -> count + 1 < h
        None -> True
      }
      let next = case another {
        True ->
          step(p, elem, front, Some(end))
          |> list.filter(fn(f) { f.0 < end })
        False -> []
      }
      exact_loop(p, elem, lo, hi, next, end, count + 1, found)
    }
  }
}

/// Every parse of the whole text (at most two) from the given type.
pub fn parse(p: Parser, type_name: String) -> List(Node) {
  case dict.get(p.g.types, type_name) {
    Error(_) -> []
    Ok(id) -> run_exact(p, id, 0, p.len)
  }
}

pub fn line_col(text: String, pos: Int) -> #(Int, Int) {
  let line = count_newlines(text, 0, pos) + 1
  let col = pos - { last_index_of_before(text, "\n", pos - 1) + 1 } + 1
  #(line, col)
}

pub fn expected(p: Parser) -> List(String) {
  read(p.expected) |> list.unique |> list.sort(string.compare)
}

pub fn rejected(p: Parser) -> List(String) {
  read(p.rejected) |> list.reverse
}
