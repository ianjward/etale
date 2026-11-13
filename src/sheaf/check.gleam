//// Static checks: everything the spec decides against declarations, never data.
////
////   order     a type resolves only to a type declared strictly above it; the
////             one exception is a recursive field whose qty starts at 0
////   fields    reserved names, fields named only above, folds end paths
////   recursion a product reads at most one factor through a recursive field
////   mappings  one or two inputs; box cases; coverage, disjointness, and every
////             output value produced
////   claims    expand, cancel, bound by ranges (induction on recursive fields)
////   places    assigning to fewer decimal places is an error
////   cost      every record's cost is worked out; 'cost <= ...' is a promise

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import sheaf/decimal.{type Decimal}
import sheaf/evaluate.{type Ev, type Val, VNumber, VText}
import sheaf/grammar.{type Cell}
import sheaf/model.{
  type Case, type Decl, type Field, type Item, type Value, Decl, NumItem, OrConn,
  Plain, Setting, StrItem, TypeItem, VArith, VFilter, VMulti, VNum, VPath,
  VRange, VStr,
}

pub type Diag {
  Diag(severity: String, msg: String, file: String, line: Int, where: String)
}

pub fn render(d: Diag) -> String {
  d.file
  <> ":"
  <> int.to_string(d.line)
  <> ": "
  <> d.severity
  <> ": "
  <> d.msg
  <> case d.where {
    "" -> ""
    w -> " [" <> w <> "]"
  }
}

pub type Report {
  Report(
    diags: List(Diag),
    costs: List(#(String, String)),
    claims: List(#(String, String)),
    mappings: List(#(String, String)),
  )
}

pub fn empty_report() -> Report {
  Report([], [], [], [])
}

pub fn merge(a: Report, b: Report) -> Report {
  Report(
    list.append(a.diags, b.diags),
    list.append(a.costs, b.costs),
    list.append(a.claims, b.claims),
    list.append(a.mappings, b.mappings),
  )
}

pub fn errors(r: Report) -> List(Diag) {
  list.filter(r.diags, fn(d) { d.severity == "error" })
}

type Ctx {
  Ctx(
    decls: Dict(String, Decl),
    index: Dict(String, Int),
    ev: Ev,
    diags: Cell(List(Diag)),
    costs: Cell(List(#(String, String))),
    claims: Cell(List(#(String, String))),
    mappings: Cell(List(#(String, String))),
  )
}

pub fn run(
  decls: Dict(String, Decl),
  index: Dict(String, Int),
  mine: List(Decl),
) -> Report {
  let c =
    Ctx(
      decls,
      index,
      evaluate.new(decls),
      grammar.cell([]),
      grammar.cell([]),
      grammar.cell([]),
      grammar.cell([]),
    )
  list.each(mine, fn(d) { check_decl(c, d) })
  Report(
    list.reverse(grammar.read(c.diags)),
    list.reverse(grammar.read(c.costs)),
    list.reverse(grammar.read(c.claims)),
    list.reverse(grammar.read(c.mappings)),
  )
}

fn push(cell: Cell(List(a)), x: a) -> Nil {
  grammar.write(cell, [x, ..grammar.read(cell)])
}

fn err(c: Ctx, d: Decl, line: Int, msg: String, where: String) -> Nil {
  let line = case line {
    0 -> d.line
    l -> l
  }
  push(c.diags, Diag("error", msg, d.file, line, where))
}

fn idx(c: Ctx, name: String) -> Int {
  case dict.get(c.index, name) {
    Ok(i) -> i
    Error(_) -> -1
  }
}

/// The bounds, claims and costs below read a filtered fold as a path with a
/// filter step in it, 'stops.Filtered.qty': a filter keeps some of the items,
/// so it can only lower a count to 0. The step is a marker for them and is
/// never looked up as a type.
fn analysis_value(v: Value) -> Value {
  case v {
    VFilter([list_name, ..rest], _) -> VPath([list_name, "Filtered", ..rest])
    _ -> v
  }
}

fn definition(f: Field) -> Option(Value) {
  option.map(model.definition(f), analysis_value)
}

fn is_upper_start(s: String) -> Bool {
  case string.first(s) {
    Ok(ch) -> string.uppercase(ch) == ch && string.lowercase(ch) != ch
    Error(_) -> False
  }
}

// ---------------------------------------------------------------- context

fn rhs_paths(v: Value) -> List(List(String)) {
  case v {
    VPath(p) -> [p]
    VArith(_, ts) | VMulti(ts) -> list.flat_map(ts, rhs_paths)
    _ -> []
  }
}

fn block_paths(b: model.Block) -> List(List(String)) {
  list.flat_map(b.clauses, fn(cl) {
    case cl {
      Plain(p, _, v) -> [p, ..rhs_paths(v)]
      model.Setting(_, v) -> rhs_paths(v)
      model.Flag(_) -> []
    }
  })
}

fn decl_paths(d: Decl) -> List(List(String)) {
  list.flatten([
    block_paths(d.preds),
    list.flat_map(d.positions, fn(p) { block_paths(p.preds) }),
    list.flat_map(d.fields, fn(f) {
      list.append(block_paths(f.preds), case f.mapping {
        Some(m) -> list.flat_map(m.cases, fn(cs) { block_paths(cs.preds) })
        None -> []
      })
    }),
  ])
}

/// The declarations that can hold a value of type x: they use it as a field,
/// item or position type, or filter by it in a path.
fn holders(c: Ctx, x: String) -> List(String) {
  let typed = fn(its: List(Item)) { list.contains(its, TypeItem(x)) }
  dict.values(c.decls)
  |> list.filter(fn(d) {
    typed(d.items)
    || list.any(d.positions, fn(p) { typed(p.items) })
    || list.any(d.fields, fn(f) { typed(f.items) })
    || list.any(decl_paths(d), fn(p) { list.contains(list.drop(p, 1), x) })
  })
  |> list.map(fn(d) { d.name })
  |> list.sort(string.compare)
}

/// A type that holds x without a u around it, if there is one.
fn escape(c: Ctx, x: String, u: String, seen: List(String)) -> Option(String) {
  case x == u || list.contains(seen, x) {
    True -> None
    False ->
      case list.filter(holders(c, x), fn(h) { h != x }) {
        [] -> Some(x)
        hs ->
          list.find_map(hs, fn(h) {
            option.to_result(escape(c, h, u, [x, ..seen]), Nil)
          })
          |> option.from_result
      }
  }
}

/// A path that starts with a type reaches the nearest record of that type
/// around this one, so the type using it must always sit inside one.
fn check_context(c: Ctx, d: Decl) -> Nil {
  decl_paths(d)
  |> list.filter_map(fn(p) {
    case p {
      [h, _, ..] if h != d.name ->
        case is_upper_start(h), dict.get(c.decls, h) {
          True, Ok(u) if u.kind == model.Record -> Ok(#(h, string.join(p, ".")))
          _, _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> list.unique
  |> list.each(fn(hp) {
    let #(u, path) = hp
    case escape(c, d.name, u, []) {
      None -> Nil
      Some(root) ->
        err(
          c,
          d,
          0,
          "'"
            <> d.name
            <> "' reaches "
            <> path
            <> ", so it must always sit inside "
            <> article(u)
            <> u
            <> ", but "
            <> case root == d.name {
            True -> "nothing holds it inside one"
            False -> root <> " holds it without one around"
          },
          d.name,
        )
    }
  })
}

fn article(name: String) -> String {
  case string.first(string.lowercase(name)) {
    Ok("a") | Ok("e") | Ok("i") | Ok("o") | Ok("u") -> "an "
    _ -> "a "
  }
}

// ---------------------------------------------------------------- order

fn type_ok(
  c: Ctx,
  d: Decl,
  name: String,
  line: Int,
  recursive_ok: Bool,
) -> Nil {
  case list.contains(model.builtin_numeric, name) {
    True -> Nil
    False -> {
      let i = idx(c, name)
      let j = idx(c, d.name)
      case i < 0, name == d.name && !recursive_ok, i > j {
        True, _, _ -> err(c, d, line, "unknown type '" <> name <> "'", d.name)
        _, True, _ ->
          err(
            c,
            d,
            line,
            "'"
              <> d.name
              <> "' refers to itself; only a record field may, as a list whose count starts at 0",
            d.name,
          )
        _, _, True -> {
          let assert Ok(other) = dict.get(c.decls, name)
          err(
            c,
            d,
            line,
            "type '"
              <> name
              <> "' is used before it is declared (line "
              <> int.to_string(other.line)
              <> "); a name resolves only to a type declared above",
            d.name,
          )
        }
        _, _, _ -> Nil
      }
    }
  }
}

fn check_decl(c: Ctx, d: Decl) -> Nil {
  check_context(c, d)
  check_refine_numbers(c, d)
  list.each(d.items, fn(it) {
    case it {
      TypeItem(n) -> type_ok(c, d, n, d.line, False)
      _ -> Nil
    }
  })
  list.each(d.positions, fn(p) {
    list.each(p.items, fn(it) {
      case it {
        TypeItem(n) -> type_ok(c, d, n, p.line, False)
        _ -> Nil
      }
    })
    check_settings(c, d, p.preds, p.line, False)
  })
  case d.kind {
    model.Refine | model.Layout -> {
      check_settings(c, d, d.preds, d.line, evaluate.is_numeric(c.ev, d.name))
      list.each(model.plains(d.preds), fn(cl) {
        let assert Plain(p, _, v) = cl
        check_path(c, d, None, p, d.line, [])
        list.each(rhs_paths(v), fn(vp) {
          case vp {
            [h, _, ..] ->
              case is_upper_start(h) {
                True -> check_path(c, d, None, vp, d.line, [])
                False -> Nil
              }
            _ -> Nil
          }
        })
      })
    }
    _ -> Nil
  }
  case d.kind, d.items {
    model.Layout, [TypeItem(b)] ->
      case list.contains(model.builtin_numeric, b) {
        True -> check_conversion(c, d)
        False -> Nil
      }
    _, _ -> Nil
  }
  case d.kind {
    model.Record -> check_record(c, d)
    _ -> Nil
  }
}

fn check_settings(
  c: Ctx,
  d: Decl,
  b: model.Block,
  line: Int,
  numeric: Bool,
) -> Nil {
  list.each(model.settings(b), fn(s) {
    let #(k, v) = s
    case { k == "places" || k == "mod" } && !numeric {
      True ->
        err(c, d, line, "'" <> k <> "=' applies only to numeric values", d.name)
      False -> Nil
    }
    // 'mod' divides, so its divisor must be known to be positive: a written
    // number above 0 (docs/geometric.md, partial operations need a guard).
    case k, v {
      "mod", VNum(n) ->
        case decimal.compare(n.value, decimal.zero()) == order.Gt {
          True -> Nil
          False -> err(c, d, line, mod_message(), d.name)
        }
      "mod", _ -> err(c, d, line, mod_message(), d.name)
      _, _ -> Nil
    }
  })
}

fn mod_message() -> String {
  "'mod =' needs a positive number written out, e.g. mod = 7: "
  <> "a zero, negative or computed divisor has no guard"
}

/// The written divisor of a field's 'mod', when it has one.
fn mod_of(f: Field) -> Option(Decimal) {
  case model.setting(f.preds, "mod") {
    Some(VNum(n)) -> Some(n.value)
    _ -> None
  }
}

fn digit_capacity(d: Decl) -> Option(Int) {
  list.try_fold(d.positions, 0, fn(n, p) {
    case list.all(p.items, fn(i) { is_str(i) }) {
      True -> Ok(n)
      False ->
        case model.setting(p.preds, "qty") {
          None -> Ok(n + 1)
          Some(VNum(q)) -> Ok(n + decimal.to_int(q.value))
          Some(VRange(_, Some(h))) -> Ok(n + decimal.to_int(h.value))
          _ -> Error(Nil)
        }
    }
  })
  |> option.from_result
}

fn is_str(i: Item) -> Bool {
  case i {
    StrItem(_) -> True
    _ -> False
  }
}

fn pow10_minus1(n: Int) -> Decimal {
  let assert Ok(d) = decimal.parse(string.repeat("9", n))
  case n {
    0 -> decimal.zero()
    _ -> d
  }
}

/// The 'val' range must fit what the layout holds.
fn check_conversion(c: Ctx, d: Decl) -> Nil {
  case digit_capacity(d) {
    None -> Nil
    Some(n) -> {
      let cap = pow10_minus1(n)
      list.each(model.plains(d.preds), fn(cl) {
        case cl {
          Plain(["val"], _, VRange(_, Some(h))) ->
            case decimal.lt(cap, h.value) {
              True ->
                err(
                  c,
                  d,
                  d.line,
                  "the val range does not fit what the layout holds (at most "
                    <> decimal.to_string(cap)
                    <> ")",
                  d.name,
                )
              False -> Nil
            }
          _ -> Nil
        }
      })
    }
  }
}

// ---------------------------------------------------------------- records

fn check_record(c: Ctx, d: Decl) -> Nil {
  list.fold(d.fields, [], fn(seen, f) {
    let where = d.name <> "." <> f.name
    case f.role {
      model.Constant ->
        err(
          c,
          d,
          f.line,
          "'"
            <> f.name
            <> " {Needs}' has no condition, so it would always hold; give it one, e.g. "
            <> f.name
            <> " {Needs} total >= 0",
          where,
        )
      _ -> Nil
    }
    case list.contains(model.reserved, f.name) {
      True ->
        err(
          c,
          d,
          f.line,
          "'"
            <> f.name
            <> "' is reserved ("
            <> string.join(model.reserved, ", ")
            <> ") and cannot name a field",
          where,
        )
      False -> Nil
    }
    case list.contains(seen, f.name) {
      True ->
        err(c, d, f.line, "field '" <> f.name <> "' is declared twice", where)
      False -> Nil
    }
    list.each(f.items, fn(it) {
      case it {
        TypeItem(n) -> {
          let rec_ok =
            n == d.name
            && case model.qty(f) {
              Some(#(Some(lo), _)) -> decimal.is_zero(lo.value)
              _ -> False
            }
          case n == d.name && !rec_ok {
            True ->
              err(
                c,
                d,
                f.line,
                "a record may use its own type only as a list whose count starts at 0, e.g. {Node 0..} or {Chain 0..1}",
                where,
              )
            False -> type_ok(c, d, n, f.line, rec_ok)
          }
        }
        _ -> Nil
      }
    })
    let numeric = evaluate.items_numeric(c.ev, f.items)
    check_settings(c, d, f.preds, f.line, numeric)
    case f.role != model.Stored && option.is_some(model.qty(f)) {
      True ->
        err(
          c,
          d,
          f.line,
          "a computed field holds one number, TRUE or FALSE, never a list: drop the count in its braces",
          where,
        )
      False -> Nil
    }
    case
      f.role == model.Computed && !numeric && !is_truth_value(model.base(f))
    {
      True ->
        err(
          c,
          d,
          f.line,
          "a computed field produces a number, TRUE or FALSE, never text, a record or a sequence",
          where,
        )
      False -> Nil
    }
    list.each(f.preds.clauses, fn(cl) {
      case model.relation_of(d, cl) {
        Some(rel) -> check_relation(c, d, f, rel)
        None -> Nil
      }
    })
    list.each(
      list.filter(f.preds.clauses, fn(cl) {
        option.is_none(model.relation_of(d, cl))
      }),
      fn(cl) {
        case cl {
          Plain(p, op, v) -> {
            check_path(c, d, Some(f), p, f.line, seen)
            let vs = case v {
              VMulti(xs) -> xs
              _ -> [v]
            }
            list.each(vs, fn(x) { check_value_paths(c, d, f, x, f.line, seen) })
            case v, op {
              VRange(..), o | VMulti(..), o if o != "=" ->
                err(
                  c,
                  d,
                  f.line,
                  "a range or a choice of values is compared with '=' (membership)",
                  where,
                )
              _, _ -> Nil
            }
          }
          Setting(k, v) if k == "qty" || k == "mod" || k == "places" ->
            check_value_paths(c, d, f, v, f.line, seen)
          _ -> Nil
        }
      },
    )
    case f.mapping {
      Some(_) -> check_mapping(c, d, f, seen)
      None -> Nil
    }
    check_numbers(c, d, f)
    case f.role {
      model.Claim -> prove_claim(c, d, f)
      model.Computed -> {
        case model.setting(f.preds, "round") {
          Some(rule) -> check_rounding(c, d, f, rule)
          None -> check_places(c, d, f)
        }
        check_recursive_products(c, d, f)
      }
      _ -> Nil
    }
    list.append(seen, [f.name])
  })
  cost_record(c, d)
}

/// A relation is a rule on a line of its own, '{Needs} (orders.customer in
/// customers.code)': each item of the left list matches some item of the
/// right list, and exactly one when the right list has 'unique: code'.
fn check_relation(c: Ctx, d: Decl, f: Field, rel: model.Relation) -> Nil {
  let where = d.name <> "." <> f.name
  let left = rel.left_list.name <> "." <> rel.left_field
  let right = rel.right_list.name <> "." <> rel.right_field
  let bad = fn(msg) { err(c, d, f.line, msg, where) }
  let example = f.name <> " {Needs} (" <> left <> " in " <> right <> ")"
  let item_of = fn(l: Field) { model.record_of(c.decls, item_name(l)) }
  case f.role, rel.op, list.length(f.preds.clauses) {
    model.Claim, _, _ ->
      bad("a relation between two lists is a rule, not a claim: " <> example)
    _, o, _ if o != "=" ->
      bad(
        "two lists are related with in only: each item of "
        <> rel.left_list.name
        <> " matches an item of "
        <> rel.right_list.name
        <> ", "
        <> example,
      )
    _, _, n if n != 1 ->
      bad(
        "a relation between two lists is a line of its own, with no other condition: "
        <> example,
      )
    _, _, _ ->
      case rel.left_list.name == rel.right_list.name {
        True -> bad("a relation is between two different lists: " <> example)
        False ->
          case item_of(rel.left_list), item_of(rel.right_list) {
            Some(li), Some(ri) ->
              case
                model.field(li, rel.left_field),
                model.field(ri, rel.right_field)
              {
                Some(lf), Some(rf) -> {
                  let scalar = fn(x: Field) {
                    option.is_none(model.qty(x))
                    && case model.base(x) {
                      TypeItem(t) -> option.is_none(model.record_of(c.decls, t))
                      _ -> True
                    }
                  }
                  let same_kind =
                    model.base(lf) == model.base(rf)
                    || {
                      evaluate.items_numeric(c.ev, lf.items)
                      && evaluate.items_numeric(c.ev, rf.items)
                    }
                  case scalar(lf) && scalar(rf), same_kind {
                    False, _ ->
                      bad(
                        left
                        <> " and "
                        <> right
                        <> " are compared as single numbers or texts: neither may be a list or a record",
                      )
                    _, False ->
                      bad(
                        left
                        <> " is "
                        <> model.item_text(model.base(lf))
                        <> " but "
                        <> right
                        <> " is "
                        <> model.item_text(model.base(rf))
                        <> ": a relation compares fields of the same type",
                      )
                    _, _ -> Nil
                  }
                }
                None, _ ->
                  bad(
                    "'"
                    <> li.name
                    <> "' has no field '"
                    <> rel.left_field
                    <> "'",
                  )
                _, None ->
                  bad(
                    "'"
                    <> ri.name
                    <> "' has no field '"
                    <> rel.right_field
                    <> "'",
                  )
              }
            _, _ ->
              bad(
                "a relation is between two lists of records: "
                <> rel.left_list.name
                <> " and "
                <> rel.right_list.name
                <> " must each be a list of one record type",
              )
          }
      }
  }
}

fn is_truth_value(i: Item) -> Bool {
  case i {
    TypeItem("True") | TypeItem("False") -> True
    _ -> False
  }
}

fn check_value_paths(
  c: Ctx,
  d: Decl,
  f: Field,
  v: Value,
  line: Int,
  seen: List(String),
) -> Nil {
  case v {
    VPath(p) -> check_path(c, d, Some(f), p, line, seen)
    VArith(_, ts) ->
      list.each(ts, fn(t) { check_value_paths(c, d, f, t, line, seen) })
    VFilter(p, conditions) -> {
      check_path(c, d, Some(f), p, line, seen)
      check_filter(c, d, f, p, conditions, line)
    }
    _ -> Nil
  }
}

/// A filter's conditions name fields of the items of the list it folds, and
/// compare each with a number, a text or a range. They are checked as the
/// conditions of a refinement of the item type.
fn check_filter(
  c: Ctx,
  d: Decl,
  f: Field,
  p: List(String),
  conditions: model.Block,
  line: Int,
) -> Nil {
  let assert [list_name, ..] = p
  let where = d.name <> "." <> f.name
  case model.field(d, list_name) {
    Some(lf) ->
      case model.base(lf), model.record_of(c.decls, item_name(lf)) {
        TypeItem(t), Some(_) -> {
          let synthetic =
            Decl(
              t <> " (a filter)",
              model.Refine,
              line,
              d.file,
              [TypeItem(t)],
              conditions,
              [],
              [],
              "",
              "",
              [],
            )
          list.each(model.plains(conditions), fn(cl) {
            let assert Plain(cp, _, _) = cl
            check_path(c, synthetic, None, cp, line, [])
          })
          check_refine_numbers(c, synthetic)
        }
        _, _ ->
          err(
            c,
            d,
            line,
            "a kept list keeps some items of a list of records, and '"
              <> list_name
              <> "' is not one",
            where,
          )
      }
    None -> Nil
  }
}

fn item_name(f: Field) -> String {
  case model.base(f) {
    TypeItem(t) -> t
    _ -> ""
  }
}

fn check_path(
  c: Ctx,
  d: Decl,
  f: Option(Field),
  p: List(String),
  line: Int,
  above: List(String),
) -> Nil {
  let where = case f {
    Some(fl) -> d.name <> "." <> fl.name
    None -> d.name
  }
  let assert [head, ..] = p
  let outer = case p, is_upper_start(head) {
    [_, step, ..], True ->
      case dict.get(c.decls, head) {
        Ok(u) if u.kind == model.Record -> Ok(Ok(u))
        Ok(_) -> Ok(Error(step))
        Error(_) -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
  case head == "val", outer {
    True, _ -> Nil
    // the nearest record of that type around this one (Step 3, Context)
    _, Ok(Ok(u)) -> walk(c, d, f, list.drop(p, 1), line, u)
    _, Ok(Error(step)) ->
      err(
        c,
        d,
        line,
        "'"
          <> head
          <> "' is not a record, so '"
          <> head
          <> "."
          <> step
          <> "' names nothing; a path that starts with a type reaches a record around this one",
        where,
      )
    _, _ -> check_path_inner(c, d, f, p, line, above, where, head)
  }
}

fn check_path_inner(
  c: Ctx,
  d: Decl,
  f: Option(Field),
  p: List(String),
  line: Int,
  above: List(String),
  where: String,
  head: String,
) -> Nil {
  case head == "val", is_upper_start(head) {
    True, _ -> Nil
    _, True -> {
      let i = idx(c, head)
      case i < 0, i >= idx(c, d.name), evaluate.singleton(c.ev, head), p {
        True, _, _, _ ->
          err(c, d, line, "unknown type '" <> head <> "' in a path", where)
        _, True, _, _ ->
          err(
            c,
            d,
            line,
            "type '" <> head <> "' is not declared above this line",
            where,
          )
        _, _, None, [_] ->
          err(
            c,
            d,
            line,
            "type '"
              <> head
              <> "' has more than one inhabitant, so it is not a value",
            where,
          )
        _, _, _, _ -> Nil
      }
    }
    _, _ ->
      case d.kind {
        model.Record ->
          case model.field(d, head), f {
            None, _ -> err(c, d, line, "unknown field '" <> head <> "'", where)
            Some(_), Some(fl) if fl.name == head ->
              err(
                c,
                d,
                line,
                "field '" <> fl.name <> "' cannot refer to itself",
                where,
              )
            Some(_), Some(fl) ->
              case list.contains(above, head) {
                False ->
                  err(
                    c,
                    d,
                    line,
                    "field '"
                      <> head
                      <> "' is declared below '"
                      <> fl.name
                      <> "'; a field may name only fields above it",
                    where,
                  )
                True -> walk(c, d, f, p, line, d)
              }
            Some(_), None -> walk(c, d, f, p, line, d)
          }
        _ -> {
          // a refinement used as a filter: its conditions name the fields
          let base = case d.items {
            [TypeItem(b)] -> model.record_of(c.decls, b)
            _ -> None
          }
          case base {
            Some(bd) ->
              case model.field(bd, head) {
                Some(_) -> walk(c, d, f, p, line, bd)
                None ->
                  err(c, d, line, "'" <> head <> "' is not a field here", where)
              }
            None ->
              err(c, d, line, "'" <> head <> "' is not a field here", where)
          }
        }
      }
  }
}

type WalkState {
  NotSeq
  Opt
  InSeq
}

fn walk(
  c: Ctx,
  d: Decl,
  f: Option(Field),
  p: List(String),
  line: Int,
  record: Decl,
) -> Nil {
  let where = case f {
    Some(fl) -> d.name <> "." <> fl.name
    None -> d.name
  }
  let last = list.length(p) - 1
  let init: #(Option(Decl), Option(Field), WalkState, Bool) = #(
    Some(record),
    None,
    NotSeq,
    False,
  )
  let r =
    list.index_fold(p, init, fn(st, step, i) {
      let #(rec, fld, state, stop) = st
      case stop {
        True -> st
        False ->
          case i > 0 && list.contains(model.folds, step) {
            True -> {
              case state == NotSeq {
                True ->
                  err(
                    c,
                    d,
                    line,
                    "'."
                      <> method_name(step)
                      <> "' reads a list, but "
                      <> string.join(list.take(p, i), ".")
                      <> " is not one",
                    where,
                  )
                False -> Nil
              }
              case i != last {
                True ->
                  err(
                    c,
                    d,
                    line,
                    "a method ends the path ('." <> method_name(step) <> "')",
                    where,
                  )
                False -> Nil
              }
              case step, fld {
                "sum", Some(fl) ->
                  case evaluate.items_numeric(c.ev, fl.items) {
                    False ->
                      err(c, d, line, "'.sum' totals a numeric field", where)
                    True -> Nil
                  }
                _, _ -> Nil
              }
              #(rec, fld, Opt, True)
            }
            False -> {
              let no_fields = fn() {
                err(
                  c,
                  d,
                  line,
                  "'" <> string.join(list.take(p, i), ".") <> "' has no fields",
                  where,
                )
                #(None, None, NotSeq, True)
              }
              case rec, i > 0 && is_upper_start(step) {
                // a type name in a path: the old way to keep some items
                Some(rd), True -> {
                  err(
                    c,
                    d,
                    line,
                    "'"
                      <> string.join(list.take(p, i + 1), ".")
                      <> "': a path holds only fields, and a type cannot narrow a list. To keep some of the items, give "
                      <> rd.name
                      <> " a field with cases and keep the items on a line of their own, e.g. ("
                      <> string.join(list.take(p, i), ".")
                      <> ".field = True)",
                    where,
                  )
                  #(None, None, NotSeq, True)
                }
                // a field of a record, or of the record under a filter
                Some(rd), False ->
                  case model.record_of(c.decls, rd.name) {
                    None -> no_fields()
                    Some(rr) ->
                      walk_field(c, d, line, where, rd, rr, step, state)
                  }
                _, _ -> no_fields()
              }
            }
          }
      }
    })
  let #(_, _, state, stopped) = r
  case state == InSeq && !stopped {
    True ->
      err(
        c,
        d,
        line,
        string.join(p, ".")
          <> " is a list: read it with a method, .count or .sum",
        where,
      )
    False -> Nil
  }
}

/// One field step of a path: the field of record 'rr', reached through a
/// value of type 'rd' (the record itself, or a filter of it).
fn walk_field(
  c: Ctx,
  d: Decl,
  line: Int,
  where: String,
  rd: Decl,
  rr: Decl,
  step: String,
  state: WalkState,
) -> #(Option(Decl), Option(Field), WalkState, Bool) {
  case model.field(rr, step) {
    None -> {
      err(
        c,
        d,
        line,
        "'" <> rd.name <> "' has no field '" <> step <> "'",
        where,
      )
      #(None, None, NotSeq, True)
    }
    Some(fl) -> {
      let state = case model.qty(fl) {
        None -> state
        Some(#(_, hi)) ->
          case hi, state {
            Some(h), NotSeq ->
              case decimal.le(h.value, decimal.from_int(1)) {
                True -> Opt
                False -> InSeq
              }
            _, _ -> InSeq
          }
      }
      let next = case model.base(fl) {
        TypeItem(t) -> option.from_result(dict.get(c.decls, t))
        _ -> None
      }
      #(next, Some(fl), state, False)
    }
  }
}

// ---------------------------------------------------------------- recursion rule

fn check_recursive_products(c: Ctx, d: Decl, f: Field) -> Nil {
  let rec_fields =
    list.filter_map(d.fields, fn(x) {
      case model.base(x) == TypeItem(d.name) {
        True -> Ok(x.name)
        False -> Error(Nil)
      }
    })
  case definition(f) {
    Some(VArith("*", terms)) -> {
      let n =
        list.count(terms, fn(t) {
          case t {
            VPath([h, ..]) -> list.contains(rec_fields, h)
            _ -> False
          }
        })
      case n > 1 {
        True ->
          err(
            c,
            d,
            f.line,
            "a product may read at most one factor through a recursive field (this would double the size of the number at every level)",
            d.name <> "." <> f.name,
          )
        False -> Nil
      }
    }
    Some(VArith("/", [a, b])) -> {
      let through = fn(t) {
        case t {
          VPath([h, ..]) -> list.contains(rec_fields, h)
          _ -> False
        }
      }
      case through(a) && through(b) {
        True ->
          err(
            c,
            d,
            f.line,
            "a quotient may not read both its dividend and its divisor through a recursive field",
            d.name <> "." <> f.name,
          )
        False -> Nil
      }
    }
    _ -> Nil
  }
}

// ---------------------------------------------------------------- places

fn places(c: Ctx, d: Decl, v: Value, seen: List(String)) -> Option(Int) {
  case v {
    VNum(n) -> Some(n.value.places)
    VArith(op, terms) -> {
      let ps = list.map(terms, fn(t) { places(c, d, t, seen) })
      case list.all(ps, option.is_some) {
        False -> None
        True -> {
          let xs = option.values(ps)
          case op {
            "*" -> Some(int.sum(xs))
            _ -> list.reduce(xs, int.max) |> option.from_result
          }
        }
      }
    }
    VPath(parts) -> {
      let last = list.last(parts) |> option.from_result
      case last {
        Some("qty") -> Some(0)
        _ ->
          case parts {
            [name] ->
              case model.field(d, name) {
                Some(fl) -> {
                  let rounded = model.setting(fl.preds, "round") != None
                  case
                    model.field_places(c.decls, fl),
                    fl.role,
                    definition(fl)
                  {
                    Some(VNum(pl)), _, _ -> Some(decimal.to_int(pl.value))
                    _, model.Computed, Some(_) if rounded ->
                      rounded_places(c, fl)
                    _, model.Computed, Some(def) ->
                      case list.contains(seen, name) {
                        True -> None
                        False -> places(c, d, def, [name, ..seen])
                      }
                    _, _, _ ->
                      case model.base(fl) {
                        TypeItem("Integer") | TypeItem("Integer_Literal") ->
                          Some(0)
                        _ -> None
                      }
                  }
                }
                None -> None
              }
            _ -> None
          }
      }
    }
    _ -> None
  }
}

// ---------------------------------------------------------------- numbers

type Kind {
  Number
  NotNumber(what: String)
  Unknown
}

/// What a path holds, as far as arithmetic is concerned. Folds give numbers;
/// a field is a number when its type is numeric.
fn path_kind(c: Ctx, d: Decl, parts: List(String)) -> Kind {
  case list.last(parts) {
    Ok("qty") | Ok("sum") -> Number
    _ ->
      case parts {
        ["val", ..] -> Unknown
        [head, ..rest] ->
          case model.field(d, head), rest, dict.get(c.decls, head) {
            None, [_, ..], Ok(u) if u.kind == model.Record ->
              path_kind(c, u, rest)
            None, _, _ -> Unknown
            Some(fl), _, _ ->
              field_kind(c, fl, list.filter(rest, fn(x) { !is_upper_start(x) }))
          }
        [] -> Unknown
      }
  }
}

fn field_kind(c: Ctx, fl: Field, rest: List(String)) -> Kind {
  case rest {
    [] ->
      case fl.role {
        model.Rule | model.Claim | model.Constant -> NotNumber("TRUE or FALSE")
        model.MappingRole ->
          case evaluate.items_numeric(c.ev, fl.items) {
            True -> Number
            False -> NotNumber(model.items_text(fl.items))
          }
        _ ->
          case evaluate.items_numeric(c.ev, fl.items) {
            True -> Number
            False ->
              case fl.items {
                [TypeItem(t)] ->
                  case model.record_of(c.decls, t) {
                    Some(_) -> NotNumber("a record")
                    None -> NotNumber(model.items_text(fl.items))
                  }
                _ -> NotNumber(model.items_text(fl.items))
              }
          }
      }
    [next, ..more] ->
      case fl.items {
        [TypeItem(t)] ->
          case model.record_of(c.decls, t) {
            Some(dd) ->
              case model.field(dd, next) {
                Some(f2) -> field_kind(c, f2, more)
                None -> Unknown
              }
            None -> Unknown
          }
        _ -> Unknown
      }
  }
}

fn value_kinds(c: Ctx, d: Decl, v: Value) -> List(#(String, Kind)) {
  case v {
    VPath(p) -> [#(string.join(p, "."), path_kind(c, d, p))]
    VStr(t) -> [#(model.quote(t), NotNumber("text"))]
    VNum(_) -> []
    VArith(_, ts) -> list.flat_map(ts, value_kinds(c, d, _))
    _ -> []
  }
}

/// Arithmetic and ordering need numbers: 'b * 2' or 'b >= 1' with b a text
/// is a compile error, not a failure at run time.
fn check_numbers(c: Ctx, d: Decl, f: Field) -> Nil {
  let where = d.name <> "." <> f.name
  let complain = fn(what: String, kind: String, why: String) {
    err(
      c,
      d,
      f.line,
      what <> " is " <> kind <> ", not a number, so it cannot be " <> why,
      where,
    )
  }
  let in_arith = fn(v: Value) {
    case v {
      VArith(op, _) ->
        list.each(value_kinds(c, d, v), fn(k) {
          case k.1 {
            NotNumber(kind) ->
              complain(k.0, kind, case op {
                "+" -> "added"
                "-" -> "subtracted"
                "/" -> "divided"
                _ -> "multiplied"
              })
            _ -> Nil
          }
        })
      _ -> Nil
    }
  }
  list.each(model.plains(f.preds), fn(cl) {
    let assert Plain(path, op, v) = cl
    in_arith(v)
    case op {
      "<" | "<=" | ">" | ">=" ->
        list.each(
          list.append(
            case path {
              ["val"] ->
                case evaluate.items_numeric(c.ev, f.items) {
                  True -> []
                  False -> [#("val", NotNumber(model.items_text(f.items)))]
                }
              _ -> [#(string.join(path, "."), path_kind(c, d, path))]
            },
            value_kinds(c, d, v),
          ),
          fn(k) {
            case k.1 {
              NotNumber(kind) -> complain(k.0, kind, "compared with " <> op)
              _ -> Nil
            }
          },
        )
      _ -> Nil
    }
  })
}

/// The same for the conditions of a filter: they name the fields of the item
/// type, so 'filter: lines.n > 5' needs n to be a number.
fn check_refine_numbers(c: Ctx, d: Decl) -> Nil {
  case d.kind, d.items {
    model.Refine, [TypeItem(b)] ->
      case model.record_of(c.decls, b) {
        Some(bd) ->
          list.each(model.plains(d.preds), fn(cl) {
            let assert Plain(path, op, v) = cl
            let kinds = case op {
              "<" | "<=" | ">" | ">=" ->
                list.append(
                  [#(string.join(path, "."), path_kind(c, bd, path))],
                  value_kinds(c, bd, v),
                )
              _ ->
                case v {
                  VArith(..) -> value_kinds(c, bd, v)
                  _ -> []
                }
            }
            list.each(kinds, fn(k) {
              case k.1 {
                NotNumber(kind) ->
                  err(
                    c,
                    d,
                    d.line,
                    k.0
                      <> " is "
                      <> kind
                      <> ", not a number, so it cannot be "
                      <> case op {
                      "=" -> "used in arithmetic"
                      _ -> "compared with " <> op
                    },
                    d.name,
                  )
                _ -> Nil
              }
            })
          })
        _ -> Nil
      }
    _, _ -> Nil
  }
}

fn check_places(c: Ctx, d: Decl, f: Field) -> Nil {
  case model.field_places(c.decls, f), definition(f) {
    Some(VNum(pl)), Some(def) ->
      case places(c, d, def, []) {
        Some(got) ->
          case got > decimal.to_int(pl.value) {
            True ->
              err(
                c,
                d,
                f.line,
                "the value has "
                  <> int.to_string(got)
                  <> " decimal places but the field holds "
                  <> pl.text
                  <> "; rounding never happens implicitly: add round: with the unit to round to, e.g. round: 0.01",
                d.name <> "." <> f.name,
              )
            False -> Nil
          }
        None -> Nil
      }
    _, _ -> Nil
  }
}

// ---------------------------------------------------------------- rounding

/// The places a rounded field rounds to: its 'places:', the places of its
/// type, or 0 for an integer.
fn rounded_places(c: Ctx, f: Field) -> Option(Int) {
  case model.field_places(c.decls, f) {
    Some(VNum(pl)) -> Some(decimal.to_int(pl.value))
    _ ->
      case integer_type(c, model.base(f)) {
        True -> Some(0)
        False -> None
      }
  }
}

/// 'round:' names a rounding rule (Step 5). The field says its places; a
/// calculation that is not a quotient rounds only when it may need more
/// places than the field holds; a quotient's divisor is never 0.
fn check_rounding(c: Ctx, d: Decl, f: Field, rule: Value) -> Nil {
  let where = d.name <> "." <> f.name
  let complain = fn(msg) { err(c, d, f.line, msg, where) }
  case rule {
    VPath([name]) ->
      case rounding_rule(c, name) {
        Ok(_) -> Nil
        Error(why) -> complain(why)
      }
    _ -> complain("round: takes the unit to round to, e.g. round: 0.01")
  }
  let n = rounded_places(c, f)
  case n {
    None ->
      complain(
        "a rounded field takes its places from its round: unit, e.g. round: 0.01",
      )
    Some(_) -> Nil
  }
  case definition(f), n {
    Some(VArith("/", [_, divisor])), _ -> check_divisor(c, d, f, divisor)
    Some(def), Some(n) ->
      case places(c, d, def, []) {
        Some(got) if got <= n ->
          complain(
            "nothing to round: the calculation has at most "
            <> int.to_string(got)
            <> " decimal places and the field holds "
            <> int.to_string(n)
            <> ", so drop round:",
          )
        _ -> Nil
      }
    _, _ -> Nil
  }
}

/// A rounding rule is a record whose field 'direction' is a mapping on
/// remainder, odd and negative.
fn rounding_rule(c: Ctx, name: String) -> Result(model.Mapping, String) {
  let not_rule =
    "'"
    <> name
    <> "' is not a rounding rule: a rule is a record whose field direction {Direction} is a mapping on remainder, odd and negative (Half_Even, Half_Up, Half_Lower and Half_Higher are in the standard library)"
  case dict.get(c.decls, name) {
    Error(_) -> Error("round: names " <> name <> ", which is not declared")
    Ok(rd) ->
      case rd.kind, model.field(rd, "direction") {
        model.Record, Some(df) ->
          case df.mapping, model.base(df) {
            Some(m), TypeItem("Direction") ->
              case
                list.all(m.inputs, fn(i) {
                  list.contains(["remainder", "odd", "negative"], i)
                })
              {
                True -> Ok(m)
                False -> Error(not_rule)
              }
            _, _ -> Error(not_rule)
          }
        _, _ -> Error(not_rule)
      }
  }
}

/// The checker must prove a divisor is never 0, from its 'value:', its
/// choice of values or its count.
fn check_divisor(c: Ctx, d: Decl, f: Field, divisor: Value) -> Nil {
  case divisor_nonzero(c, d, divisor) {
    True -> Nil
    False -> {
      let #(lo, hi) = term_bounds(c, d, divisor)
      err(
        c,
        d,
        f.line,
        "cannot prove the divisor "
          <> model.value_text(divisor)
          <> " is never 0: it is only known to lie in ["
          <> bfmt(lo)
          <> ", "
          <> bfmt(hi)
          <> "]; give it allowed values or a type that leaves out 0",
        d.name <> "." <> f.name,
      )
    }
  }
}

fn divisor_nonzero(c: Ctx, d: Decl, divisor: Value) -> Bool {
  let #(lo, hi) = term_bounds(c, d, divisor)
  let nonzero = fn(v: Val) {
    case v {
      VNumber(x) -> !decimal.is_zero(x)
      _ -> False
    }
  }
  bsign(lo) > 0
  || bsign(hi) < 0
  || case divisor {
    VPath([name]) ->
      case model.field(d, name) {
        Some(fl) ->
          case evaluate.finite_values(c.ev, fl.items), value_choice(fl) {
            Some(vs), _ -> vs != [] && list.all(vs, nonzero)
            _, Some(vs) -> list.all(vs, nonzero)
            None, None -> False
          }
        None -> False
      }
    _ -> False
  }
}

/// The numbers a field's 'value:' chooses among, as in value: 10 | 30.
fn value_choice(fl: Field) -> Option(List(Val)) {
  list.find_map(model.plains(fl.preds), fn(cl) {
    case cl {
      Plain(["val"], "=", VMulti(xs)) ->
        list.try_map(xs, fn(x) {
          case x {
            VNum(n) -> Ok(VNumber(n.value))
            _ -> Error(Nil)
          }
        })
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// The bounds of one term of a calculation: a number, or a path.
fn term_bounds(c: Ctx, d: Decl, v: Value) -> #(B, B) {
  case v {
    VNum(n) -> #(Fin(n.value), Fin(n.value))
    VPath(parts) -> atom_bounds(c, d, string.join(parts, "."), None)
    _ -> #(NegInf, PosInf)
  }
}

/// The bounds of a calculation's exact value, by interval arithmetic; a
/// quotient's bounds are worked out to n places, outward.
fn value_bounds(c: Ctx, d: Decl, v: Value, n: Int) -> #(B, B) {
  case v {
    VArith("/", [a, b]) ->
      case divisor_nonzero(c, d, b) {
        True -> idiv(term_bounds(c, d, a), term_bounds(c, d, b), n)
        False -> #(NegInf, PosInf)
      }
    VArith(op, [first, ..rest]) ->
      list.fold(rest, value_bounds(c, d, first, n), fn(acc, t) {
        let b = value_bounds(c, d, t, n)
        case op {
          "+" -> #(badd(acc.0, b.0), badd(acc.1, b.1))
          "-" -> #(bsub(acc.0, b.1), bsub(acc.1, b.0))
          _ -> imul(acc, b)
        }
      })
    _ -> term_bounds(c, d, v)
  }
}

fn bsub(a: B, b: B) -> B {
  badd(a, bmul(b, Fin(decimal.from_int(-1))))
}

/// Dividing ranges, for a divisor whose range leaves out 0. For a divisor
/// above 0, x / y grows with x, and shrinks with y when x is not below 0
/// and grows with it otherwise, so each bound pairs one end of x with the
/// end of y that suits its sign; a divisor below 0 is the same with both
/// signs turned. Each bound is worked out to n places, the lower one down
/// and the upper one up, and a divisor without end gives 0.
fn idiv(x: #(B, B), y: #(B, B), n: Int) -> #(B, B) {
  case bsign(y.0) > 0, bsign(y.1) < 0 {
    True, _ -> {
      let lo = case bsign(x.0) >= 0 {
        True -> bdiv(x.0, y.1, n, False)
        False -> bdiv(x.0, y.0, n, False)
      }
      let hi = case bsign(x.1) >= 0 {
        True -> bdiv(x.1, y.0, n, True)
        False -> bdiv(x.1, y.1, n, True)
      }
      #(lo, hi)
    }
    _, True -> idiv(bneg_range(x), bneg_range(y), n)
    _, _ -> #(NegInf, PosInf)
  }
}

fn bneg_range(x: #(B, B)) -> #(B, B) {
  let neg = fn(b) { bmul(b, Fin(decimal.from_int(-1))) }
  #(neg(x.1), neg(x.0))
}

/// One bound divided by another, a divisor that is not 0, worked out to n
/// places down or up.
fn bdiv(a: B, b: B, n: Int, up: Bool) -> B {
  case a, b {
    Fin(p), Fin(q) -> {
      let assert Ok(cut) = decimal.divide(p, q, n)
      case cut.exact || up == cut.negative {
        True -> Fin(cut.kept)
        False -> Fin(decimal.away_from_zero(cut))
      }
    }
    Fin(_), _ -> d0()
    _, _ ->
      case bsign(a) * bsign(b) > 0 {
        True -> PosInf
        False -> NegInf
      }
  }
}

/// A rounded field is a value of its places within one unit of its last
/// place of the exact value, or half a unit when its rule rounds toward
/// zero below a half and away from zero above one.
fn rounded_bounds(
  c: Ctx,
  d: Decl,
  fl: Field,
  def: Value,
  rule: String,
) -> #(B, B) {
  case rounded_places(c, fl) {
    None -> #(NegInf, PosInf)
    Some(n) -> {
      let #(lo, hi) = value_bounds(c, d, def, n + 1)
      let half = rule_rounds_half(c, rule)
      let u = decimal.unit(n)
      let hu = decimal.half(u)
      #(
        case lo, half {
          Fin(x), True -> Fin(decimal.ceiling_places(decimal.sub(x, hu), n))
          Fin(x), False -> Fin(decimal.floor_places(x, n))
          b, _ -> b
        },
        case hi, half {
          Fin(x), True -> Fin(decimal.floor_places(decimal.add(x, hu), n))
          Fin(x), False -> Fin(decimal.ceiling_places(x, n))
          b, _ -> b
        },
      )
    }
  }
}

/// A rule rounds within half a unit when, for every odd and negative, its
/// direction is toward zero for each remainder below 0.5 and away from
/// zero for each one above. Its cases are intervals, so the direction
/// changes only at the numbers they are written with: trying those
/// numbers and the points between them tries every remainder.
fn rule_rounds_half(c: Ctx, rule: String) -> Bool {
  case rounding_rule(c, rule) {
    Error(_) -> False
    Ok(m) -> {
      let half = decimal.half(decimal.from_int(1))
      let one = decimal.from_int(1)
      let marks =
        list.flat_map(m.cases, fn(cs) {
          list.flat_map(model.plains(cs.preds), fn(cl) {
            case cl {
              Plain(["remainder"], _, v) ->
                case v {
                  VNum(x) -> [x.value]
                  VRange(l, h) ->
                    list.map(option.values([l, h]), fn(x) { x.value })
                  VMulti(xs) ->
                    list.filter_map(xs, fn(x) {
                      case x {
                        VNum(y) -> Ok(y.value)
                        _ -> Error(Nil)
                      }
                    })
                  _ -> []
                }
              _ -> []
            }
          })
        })
      let marks =
        [decimal.zero(), half, one, ..marks]
        |> list.filter(fn(x) {
          decimal.le(decimal.zero(), x) && decimal.le(x, one)
        })
        |> list.sort(decimal.compare)
        |> dedupe_dec
      let between =
        list.window_by_2(marks)
        |> list.map(fn(p) { decimal.half(decimal.add(p.0, p.1)) })
      let remainders =
        list.append(marks, between)
        |> list.filter(fn(x) {
          decimal.lt(decimal.zero(), x) && decimal.lt(x, one)
        })
      let facts = [VText("TRUE"), VText("FALSE")]
      list.all(remainders, fn(r) {
        let want = case decimal.compare(r, half) {
          order.Lt -> Some("toward_zero")
          order.Gt -> Some("away_from_zero")
          order.Eq -> None
        }
        list.all(facts, fn(odd) {
          list.all(facts, fn(negative) {
            let got =
              evaluate.direction_at(c.ev, m, [
                #("remainder", VNumber(r)),
                #("odd", odd),
                #("negative", negative),
              ])
            case want, got {
              None, Ok(_) -> True
              Some(w), Ok(g) -> w == g
              _, Error(_) -> False
            }
          })
        })
      })
    }
  }
}

// ---------------------------------------------------------------- bounds

pub type B {
  NegInf
  Fin(Decimal)
  PosInf
}

fn bcmp(a: B, b: B) -> order.Order {
  case a, b {
    NegInf, NegInf | PosInf, PosInf -> order.Eq
    NegInf, _ -> order.Lt
    _, NegInf -> order.Gt
    PosInf, _ -> order.Gt
    _, PosInf -> order.Lt
    Fin(x), Fin(y) -> decimal.compare(x, y)
  }
}

fn bmax(a: B, b: B) -> B {
  case bcmp(a, b) {
    order.Lt -> b
    _ -> a
  }
}

fn bmin(a: B, b: B) -> B {
  case bcmp(a, b) {
    order.Gt -> b
    _ -> a
  }
}

fn badd(a: B, b: B) -> B {
  case a, b {
    Fin(x), Fin(y) -> Fin(decimal.add(x, y))
    PosInf, _ | _, PosInf -> PosInf
    _, _ -> NegInf
  }
}

fn bsign(a: B) -> Int {
  case a {
    NegInf -> -1
    PosInf -> 1
    Fin(x) ->
      case decimal.compare(x, decimal.zero()) {
        order.Lt -> -1
        order.Eq -> 0
        order.Gt -> 1
      }
  }
}

fn bmul(a: B, b: B) -> B {
  case a, b {
    Fin(x), Fin(y) -> Fin(decimal.mul(x, y))
    _, _ ->
      case bsign(a) * bsign(b) {
        0 -> Fin(decimal.zero())
        1 -> PosInf
        _ -> NegInf
      }
  }
}

fn imul(x: #(B, B), y: #(B, B)) -> #(B, B) {
  let cs = [bmul(x.0, y.0), bmul(x.0, y.1), bmul(x.1, y.0), bmul(x.1, y.1)]
  let assert Ok(lo) = list.reduce(cs, bmin)
  let assert Ok(hi) = list.reduce(cs, bmax)
  #(lo, hi)
}

fn bfmt(b: B) -> String {
  case b {
    NegInf -> "-∞"
    PosInf -> "∞"
    Fin(x) -> decimal.to_short(x)
  }
}

fn d0() -> B {
  Fin(decimal.zero())
}

fn field_bounds(c: Ctx, fl: Field) -> #(B, B) {
  let def = definition(fl)
  let #(lo, hi) =
    list.fold(model.plains(fl.preds), #(NegInf, PosInf), fn(acc, cl) {
      let #(lo, hi) = acc
      case cl {
        Plain(["val"], op, v) ->
          case v, op {
            VRange(l, h), "=" -> #(
              case l {
                Some(n) -> bmax(lo, Fin(n.value))
                None -> lo
              },
              case h {
                Some(n) -> bmin(hi, Fin(n.value))
                None -> hi
              },
            )
            VNum(n), ">=" | VNum(n), ">" -> #(bmax(lo, Fin(n.value)), hi)
            VNum(n), "<=" | VNum(n), "<" -> #(lo, bmin(hi, Fin(n.value)))
            VNum(n), "=" ->
              case def == Some(v) {
                True -> acc
                False -> #(bmax(lo, Fin(n.value)), bmin(hi, Fin(n.value)))
              }
            _, _ -> acc
          }
        _ -> acc
      }
    })
  let #(tl, th) = type_bounds(c, model.base(fl), [])
  let #(lo, hi) = #(bmax(lo, tl), bmin(hi, th))
  // a count (count:, a path ending in qty) is never below 0
  let #(lo, hi) = case def {
    Some(VPath(parts)) ->
      case list.last(parts) {
        Ok("qty") -> #(bmax(lo, d0()), hi)
        _ -> #(lo, hi)
      }
    _ -> #(lo, hi)
  }
  case mod_of(fl) {
    Some(m) -> {
      let top = case integer_type(c, model.base(fl)) && decimal.is_integral(m) {
        True -> decimal.sub(m, decimal.from_int(1))
        False -> m
      }
      #(bmax(lo, d0()), bmin(hi, Fin(top)))
    }
    None -> #(lo, hi)
  }
}

/// A field's bounds, with a total (sum:) bounded by its list's qty times the
/// bounds of the field it adds up, in rec, the record that holds the field.
/// So a total of delays that are each 0..120 is never below 0.
fn def_bounds(c: Ctx, rec: Decl, fl: Field) -> #(B, B) {
  let #(lo, hi) = field_bounds(c, fl)
  case model.setting(fl.preds, "round"), definition(fl) {
    Some(VPath([rule])), Some(def) -> {
      let #(rlo, rhi) = rounded_bounds(c, rec, fl, def, rule)
      #(bmax(lo, rlo), bmin(hi, rhi))
    }
    _, Some(VPath([_, _, ..] as parts)) ->
      case list.last(parts) {
        // a count is bounded by its list's qty, as in count: stops with
        // stops qty: 1.., which is never 0
        Ok("qty") -> {
          let #(qlo, qhi) = atom_bounds(c, rec, string.join(parts, "."), None)
          #(bmax(lo, qlo), bmin(hi, qhi))
        }
        _ -> sum_bounds(c, rec, fl, lo, hi)
      }
    _, _ -> sum_bounds(c, rec, fl, lo, hi)
  }
}

fn sum_bounds(c: Ctx, rec: Decl, fl: Field, lo: B, hi: B) -> #(B, B) {
  case definition(fl) {
    Some(VPath([list_name, ..rest])) ->
      case model.field(rec, list_name), list.last(rest) {
        Some(lf), Ok("sum") -> {
          let filtered = list.any(rest, is_upper_start)
          let #(qlo, qhi) = case model.qty(lf) {
            Some(#(l, h)) -> #(
              case l {
                Some(n) -> Fin(n.value)
                None -> d0()
              },
              case h {
                Some(n) -> Fin(n.value)
                None -> PosInf
              },
            )
            None -> #(d0(), PosInf)
          }
          let qlo = case filtered {
            True -> d0()
            False -> qlo
          }
          let inner = case
            model.base(lf),
            list.filter(rest, fn(x) { !is_upper_start(x) })
          {
            TypeItem(t), [name, "sum"] ->
              case model.record_of(c.decls, t) {
                Some(it) -> model.field(it, name)
                None -> None
              }
            _, _ -> None
          }
          case inner {
            Some(inn) -> {
              let #(ilo, ihi) = field_bounds(c, inn)
              case bsign(ilo) >= 0 || bsign(ihi) <= 0 {
                True -> {
                  let #(a, b) = imul(#(qlo, qhi), #(ilo, ihi))
                  #(bmax(lo, a), bmin(hi, b))
                }
                False -> #(lo, hi)
              }
            }
            None -> #(lo, hi)
          }
        }
        _, _ -> #(lo, hi)
      }
    _ -> #(lo, hi)
  }
}

fn type_bounds(c: Ctx, it: Item, seen: List(String)) -> #(B, B) {
  case it {
    NumItem(v, _) -> #(Fin(v), Fin(v))
    StrItem(_) -> #(NegInf, PosInf)
    TypeItem(name) ->
      case list.contains(seen, name), dict.get(c.decls, name) {
        False, Ok(dd) ->
          case dd.kind {
            model.Union ->
              case evaluate.is_numeric(c.ev, name) {
                True -> {
                  let bs =
                    list.map(dd.items, fn(i) {
                      type_bounds(c, i, [name, ..seen])
                    })
                  #(
                    list.fold(bs, PosInf, fn(a, b) { bmin(a, b.0) }),
                    list.fold(bs, NegInf, fn(a, b) { bmax(a, b.1) }),
                  )
                }
                False -> #(NegInf, PosInf)
              }
            model.Refine | model.Layout -> {
              let #(lo, hi) =
                list.fold(
                  model.plains(dd.preds),
                  #(NegInf, PosInf),
                  fn(acc, cl) {
                    case cl {
                      Plain(["val"], "=", VRange(l, h)) -> #(
                        case l {
                          Some(n) -> Fin(n.value)
                          None -> acc.0
                        },
                        case h {
                          Some(n) -> Fin(n.value)
                          None -> acc.1
                        },
                      )
                      _ -> acc
                    }
                  },
                )
              let #(lo, hi) = case dd.kind, dd.items {
                model.Layout, [TypeItem(b)] ->
                  case list.contains(model.builtin_numeric, b) {
                    True -> {
                      let signed =
                        list.any(dd.positions, fn(p) {
                          p.items == [StrItem("-")]
                        })
                      case digit_capacity(dd), signed {
                        Some(n), True -> #(
                          bmax(lo, Fin(decimal.negate(pow10_minus1(n)))),
                          bmin(hi, Fin(pow10_minus1(n))),
                        )
                        Some(n), False -> #(
                          bmax(lo, d0()),
                          bmin(hi, Fin(pow10_minus1(n))),
                        )
                        None, True -> #(lo, hi)
                        None, False -> #(bmax(lo, d0()), hi)
                      }
                    }
                    False -> #(lo, hi)
                  }
                _, _ -> #(lo, hi)
              }
              case dd.kind {
                model.Refine -> {
                  let #(bl, bh) =
                    type_bounds(c, model.decl_base(dd), [name, ..seen])
                  #(bmax(lo, bl), bmin(hi, bh))
                }
                _ -> #(lo, hi)
              }
            }
            model.Record -> #(NegInf, PosInf)
            // the value is the first type's reading of the text
            model.Intersection ->
              type_bounds(c, model.decl_base(dd), [name, ..seen])
          }
        _, _ -> #(NegInf, PosInf)
      }
  }
}

// ---------------------------------------------------------------- mappings

type Domain {
  Finite(values: List(Val))
  Numeric(integer: Bool, lo: B, hi: B)
}

type Cons {
  SetC(values: List(Val))
  NumC(conds: List(#(String, Point)))
}

type Point {
  At(Decimal)
  Between(low: Option(Decimal), high: Option(Decimal))
}

fn domain(c: Ctx, fl: Field) -> Option(Domain) {
  case model.qty(fl), fl.mapping {
    Some(_), _ -> None
    None, Some(m) -> option.map(evaluate.finite_values(c.ev, m.outputs), Finite)
    None, None ->
      case evaluate.finite_values(c.ev, fl.items) {
        Some(vs) -> Some(Finite(vs))
        None ->
          case evaluate.items_numeric(c.ev, fl.items) {
            True -> {
              let #(lo, hi) = field_bounds(c, fl)
              Some(Numeric(
                list.all(fl.items, fn(i) { integer_type(c, i) }),
                lo,
                hi,
              ))
            }
            False ->
              case model.base(fl) {
                TypeItem("Needs") | TypeItem("Claims") ->
                  Some(Finite([VText("TRUE")]))
                _ -> None
              }
          }
      }
  }
}

fn integer_type(c: Ctx, it: Item) -> Bool {
  case it {
    NumItem(v, _) -> decimal.is_integral(v)
    StrItem(_) -> False
    TypeItem("Integer") | TypeItem("Integer_Literal") -> True
    TypeItem(name) ->
      case dict.get(c.decls, name) {
        Ok(dd) ->
          case dd.kind {
            model.Layout -> dd.items == [TypeItem("Integer")]
            model.Refine | model.Intersection ->
              integer_type(c, model.decl_base(dd))
            model.Union -> list.all(dd.items, fn(i) { integer_type(c, i) })
            model.Record -> False
          }
        Error(_) -> False
      }
  }
}

fn case_box(
  c: Ctx,
  d: Decl,
  f: Field,
  cs: Case,
  inputs: List(String),
  domains: Dict(String, Domain),
) -> Result(Dict(String, Cons), Nil) {
  let where = d.name <> "." <> f.name
  let bad = fn(msg) {
    err(c, d, cs.line, msg, where)
    Error(Nil)
  }
  case cs.preds.conn == OrConn && list.length(cs.preds.clauses) > 1 {
    True ->
      bad(
        "a case is a box: one interval or literal set per input (an '|' between predicates on different inputs is not a box)",
      )
    False ->
      list.try_fold(cs.preds.clauses, dict.new(), fn(box, cl) {
        case cl {
          Plain([name], op, v) ->
            case list.contains(inputs, name), dict.has_key(box, name) {
              False, _ ->
                bad(
                  "a case predicate names one of the inputs ("
                  <> string.join(inputs, ", ")
                  <> "), not '"
                  <> name
                  <> "'",
                )
              _, True ->
                bad("input '" <> name <> "' is constrained twice in one case")
              True, False -> {
                let vals = case v {
                  VMulti(xs) -> xs
                  _ -> [v]
                }
                let assert Ok(dom) = dict.get(domains, name)
                let parts =
                  list.try_map(vals, fn(x) {
                    case x {
                      VArith(..) | VFilter(..) ->
                        Error(
                          "a case compares to a literal or a range: no arithmetic, no other fields",
                        )
                      VPath([h]) ->
                        case is_upper_start(h), evaluate.singleton(c.ev, h) {
                          True, Some(sv) -> Ok(#(Some(sv), None))
                          True, None ->
                            Error("'" <> h <> "' is not a single value")
                          False, _ ->
                            Error(
                              "a case compares to a literal or a range: no arithmetic, no other fields",
                            )
                        }
                      VPath(_) ->
                        Error(
                          "a case compares to a literal or a range: no arithmetic, no other fields",
                        )
                      VNum(n) -> Ok(#(Some(VNumber(n.value)), None))
                      VStr(s) -> Ok(#(Some(VText(s)), None))
                      VRange(l, h) ->
                        Ok(#(
                          None,
                          Some(Between(
                            option.map(l, fn(n) { n.value }),
                            option.map(h, fn(n) { n.value }),
                          )),
                        ))
                      VMulti(_) -> Error("nested choice")
                    }
                  })
                case parts {
                  Error(msg) -> bad(msg)
                  Ok(ps) ->
                    case dom {
                      Finite(values) ->
                        case op != "=" {
                          True ->
                            bad(
                              "'"
                              <> name
                              <> "' takes one of a set of values; compare it with '='",
                            )
                          False ->
                            case
                              list.find(ps, fn(p) {
                                case p {
                                  #(Some(sv), _) ->
                                    !list.any(values, fn(x) {
                                      evaluate.same(x, sv)
                                    })
                                  _ -> True
                                }
                              })
                            {
                              Ok(_) ->
                                bad(
                                  "a value in this case is not a value of input '"
                                  <> name
                                  <> "'",
                                )
                              Error(_) ->
                                Ok(dict.insert(
                                  box,
                                  name,
                                  SetC(
                                    list.filter_map(ps, fn(p) {
                                      option.to_result(p.0, Nil)
                                    }),
                                  ),
                                ))
                            }
                        }
                      Numeric(..) ->
                        Ok(dict.insert(
                          box,
                          name,
                          NumC(
                            list.map(ps, fn(p) {
                              case p {
                                #(Some(VNumber(x)), _) -> #(op, At(x))
                                #(_, Some(pt)) -> #(op, pt)
                                _ -> #(op, Between(None, None))
                              }
                            }),
                          ),
                        ))
                    }
                }
              }
            }
          _ -> bad("a case predicate compares an input to a literal or a range")
        }
      })
  }
}

fn in_box(cons: Result(Cons, Nil), x: Val) -> Bool {
  case cons {
    Error(_) -> True
    Ok(SetC(vs)) -> list.any(vs, fn(v) { evaluate.same(v, x) })
    Ok(NumC(conds)) ->
      case x {
        VNumber(v) ->
          list.any(conds, fn(c) {
            case c {
              #("=", Between(l, h)) ->
                case l {
                  Some(a) -> decimal.le(a, v)
                  None -> True
                }
                && case h {
                  Some(b) -> decimal.le(v, b)
                  None -> True
                }
              #(_, Between(..)) -> False
              #(op, At(y)) ->
                case op {
                  "=" -> decimal.eq(v, y)
                  "<" -> decimal.lt(v, y)
                  "<=" -> decimal.le(v, y)
                  ">" -> decimal.lt(y, v)
                  _ -> decimal.le(y, v)
                }
            }
          })
        _ -> False
      }
  }
}

fn sample(
  dom: Domain,
  boxes: List(Dict(String, Cons)),
  inp: String,
) -> List(Val) {
  let assert Numeric(integer, lo, hi) = dom
  let bounds =
    list.fold(boxes, [], fn(acc, b) {
      case dict.get(b, inp) {
        Ok(NumC(conds)) ->
          list.fold(conds, acc, fn(acc, c) {
            case c.1 {
              At(x) -> [x, ..acc]
              Between(l, h) -> list.append(option.values([l, h]), acc)
            }
          })
        _ -> acc
      }
    })
  let bounds = case lo {
    Fin(x) -> [x, ..bounds]
    _ -> bounds
  }
  let bounds = case hi {
    Fin(x) -> [x, ..bounds]
    _ -> bounds
  }
  let bs = list.sort(bounds, decimal.compare) |> dedupe_dec
  let one = decimal.from_int(1)
  let pts = case bs, list.last(bs) {
    [first, ..], Ok(last) -> [
      decimal.sub(first, one),
      decimal.add(last, one),
      ..bs
    ]
    _, _ -> [decimal.zero()]
  }
  let between =
    list.window_by_2(bs)
    |> list.filter_map(fn(pair) {
      let #(a, b) = pair
      case integer {
        True -> {
          let k = decimal.add(decimal.floor(a), one)
          case decimal.lt(k, b) {
            True -> Ok(k)
            False -> Error(Nil)
          }
        }
        False -> Ok(decimal.half(decimal.add(a, b)))
      }
    })
  list.append(pts, between)
  |> list.sort(decimal.compare)
  |> dedupe_dec
  |> list.filter(fn(x) {
    { !integer || decimal.is_integral(x) }
    && bcmp(Fin(x), lo) != order.Lt
    && bcmp(Fin(x), hi) != order.Gt
  })
  |> list.map(VNumber)
}

fn dedupe_dec(xs: List(Decimal)) -> List(Decimal) {
  list.fold(xs, [], fn(acc, x) {
    case acc {
      [y, ..] ->
        case decimal.eq(x, y) {
          True -> acc
          False -> [x, ..acc]
        }
      [] -> [x]
    }
  })
  |> list.reverse
}

fn vfmt(v: Val) -> String {
  case v {
    VNumber(x) -> decimal.to_short(x)
    _ -> evaluate.show(v)
  }
}

fn check_mapping(c: Ctx, d: Decl, f: Field, above: List(String)) -> Nil {
  let assert Some(mp) = f.mapping
  let where = d.name <> "." <> f.name
  let domains =
    list.try_fold(mp.inputs, dict.new(), fn(acc, inp) {
      case model.field(d, inp), list.contains(above, inp) {
        Some(fl), True ->
          case domain(c, fl) {
            Some(dom) -> Ok(dict.insert(acc, inp, dom))
            None -> {
              err(
                c,
                d,
                f.line,
                "mapping input '"
                  <> inp
                  <> "' must be of a finite union type or a numeric type (text and sequence inputs are not allowed)",
                where,
              )
              Error(Nil)
            }
          }
        _, _ -> {
          err(
            c,
            d,
            f.line,
            "mapping input '"
              <> inp
              <> "' must be a field declared above the mapping",
            where,
          )
          Error(Nil)
        }
      }
    })
  case domains {
    Error(_) -> Nil
    Ok(domains) -> {
      list.each(mp.outputs, fn(o) {
        case o {
          TypeItem(n) -> type_ok(c, d, n, f.line, False)
          _ -> Nil
        }
      })
      let out_vals = evaluate.finite_values(c.ev, mp.outputs)
      let boxes =
        list.try_map(mp.cases, fn(cs) {
          case evaluate.item_value(c.ev, cs.output) {
            None -> {
              err(
                c,
                d,
                cs.line,
                "a case output is a singleton (a literal, or a type with one inhabitant); '"
                  <> model.item_text(cs.output)
                  <> "' is not",
                where,
              )
              Error(Nil)
            }
            Some(v) ->
              case out_vals {
                Some(ovs) ->
                  case list.any(ovs, fn(x) { evaluate.same(x, v) }) {
                    False -> {
                      err(
                        c,
                        d,
                        cs.line,
                        "case output "
                          <> model.item_text(cs.output)
                          <> " is not a value of the output type",
                        where,
                      )
                      Error(Nil)
                    }
                    True -> case_box(c, d, f, cs, mp.inputs, domains)
                  }
                None -> case_box(c, d, f, cs, mp.inputs, domains)
              }
          }
        })
      case boxes {
        Error(_) -> Nil
        Ok(boxes) -> {
          let points =
            list.map(mp.inputs, fn(inp) {
              let assert Ok(dom) = dict.get(domains, inp)
              case dom {
                Finite(vs) -> vs
                Numeric(..) -> sample(dom, boxes, inp)
              }
            })
          let combos = case points {
            [xs] -> list.map(xs, fn(x) { [x] })
            [xs, ys] ->
              list.flat_map(xs, fn(x) { list.map(ys, fn(y) { [x, y] }) })
            _ -> []
          }
          let #(missing, overlap) =
            list.fold(combos, #([], []), fn(acc, combo) {
              let env = list.zip(mp.inputs, combo)
              let hits =
                list.index_map(boxes, fn(b, k) { #(b, k) })
                |> list.filter(fn(bk) {
                  list.all(env, fn(e) { in_box(dict.get(bk.0, e.0), e.1) })
                })
                |> list.map(fn(bk) { bk.1 })
              case hits {
                [] -> #(list.append(acc.0, [env]), acc.1)
                [_] -> acc
                _ -> #(acc.0, list.append(acc.1, [#(env, hits)]))
              }
            })
          let fmt = fn(env: List(#(String, Val))) {
            list.map(env, fn(e) { e.0 <> " = " <> vfmt(e.1) })
            |> string.join(", ")
          }
          case missing {
            [] -> Nil
            _ ->
              err(
                c,
                d,
                f.line,
                "cases do not cover every input combination; missing: "
                  <> {
                  list.take(missing, 4) |> list.map(fmt) |> string.join("; ")
                }
                  <> case list.length(missing) > 4 {
                  True -> " …"
                  False -> ""
                },
                where,
              )
          }
          case overlap {
            [#(env, hits), ..] ->
              err(
                c,
                d,
                f.line,
                "cases are not disjoint: "
                  <> fmt(env)
                  <> " matches cases "
                  <> {
                  list.map(hits, fn(h) { int.to_string(h + 1) })
                  |> string.join(", ")
                },
                where,
              )
            [] -> Nil
          }
          case out_vals {
            Some(ovs) -> {
              let produced =
                list.filter_map(mp.cases, fn(cs) {
                  option.to_result(evaluate.item_value(c.ev, cs.output), Nil)
                })
              let lost =
                list.filter(ovs, fn(v) {
                  !list.any(produced, fn(p) { evaluate.same(p, v) })
                })
              case lost {
                [] -> Nil
                _ ->
                  err(
                    c,
                    d,
                    f.line,
                    "no case produces "
                      <> { list.map(lost, vfmt) |> string.join(", ") }
                      <> "; every value of the output type must be produced by some case",
                    where,
                  )
              }
            }
            None -> Nil
          }
          case missing, overlap {
            [], [] ->
              push(c.mappings, #(
                where,
                int.to_string(list.length(mp.cases))
                  <> " cases, "
                  <> int.to_string(list.length(combos))
                  <> " cells checked: covering and disjoint",
              ))
            _, _ -> Nil
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------- claims

type Poly =
  Dict(List(String), Decimal)

fn padd(a: Poly, b: Poly, sign: Int) -> Poly {
  dict.fold(b, a, fn(acc, m, k) {
    let k = case sign {
      1 -> k
      _ -> decimal.negate(k)
    }
    let now = case dict.get(acc, m) {
      Ok(x) -> x
      Error(_) -> decimal.zero()
    }
    dict.insert(acc, m, decimal.add(now, k))
  })
}

fn pmul(a: Poly, b: Poly) -> Poly {
  dict.fold(a, dict.new(), fn(acc, m1, k1) {
    dict.fold(b, acc, fn(acc, m2, k2) {
      let m = list.sort(list.append(m1, m2), string.compare)
      let now = case dict.get(acc, m) {
        Ok(x) -> x
        Error(_) -> decimal.zero()
      }
      dict.insert(acc, m, decimal.add(now, decimal.mul(k1, k2)))
    })
  })
}

fn expand(d: Decl, v: Value, depth: Int) -> Option(Poly) {
  case depth > 50, v {
    True, _ -> None
    _, VNum(n) -> Some(dict.from_list([#([], n.value)]))
    _, VArith("/", _) -> None
    _, VArith(op, terms) -> {
      let ps = list.map(terms, fn(t) { expand(d, t, depth + 1) })
      case list.all(ps, option.is_some), option.values(ps) {
        True, [first, ..rest] ->
          Some(
            list.fold(rest, first, fn(acc, p) {
              case op {
                "+" -> padd(acc, p, 1)
                "-" -> padd(acc, p, -1)
                _ -> pmul(acc, p)
              }
            }),
          )
        _, _ -> None
      }
    }
    _, VPath(parts) -> {
      let assert [head, ..] = parts
      case model.field(d, head), parts {
        None, _ -> None
        Some(fl), [_] ->
          // a field that wraps ('mod =') is not its definition: it stays an
          // atom, bounded by field_bounds to [0, m)
          // and a rounded field ('round:') is not its calculation either: it
          // stays an atom, bounded by def_bounds within a unit of it
          case
            fl.role,
            definition(fl),
            model.setting(fl.preds, "mod"),
            model.setting(fl.preds, "round")
          {
            model.Computed, Some(def), None, None -> expand(d, def, depth + 1)
            _, _, _, _ -> Some(dict.from_list([#([head], decimal.from_int(1))]))
          }
        Some(_), _ ->
          Some(
            dict.from_list([#([string.join(parts, ".")], decimal.from_int(1))]),
          )
      }
    }
    _, _ -> None
  }
}

fn claim_parts(claim: Field) -> #(Option(String), String, Value) {
  let assert [Plain(p, op, v)] = model.plains(claim.preds)
  case p {
    [one] -> #(Some(one), op, v)
    _ -> #(None, op, v)
  }
}

fn claim_interval(claim: Field) -> #(B, B) {
  case claim_parts(claim) {
    #(_, op, VNum(n)) ->
      case op {
        ">=" | ">" -> #(Fin(n.value), PosInf)
        "<=" | "<" -> #(NegInf, Fin(n.value))
        _ -> #(Fin(n.value), Fin(n.value))
      }
    _ -> #(NegInf, PosInf)
  }
}

/// On a recursive type, the claim itself may be assumed for the field it
/// claims, read through the recursive field.
fn induction(
  d: Decl,
  it: Decl,
  inn: Field,
  claim: Option(Field),
) -> Option(#(B, B)) {
  case claim {
    Some(cl) -> {
      let #(subject, _, _) = claim_parts(cl)
      case it.name == d.name && subject == Some(inn.name) {
        True -> Some(claim_interval(cl))
        False -> None
      }
    }
    None -> None
  }
}

fn atom_bounds(c: Ctx, d: Decl, atom: String, claim: Option(Field)) -> #(B, B) {
  let all_parts = string.split(atom, ".")
  // a filter keeps some of the items: it can only lower the count to 0
  let filtered = list.any(list.drop(all_parts, 1), fn(x) { is_upper_start(x) })
  let parts = case all_parts {
    [h, ..rest] -> [h, ..list.filter(rest, fn(x) { !is_upper_start(x) })]
    [] -> []
  }
  let assert [head, ..] = parts
  case model.field(d, head) {
    None -> #(NegInf, PosInf)
    Some(fl) ->
      case parts {
        [_] -> def_bounds(c, d, fl)
        _ -> {
          let assert Ok(last) = list.last(parts)
          let fold = case list.contains(model.folds, last) {
            True -> Some(last)
            False -> None
          }
          let #(qlo, qhi) = case model.qty(fl) {
            Some(#(l, h)) -> #(
              case l {
                Some(n) -> Fin(n.value)
                None -> d0()
              },
              case h {
                Some(n) -> Fin(n.value)
                None -> PosInf
              },
            )
            None -> #(d0(), PosInf)
          }
          let qlo = case filtered {
            True -> d0()
            False -> qlo
          }
          let item = case model.base(fl) {
            TypeItem(t) -> model.record_of(c.decls, t)
            _ -> None
          }
          let inner = case item, parts {
            Some(it), [_, second, ..] -> model.field(it, second)
            _, _ -> None
          }
          case fold, item, inner {
            Some("qty"), _, _ -> #(qlo, qhi)
            Some("count"), _, _ -> #(d0(), qhi)
            Some("sum"), Some(it), Some(inn) -> {
              // Induction through a fold: on a recursive field, each item's
              // value of the claimed field may be assumed to satisfy the claim.
              let #(lo, hi) = case induction(d, it, inn, claim) {
                Some(b) -> b
                None -> field_bounds(c, inn)
              }
              case bsign(lo) >= 0 || bsign(hi) <= 0 {
                True -> imul(#(qlo, qhi), #(lo, hi))
                False -> #(NegInf, PosInf)
              }
            }
            None, Some(it), Some(inn) -> {
              let #(lo, hi) = case induction(d, it, inn, claim) {
                Some(b) -> b
                None -> def_bounds(c, it, inn)
              }
              case bcmp(qlo, d0()) == order.Eq {
                True -> #(bmin(lo, d0()), bmax(hi, d0()))
                False -> #(lo, hi)
              }
            }
            _, _, _ -> #(NegInf, PosInf)
          }
        }
      }
  }
}

fn pstr(p: Poly) -> String {
  dict.to_list(p)
  |> list.filter(fn(kv) { !decimal.is_zero(kv.1) })
  |> list.sort(fn(a, b) {
    case int.compare(list.length(a.0), list.length(b.0)) {
      order.Eq -> string.compare(string.join(a.0, "*"), string.join(b.0, "*"))
      o -> o
    }
  })
  |> list.map(fn(kv) {
    let #(m, k) = kv
    let body = string.join(m, " * ")
    let one = decimal.from_int(1)
    case m, decimal.eq(k, one), decimal.eq(k, decimal.negate(one)) {
      [], _, _ -> decimal.to_short(k)
      _, True, _ -> body
      _, _, True -> "-" <> body
      _, _, _ -> decimal.to_short(k) <> " * " <> body
    }
  })
  |> string.join(" + ")
  |> string.replace("+ -", "- ")
}

fn prove_claim(c: Ctx, d: Decl, f: Field) -> Nil {
  let assert [Plain(p, op, v)] = model.plains(f.preds)
  let where = d.name <> "." <> f.name
  let text = model.clause_text(Plain(p, op, v))
  case v {
    VRange(..) | VMulti(..) | VStr(_) ->
      err(
        c,
        d,
        f.line,
        "a claim is a single comparison between numeric expressions",
        where,
      )
    _ ->
      case expand(d, VPath(p), 0), expand(d, v, 0) {
        Some(l), Some(r) -> {
          let diff =
            padd(l, r, -1) |> dict.filter(fn(_, k) { !decimal.is_zero(k) })
          let #(lo, hi) =
            dict.fold(diff, #(d0(), d0()), fn(acc, mono, k) {
              let b =
                list.fold(
                  mono,
                  #(Fin(decimal.from_int(1)), Fin(decimal.from_int(1))),
                  fn(b, atom) { imul(b, atom_bounds(c, d, atom, Some(f))) },
                )
              let b = imul(b, #(Fin(k), Fin(k)))
              #(badd(acc.0, b.0), badd(acc.1, b.1))
            })
          let proved = case op {
            ">=" -> bsign(lo) >= 0
            ">" -> bsign(lo) > 0
            "<=" -> bsign(hi) <= 0
            "<" -> bsign(hi) < 0
            _ -> bsign(lo) == 0 && bsign(hi) == 0
          }
          let expr = case pstr(diff) {
            "" -> "0"
            e -> e
          }
          case proved {
            True ->
              push(c.claims, #(
                where,
                "proved: "
                  <> text
                  <> "  (left - right = "
                  <> expr
                  <> ", which lies in ["
                  <> bfmt(lo)
                  <> ", "
                  <> bfmt(hi)
                  <> "])",
              ))
            False ->
              err(
                c,
                d,
                f.line,
                "cannot prove "
                  <> text
                  <> ": left - right = "
                  <> expr
                  <> " is only known to lie in ["
                  <> bfmt(lo)
                  <> ", "
                  <> bfmt(hi)
                  <> "]",
                where,
              )
          }
        }
        _, _ ->
          err(
            c,
            d,
            f.line,
            "cannot prove "
              <> text
              <> ": the sides do not expand into stored fields",
            where,
          )
      }
  }
}

// ---------------------------------------------------------------- cost

type CPoly =
  Dict(List(String), Int)

fn cadd(a: CPoly, b: CPoly) -> CPoly {
  dict.fold(b, a, fn(acc, m, k) {
    dict.insert(acc, m, k + result_or(dict.get(acc, m), 0))
  })
}

fn result_or(r: Result(a, Nil), default: a) -> a {
  case r {
    Ok(x) -> x
    Error(_) -> default
  }
}

fn unit() -> CPoly {
  dict.from_list([#([], 1)])
}

fn cost_value(
  c: Ctx,
  d: Decl,
  v: Value,
  prefix: String,
  seen: List(String),
) -> CPoly {
  case v {
    VNum(_) | VStr(_) | VRange(..) -> dict.new()
    VMulti(xs) ->
      list.fold(xs, dict.new(), fn(acc, x) {
        cadd(acc, cost_value(c, d, x, prefix, seen))
      })
    VArith(_, ts) ->
      list.fold(ts, unit(), fn(acc, t) {
        cadd(acc, cost_value(c, d, t, prefix, seen))
      })
    VPath(p) -> cost_path(c, d, p, prefix, seen)
    VFilter(..) -> cost_value(c, d, analysis_value(v), prefix, seen)
  }
}

fn cost_path(
  c: Ctx,
  d: Decl,
  p: List(String),
  prefix: String,
  seen: List(String),
) -> CPoly {
  let assert [head, ..rest] = p
  let outer = case is_upper_start(head), rest {
    True, [_, ..] ->
      case dict.get(c.decls, head) {
        Ok(u) if u.kind == model.Record && head != d.name -> Some(u)
        _ -> None
      }
    _, _ -> None
  }
  use <- cost_outer(outer, fn(u) {
    cost_path(c, u, rest, head <> ".", [head, ..seen])
  })
  case
    head == "val" || is_upper_start(head) || d.kind != model.Record,
    model.field(d, head),
    rest
  {
    True, _, _ -> unit()
    _, None, _ -> unit()
    _, _, [] -> unit()
    _, Some(fl), [second, ..] ->
      case model.qty(fl) {
        None -> unit()
        Some(#(_, hi)) -> {
          let name = prefix <> head
          let recursive = model.base(fl) == TypeItem(d.name)
          let var = case recursive, hi {
            True, _ -> Some("nodes(" <> name <> ")")
            False, Some(_) -> None
            False, None -> Some(name <> ".count")
          }
          let item = case model.base(fl) {
            TypeItem(t) -> model.record_of(c.decls, t)
            _ -> None
          }
          let per_item = case item {
            Some(it) ->
              case
                !list.contains(model.folds, second)
                && !recursive
                && !list.contains(seen, it.name)
              {
                True ->
                  case model.field(it, second) {
                    Some(inner) ->
                      cadd(
                        unit(),
                        cost_field(c, it, inner, name <> ".", [it.name, ..seen]),
                      )
                    None -> unit()
                  }
                False -> unit()
              }
            None -> unit()
          }
          fold_over(per_item, name, var)
        }
      }
  }
}

/// A path into a record around this one costs what walking it from there
/// costs, named from there: 'Book.customers.qty'.
fn cost_outer(
  outer: Option(Decl),
  inner: fn(Decl) -> CPoly,
  otherwise: fn() -> CPoly,
) -> CPoly {
  case outer {
    Some(u) -> inner(u)
    None -> otherwise()
  }
}

/// The cost of visiting every item once: the per-item cost times the number
/// of items, except for per-item terms that are themselves sizes of the item's
/// own sequences. Summed over the items, those add up to the flattened size
/// (rows.cells.qty already counts every cell of every row), so they are not
/// multiplied again (Step 5: a path through two sequences flattens them).
fn fold_over(per_item: CPoly, name: String, var: Option(String)) -> CPoly {
  dict.fold(per_item, dict.new(), fn(acc, m, k) {
    let nested = list.any(m, fn(x) { string.starts_with(x, name <> ".") })
    let m2 = case nested, var {
      True, _ -> m
      False, Some(x) -> list.sort([x, ..m], string.compare)
      False, None -> m
    }
    dict.insert(acc, m2, k + result_or(dict.get(acc, m2), 0))
  })
}

fn cost_field(
  c: Ctx,
  d: Decl,
  f: Field,
  prefix: String,
  seen: List(String),
) -> CPoly {
  let acc =
    list.fold(f.preds.clauses, unit(), fn(acc, cl) {
      case cl {
        Plain(p, _, v) ->
          acc
          |> cadd(unit())
          |> cadd(cost_path(c, d, p, prefix, seen))
          |> cadd(cost_value(c, d, v, prefix, seen))
        _ -> acc
      }
    })
  case f.mapping {
    Some(m) ->
      cadd(
        acc,
        dict.from_list([#([], list.length(m.inputs) + list.length(m.cases))]),
      )
    None -> acc
  }
}

fn dominated(m: List(String), pm: List(String)) -> Bool {
  list.all(list.unique(m), fn(v) {
    list.count(m, fn(x) { x == v }) <= list.count(pm, fn(x) { x == v })
  })
}

pub fn cost_text(cp: CPoly) -> String {
  let monos = dict.keys(dict.filter(cp, fn(_, k) { k != 0 }))
  let keep =
    list.filter(monos, fn(m) {
      !list.any(monos, fn(o) { o != m && dominated(m, o) })
    })
  case keep {
    [] | [[]] -> "O(1)"
    _ ->
      "O("
      <> {
        keep
        |> list.sort(fn(a, b) {
          case int.compare(list.length(b), list.length(a)) {
            order.Eq -> string.compare(string.join(a, "*"), string.join(b, "*"))
            o -> o
          }
        })
        |> list.map(fn(m) {
          case m {
            [] -> "1"
            _ ->
              list.map(m, fn(x) { string.replace(x, ".qty", ".count") })
              |> string.join(" * ")
          }
        })
        |> string.join(" + ")
      }
      <> ")"
  }
}

/// A size named in a cost promise: a list's count (lines.qty), or a field that
/// counts the nodes of a recursive value, written 'n {Integer} val = 1 +
/// kids.n.sum' (or '1 + rest.n' for a list of at most one), which stands for
/// the nodes of that recursive field.
fn promise_var(d: Decl, p: List(String)) -> String {
  let counted = case p {
    [f] ->
      case model.field(d, f) {
        Some(fl) ->
          case definition(fl) {
            Some(VArith("+", [VNum(one), VPath([r, f2, ..tail])]))
            | Some(VArith("+", [VPath([r, f2, ..tail]), VNum(one)])) ->
              case
                decimal.eq(one.value, decimal.from_int(1))
                && f2 == f
                && { tail == ["sum"] || tail == [] }
              {
                True ->
                  case model.field(d, r) {
                    Some(rf) ->
                      case model.base(rf) == TypeItem(d.name) {
                        True -> Some(r)
                        False -> None
                      }
                    None -> None
                  }
                False -> None
              }
            _ -> None
          }
        None -> None
      }
    _ -> None
  }
  case counted {
    Some(r) -> "nodes(" <> r <> ")"
    None -> string.join(p, ".")
  }
}

fn promise_poly(d: Decl, v: Value) -> Option(CPoly) {
  case v {
    VNum(_) -> Some(unit())
    VPath(p) -> Some(dict.from_list([#([promise_var(d, p)], 1)]))
    VArith("*", ts) ->
      Some(
        dict.from_list([
          #(
            list.filter_map(ts, fn(t) {
              case t {
                VPath(p) -> Ok(promise_var(d, p))
                _ -> Error(Nil)
              }
            })
              |> list.sort(string.compare),
            1,
          ),
        ]),
      )
    VArith("+", ts) ->
      Some(
        dict.from_list(
          list.filter_map(ts, fn(t) {
            case t {
              VPath(p) -> Ok(#([promise_var(d, p)], 1))
              _ -> Error(Nil)
            }
          }),
        ),
      )
    _ -> None
  }
}

fn cost_record(c: Ctx, d: Decl) -> Nil {
  let total =
    list.fold(d.fields, dict.new(), fn(total, f) {
      let fc = cost_field(c, d, f, "", [])
      case model.setting(f.preds, "cost") {
        Some(promise) ->
          case promise_poly(d, promise) {
            None ->
              err(
                c,
                d,
                f.line,
                "cost <= "
                  <> model.value_text(promise)
                  <> ": the bound must be a number, a size, or one product or sum of sizes",
                d.name <> "." <> f.name,
              )
            Some(pc) -> {
              let bad =
                list.filter(dict.keys(fc), fn(m) {
                  !list.any(dict.keys(pc), fn(pm) { dominated(m, pm) })
                })
              case bad {
                [] -> Nil
                _ ->
                  err(
                    c,
                    d,
                    f.line,
                    "cost promise broken: worked-out cost "
                      <> cost_text(fc)
                      <> " exceeds cost <= "
                      <> model.value_text(promise),
                    d.name <> "." <> f.name,
                  )
              }
            }
          }
        None -> Nil
      }
      cadd(total, fc)
    })
  push(c.costs, #(d.name, cost_text(total)))
}

// ---------------------------------------------------------------- mapping grids (for drawing)

/// A mapping as a grid: the sampled values of each input (one or two axes),
/// and for every cell the cases whose box contains it.
pub type Grid {
  Grid(
    inputs: List(String),
    axes: List(List(Val)),
    cells: List(#(List(Val), List(Int))),
    outputs: List(String),
  )
}

pub fn mapping_grid(
  decls: Dict(String, Decl),
  index: Dict(String, Int),
  d: Decl,
  f: Field,
) -> Option(Grid) {
  let c =
    Ctx(
      decls,
      index,
      evaluate.new(decls),
      grammar.cell([]),
      grammar.cell([]),
      grammar.cell([]),
      grammar.cell([]),
    )
  case f.mapping {
    None -> None
    Some(mp) -> {
      let domains =
        list.try_fold(mp.inputs, dict.new(), fn(acc, inp) {
          case model.field(d, inp) {
            Some(fl) ->
              case domain(c, fl) {
                Some(dom) -> Ok(dict.insert(acc, inp, dom))
                None -> Error(Nil)
              }
            None -> Error(Nil)
          }
        })
      case domains {
        Error(_) -> None
        Ok(domains) -> {
          let boxes =
            list.try_map(mp.cases, fn(cs) {
              case_box(c, d, f, cs, mp.inputs, domains)
            })
          case boxes {
            Error(_) -> None
            Ok(boxes) -> {
              let axes =
                list.map(mp.inputs, fn(inp) {
                  let assert Ok(dom) = dict.get(domains, inp)
                  case dom {
                    Finite(vs) -> vs
                    Numeric(..) -> sample(dom, boxes, inp)
                  }
                })
              let combos = case axes {
                [xs] -> list.map(xs, fn(x) { [x] })
                [xs, ys] ->
                  list.flat_map(xs, fn(x) { list.map(ys, fn(y) { [x, y] }) })
                _ -> []
              }
              let cells =
                list.map(combos, fn(combo) {
                  let env = list.zip(mp.inputs, combo)
                  #(combo, hits(boxes, env))
                })
              Some(Grid(
                mp.inputs,
                axes,
                cells,
                list.map(mp.cases, fn(cs) { model.item_text(cs.output) }),
              ))
            }
          }
        }
      }
    }
  }
}

fn hits(
  boxes: List(Dict(String, Cons)),
  env: List(#(String, Val)),
) -> List(Int) {
  list.index_map(boxes, fn(b, k) { #(b, k) })
  |> list.filter(fn(bk) {
    list.all(env, fn(e) { in_box(dict.get(bk.0, e.0), e.1) })
  })
  |> list.map(fn(bk) { bk.1 })
}

/// The cases of a mapping that a concrete input combination falls into.
pub fn cases_for(
  decls: Dict(String, Decl),
  index: Dict(String, Int),
  d: Decl,
  f: Field,
  env: List(#(String, Val)),
) -> List(Int) {
  let c =
    Ctx(
      decls,
      index,
      evaluate.new(decls),
      grammar.cell([]),
      grammar.cell([]),
      grammar.cell([]),
      grammar.cell([]),
    )
  case f.mapping {
    None -> []
    Some(mp) -> {
      let domains =
        list.try_fold(mp.inputs, dict.new(), fn(acc, inp) {
          case model.field(d, inp) {
            Some(fl) ->
              case domain(c, fl) {
                Some(dom) -> Ok(dict.insert(acc, inp, dom))
                None -> Error(Nil)
              }
            None -> Error(Nil)
          }
        })
      case domains {
        Error(_) -> []
        Ok(domains) ->
          case
            list.try_map(mp.cases, fn(cs) {
              case_box(c, d, f, cs, mp.inputs, domains)
            })
          {
            Ok(boxes) -> hits(boxes, env)
            Error(_) -> []
          }
      }
    }
  }
}

/// A fold step as the language writes it: the model's qty is '.count'.
fn method_name(step: String) -> String {
  case step {
    "qty" -> "count"
    other -> other
  }
}
