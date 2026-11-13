//// Tests: `gleam test`. A small runner, since the test library (gleeunit) is
//// a hex package and this project builds from git only.

import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import sheaf/check
import sheaf/decimal
import sheaf/evaluate.{VNumber, VRecord, VText}
import sheaf/graph
import sheaf/model
import sheaf/printer
import sheaf/program.{type Program}
import sheaf/sequents

@external(javascript, "../etale/sheaf/ffi.mjs", "read_file")
fn read_file(p: String) -> Result(String, Nil)

@external(javascript, "../etale/sheaf/ffi.mjs", "cwd")
fn cwd() -> String

@external(javascript, "../etale/sheaf/ffi.mjs", "list_dir")
fn list_dir(dir: String) -> List(#(String, Bool))

@external(javascript, "../etale/sheaf/ffi.mjs", "exit")
fn exit(code: Int) -> Nil

@external(javascript, "../etale/sheaf/ffi.mjs", "now_ms")
fn now_ms() -> Float

type Outcome {
  Pass
  Fail(String)
}

fn expect(cond: Bool, what: String) -> Outcome {
  case cond {
    True -> Pass
    False -> Fail(what)
  }
}

fn all(results: List(Outcome)) -> Outcome {
  list.find(results, fn(r) { r != Pass })
  |> option.from_result
  |> option.unwrap(Pass)
}

fn prelude() -> String {
  let assert Ok(t) = read_file("priv/language.sheaf")
  t
}

fn fs() -> program.Fs {
  program.Fs(read_file, list_dir, cwd(), cwd(), cwd() <> "/priv/stdlib")
}

fn base(verify: Bool) -> Program {
  let assert Ok(p) = program.new(prelude(), fs(), verify)
  p
}

fn load(path: String) -> #(Program, check.Report) {
  let assert Ok(r) = program.load(base(False), program.join(cwd(), path))
  r
}

fn source(text: String) -> Result(#(Program, check.Report), model.MapError) {
  program.load_text(base(False), text, cwd() <> "/test.sheaf")
}

fn msgs(r: check.Report) -> String {
  check.errors(r) |> list.map(fn(d) { d.msg }) |> string.join(" | ")
}

fn get(p: Program, v, name: String) {
  let assert Some(VRecord(r)) = v
  evaluate.get(p.ev, r, name)
}

fn num(v) -> String {
  case v {
    VNumber(d) -> decimal.to_string(d)
    VText(s) -> s
    _ -> evaluate.show(v)
  }
}

// ---------------------------------------------------------------- tests

fn bootstrap() -> Outcome {
  let p = base(True)
  all([
    expect(
      list.length(p.order) == spec_decls,
      int.to_string(list.length(p.order)) <> " declarations",
    ),
    expect(check.errors(p.prelude_report) == [], "prelude checks clean"),
    expect(
      !string.ends_with(prelude(), "\n"),
      "the bundled spec relies on the last-line rule",
    ),
  ])
}

fn decimals() -> Outcome {
  let assert Ok(a) = decimal.parse("19.99")
  let assert Ok(b) = decimal.parse("120.00")
  all([
    expect(
      decimal.to_string(decimal.mul(a, decimal.from_int(3))) == "59.97",
      "19.99 * 3",
    ),
    expect(
      decimal.to_string(decimal.mul(decimal.from_int(10), b)) == "1200.00",
      "places add",
    ),
    expect(decimal.eq(b, decimal.from_int(120)), "1.50 = 1.5 style equality"),
    expect(
      decimal.to_string(decimal.modulo(
        decimal.from_int(-7),
        decimal.from_int(4),
      ))
        == "1",
      "mod is never negative",
    ),
    expect(
      decimal.to_string(decimal.mul(
        {
          let assert Ok(x) = decimal.parse("99999999999999999999")
          x
        },
        decimal.from_int(10),
      ))
        == "999999999999999999990",
      "integers are unbounded",
    ),
  ])
}

fn last_line_without_newline() -> Outcome {
  case
    source(
      "Two_Digits {\"0\" | \"1\"}\nPair {}\n  a {Two_Digits}\n  b {Two_Digits}",
    )
  {
    Ok(#(p, rep)) ->
      all([
        expect(check.errors(rep) == [], "clean"),
        expect(program.check(p, "Pair", "01").ok, "Pair 01"),
      ])
    Error(e) -> Fail(model.error_text(e))
  }
}

fn syntax_errors() -> Outcome {
  all([
    expect(result_is_error(source("Bad {\"a\" | }\n")), "bad union"),
    expect(
      result_is_error(source(
        "Thing {}\n  a {Integer}\n  b {Integer} value: 1, if: a = 2 | a = 3\n",
      )),
      "& mixed with |",
    ),
    expect(
      result_is_error(source("Two {\"a\" | \"b\"} value: \"a\"\n")),
      "predicates on a union",
    ),
    expect(
      case source("Digit {\"0\"}\n") {
        Error(e) -> string.contains(e.msg, "already declared")
        Ok(_) -> False
      },
      "redeclaring a prelude type",
    ),
  ])
}

fn result_is_error(r: Result(a, b)) -> Bool {
  case r {
    Error(_) -> True
    Ok(_) -> False
  }
}

fn and_gate_short_circuit() -> Outcome {
  let p = base(False)
  let o = program.check(p, "And_Gate", "FALSETRUE")
  let assert Some(VRecord(r)) = o.value
  let assert Ok(t) = list.find(evaluate.trace(r), fn(t) { t.field == "out" })
  all([
    expect(o.ok, "FALSETRUE inhabits And_Gate"),
    expect(num(get(p, o.value, "out")) == "FALSE", "out = FALSE"),
    expect(
      t.deps == ["left"] && string.contains(t.detail, "never evaluated: right"),
      "right never evaluated",
    ),
    expect(
      num(get(p, program.check(p, "And_Gate", "TRUETRUE").value, "out"))
        == "TRUE",
      "TRUETRUE -> TRUE",
    ),
  ])
}

fn bounded_range_rule() -> Outcome {
  let o = program.check(base(False), "Bounded_Range", "5..1")
  expect(
    !o.ok && list.any(o.failures, fn(f) { string.contains(f, "ordered") }),
    "5..1 breaks 'ordered'",
  )
}

fn mistakes() -> Outcome {
  let #(_, rep) = load("examples/mistakes/mistakes.sheaf")
  let text = msgs(rep)
  list.map(
    [
      "used before it is declared", "is reserved", "declared below",
      "do not cover", "not disjoint", "cannot prove", "at most one factor",
      "rounding never happens", "not a number, so it cannot be multiplied",
      "must always sit inside",
    ],
    fn(needle) { expect(string.contains(text, needle), needle) },
  )
  |> all
}

fn geometric_mistakes() -> Outcome {
  let #(_, rep) = load("examples/mistakes/geometric.sheaf")
  let text = msgs(rep)
  let wrapped =
    "Clock {}\n  hour {Integer} value: 0..23\n"
    <> "  later {Integer} value: hour + 5, mod: 24\n  in_day {Claims} later <= 23\n"
  let assert Ok(#(_, ok)) = source(wrapped)
  let assert Ok(#(table, _)) =
    source(
      "Row {}\n  p {Decimal} unique: True\n  text {Text}\n    1. {p}\n    2. {Newline}\nTable {}\n  rows {Row} qty: 1..\n",
    )
  all([
    expect(
      result_is_error(source(
        "X {}\n  h {Integer}\n  later {Integer} value: h + 5, mod: -3\n",
      ))
        && result_is_error(source(
        "X {}\n  h {Integer}\n  m {Integer}\n  later {Integer} value: h + 5, mod: m\n",
      )),
      "mod: takes a number written out in digits",
    ),
    expect(
      string.contains(text, "cannot prove later >= hour"),
      "a wrapped field is not its definition",
    ),
    expect(
      list.key_find(ok.claims, "Clock.in_day") |> is_ok,
      "a wrapped field lies in [0, m)",
    ),
    expect(
      !program.check(table, "Table", "1.50\n1.5\n").ok
        && program.check(table, "Table", "1.50\n1.6\n").ok,
      "unique compares numbers by value",
    ),
  ])
}

fn sequents_print() -> Outcome {
  let theory = fn(path) {
    let #(p, _) = load(path)
    sequents.file(p, option.unwrap(p.main_file, path))
  }
  let orders = theory("examples/orders/orders.sheaf")
  let book = theory("examples/book/book.sheaf")
  let has = fn(text, needle) { expect(string.contains(text, needle), needle) }
  all([
    has(orders, "Order(t) ⊢ t.total = t.lines.line_total.sum"),
    has(orders, "Line(t) ∧ t.line_total ≥ 500.00 ⊢ t.big = TRUE"),
    has(orders, "∧ Line{1..}(lines)"),
    has(orders, "t.big_lines = t.lines.qty [only items with lines.big = True]"),
    has(book, "t.orders.customer ⊆ t.customers.code"),
    has(book, "t.code = u.code ⊢ t = u"),
    expect(
      !string.contains(orders <> book, "¬")
        && !string.contains(orders <> book, "→")
        && !string.contains(orders <> book, "∀"),
      "no ¬, → or ∀",
    ),
  ])
}

fn mapping_outputs_and_inputs() -> Outcome {
  let assert Ok(#(_, r1)) =
    source(
      "Two {\"x\" | \"y\"}\nM {}\n  a {True | False}\n  out {Two} (a)\n    {\"x\"} if: a = True\n    {\"x\"} if: a = False\n",
    )
  let assert Ok(#(_, r2)) =
    source(
      "M {}\n  t {Text}\n  out {True | False} (t)\n    {True} if: t = \"a\"\n",
    )
  all([
    expect(
      string.contains(msgs(r1), "no case produces"),
      "every output produced",
    ),
    expect(
      string.contains(msgs(r2), "finite union type or a numeric type"),
      "text inputs rejected",
    ),
  ])
}

fn claims_and_costs() -> Outcome {
  let #(_, rep) = load("examples/proofs/proofs.sheaf")
  let #(_, orders) = load("examples/orders/orders.sheaf")
  all([
    expect(
      list.key_find(rep.claims, "Window.wide_enough") |> is_ok,
      "range claim proved",
    ),
    expect(
      list.key_find(rep.claims, "Chain.nonnegative") |> is_ok,
      "induction claim proved",
    ),
    expect(check.errors(rep) == [], "proofs clean"),
    expect(
      list.key_find(orders.costs, "Order") == Ok("O(lines.qty)"),
      "Order is linear",
    ),
    expect(
      list.key_find(orders.costs, "Line") == Ok("O(1)"),
      "Line is constant",
    ),
  ])
}

fn is_ok(r: Result(a, b)) -> Bool {
  case r {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn libraries_clean() -> Outcome {
  list.map(
    [
      "priv/stdlib/logic.sheaf", "priv/stdlib/bits.sheaf",
      "priv/stdlib/dates.sheaf", "priv/stdlib/text.sheaf",
      "priv/stdlib/rounding.sheaf", "examples/orders/orders.sheaf",
      "examples/proofs/proofs.sheaf", "examples/meeting/meeting.sheaf",
      "examples/xor/xor.sheaf",
    ],
    fn(f) {
      let #(_, rep) = load(f)
      expect(check.errors(rep) == [], f <> ": " <> msgs(rep))
    },
  )
  |> all
}

fn orders() -> Outcome {
  let #(p, _) = load("examples/orders/orders.sheaf")
  let assert Ok(t) = read_file("examples/orders/order_1042.txt")
  let o = program.check(p, "Order", t)
  let small = "order 7\nABC-0001 x1 @ 1.00\n"
  let bad = program.check(p, "Order", "order 7\nABC-0001 x3 @ 19.9\n")
  all([
    expect(o.ok, "order inhabits Order"),
    expect(num(get(p, o.value, "total")) == "1259.97", "total"),
    expect(num(get(p, o.value, "big_lines")) == "1", "big lines"),
    expect(program.check(p, "Order", small).ok, "a small order inhabits Order"),
    expect(
      num(get(p, program.check(p, "Order", small).value, "big_lines")) == "0",
      "a filter that keeps nothing counts 0",
    ),
    expect(
      !bad.ok
        && list.any(bad.failures, fn(f) { string.contains(f, "places = 2") }),
      "places enforced",
    ),
  ])
}

fn dates() -> Outcome {
  let #(p, _) = load("priv/stdlib/dates.sheaf")
  let o = program.check(p, "Date", "2026-13-01")
  all([
    expect(program.check(p, "Date", "2024-02-29").ok, "2024 leap day"),
    expect(program.check(p, "Date", "2000-02-29").ok, "2000 leap day"),
    expect(
      !program.check(p, "Date", "2023-02-29").ok,
      "2023 is not a leap year",
    ),
    expect(
      !program.check(p, "Date", "1900-02-29").ok,
      "1900 is not a leap year",
    ),
    expect(!program.check(p, "Date", "2026-04-31").ok, "April has 30 days"),
    expect(
      list.any(o.failures, fn(f) { string.contains(f, "Month requires") }),
      "month 13 reported",
    ),
  ])
}

fn recursion_mapping_bytes() -> Outcome {
  let #(p, _) = load("examples/proofs/proofs.sheaf")
  let #(q, _) = load("priv/stdlib/bits.sheaf")
  let #(l, _) = load("priv/stdlib/logic.sheaf")
  let chain = program.check(p, "Chain", "+3+4+5")
  all([
    expect(num(get(p, chain.value, "total")) == "12", "chain total"),
    expect(num(get(p, chain.value, "links")) == "2", "chain size"),
    expect(
      num(get(p, program.check(p, "Parcel", "3 A").value, "tier")) == "light",
      "light parcel",
    ),
    expect(
      num(get(p, program.check(p, "Parcel", "30 B").value, "tier")) == "far",
      "far parcel",
    ),
    expect(
      num(get(q, program.check(q, "Byte", "01000001").value, "number")) == "65",
      "byte value",
    ),
    expect(
      num(get(l, program.check(l, "Xor_Gate", "TRUETRUE").value, "out"))
        == "FALSE",
      "xor",
    ),
  ])
}

fn ambiguity() -> Outcome {
  let assert Ok(#(p, _)) =
    source("Piece {\"a\" | \"aa\"}\nTwo {}\n  x {Piece}\n  y {Piece}\n")
  let o = program.check(p, "Two", "aaa")
  // A record's rules are checked before at most two readings are kept, so a
  // reading that fails a rule cannot hide two that hold: "1020" reads as 1020,
  // as 10 then 20, and as 1 then 20.
  let assert Ok(#(q, _)) =
    source(
      "Chain {}\n  key {Integer}\n  rest {Chain} qty: 0..1\n  later {Integer} count: rest\n  in_order {Needs} later = 0 | key <= rest.key\n",
    )
  let chain = program.check(q, "Chain", "1020")
  let single = program.check(q, "Chain", "5")
  all([
    expect(!o.ok && o.ambiguous, "aaa splits two ways"),
    expect(!chain.ok && chain.ambiguous, "1020 reads three ways that hold"),
    expect(single.ok, "5 reads one way"),
  ])
}

/// No imports: a file sees its folder, the folders above, each subfolder's
/// front file and the standard library (Step 10).
fn scope() -> Outcome {
  let #(m, _) = load("examples/meeting/meeting.sheaf")
  let #(shop, shop_rep) = load("examples/shop/orders/orders.sheaf")
  let #(_, peek) = load("examples/shop/orders/peek.sheaf")
  let cycle =
    program.load(base(False), program.join(cwd(), "examples/cycle/a.sheaf"))
  let order = "2026-10-15\nABC123 19.99\nXYZ042 5.00\n"
  let bundle =
    program.bundle_text([
      #("a/x.sheaf", "X {\"x\"}"),
      #("a/y.sheaf", "Y {\"y\" | X}\n"),
    ])
  all([
    expect(
      program.check(m, "Meeting", "2024-02-29 room_4").ok,
      "the standard library is in scope",
    ),
    expect(
      !program.check(m, "Meeting", "2023-02-29 room_4").ok,
      "its rules apply",
    ),
    expect(check.errors(shop_rep) == [], "folder above and front file seen"),
    expect(
      num(get(shop, program.check(shop, "Order", order).value, "total"))
        == "24.99",
      "a project-wide order",
    ),
    expect(
      list.any(check.errors(peek), fn(d) { string.contains(d.msg, "Code") }),
      "a non-front file stays private",
    ),
    expect(
      case cycle {
        Error(e) -> string.contains(e.msg, "cycle")
        Ok(_) -> False
      },
      "a cycle between files is an error",
    ),
    expect(
      program.bundle_entries(bundle)
        == [#("a/x.sheaf", "X {\"x\"}\n"), #("a/y.sheaf", "Y {\"y\" | X}\n")],
      "a bundle splits into named texts",
    ),
    expect(
      program.check(base(False), "Project", bundle).ok,
      "a bundle inhabits Project",
    ),
    expect(
      result_is_error(source("import \"a.sheaf\"\n")),
      "import lines are gone",
    ),
  ])
}

fn graphs() -> Outcome {
  let #(p, _) = load("examples/orders/orders.sheaf")
  let g = graph.build(p, "examples/orders/orders.sheaf")
  let svg = graph.to_svg(g, graph.layout(g), "orders")
  let wires = list.length(g.edges)
  all([
    expect(list.any(g.nodes, fn(n) { n.id == "Order" }), "Order node"),
    expect(wires == 9, "wires: " <> int.to_string(wires)),
    expect(string.starts_with(svg, "<svg"), "svg"),
    expect(
      dict.size(graph.layout(g)) == list.length(g.nodes),
      "every node placed",
    ),
  ])
}

fn grids() -> Outcome {
  let #(p, _) = load("priv/stdlib/bits.sheaf")
  let assert Ok(d) = dict.get(p.decls, "Xor_Bit")
  let assert Some(f) = model.field(d, "out")
  case check.mapping_grid(p.decls, p.index, d, f) {
    Some(g) ->
      expect(
        list.length(g.cells) == 4
          && list.all(g.cells, fn(c) { list.length(c.1) == 1 }),
        "2x2, one case per cell",
      )
    None -> Fail("no grid")
  }
}

/// The number of declarations in priv/language.sheaf.
const spec_decls = 156

const inter_src =
  "Letters {Uppercase} qty: 3
Code {Text}
  1. {Letters}
  2. {\"-\"}
  3. {Digit} qty: 1..
Short_Text {Character} qty: 0..8
Short_Code {Code & Short_Text}
Four {Integer}
  1. {Digit} qty: 4
Year {Four & Integer}
"

/// A text inhabits {A & B} when both match the same span; values come from A.
fn intersection() -> Outcome {
  let assert Ok(#(p, rep)) = source(inter_src)
  let year = program.check(p, "Year", "2026")
  all([
    expect(check.errors(rep) == [], "intersections check clean"),
    expect(program.check(p, "Short_Code", "ABC-1234").ok, "8 characters fit"),
    expect(!program.check(p, "Short_Code", "ABC-12345").ok, "9 do not"),
    expect(!program.check(p, "Short_Code", "abc-1").ok, "shape still required"),
    expect(
      year.value == Some(VNumber(decimal.from_int(2026)))
        || option.map(year.value, num) == Some("2026"),
      "value from the first type",
    ),
    expect(
      result_is_error(source("X {}\n  f {Code & Code}\n")),
      "intersection only at top level",
    ),
  ])
}

const loose_src =
  "Zone {\"A\"|\"B\"}
Tier {\"light\" |   \"heavy\" | \"far\"}
Parcel {}
  weight {Integer} value: 0..50
  zone {Zone}
  spare {Integer} value: 0..9
  more {Integer} value: weight +  spare+1
  check {Needs} spare  >=  0 & weight <= 50
  tier {Tier} (weight, zone)
    {\"light\"} if: weight = 0..5   &  zone = \"A\"
    {\"heavy\"} if: weight = 6..50&zone = \"A\"
    {\"far\"} if: zone = \"B\"
  text {Text}
    1. {weight}
    2. {\" \"}
    3. {zone}
    4. {spare}
"

/// Spaces around & | -> + - * are free; comparisons need a space on each
/// side; settings take none; lines are at most 100 characters, without tabs.
fn spacing() -> Outcome {
  let assert Ok(#(p, rep)) = source(loose_src)
  let parcel = program.check(p, "Parcel", "7 A4")
  all([
    expect(check.errors(rep) == [], "loose spacing checks clean"),
    expect(num(get(p, parcel.value, "more")) == "12", "loose arithmetic"),
    expect(num(get(p, parcel.value, "tier")) == "heavy", "loose mapping"),
    expect(
      is_ok(source("X {}\n  x {Integer}\n  r {Needs} x=1..2 & x>=1\n")),
      "comparisons take any spacing",
    ),
    expect(
      result_is_error(source("X {}\n  x {Digit 2}\n")),
      "braces hold only a type: qty: is an item",
    ),
    expect(
      result_is_error(source("X {\"a\" | \"b\"} qty: 2\n")),
      "a union takes no items",
    ),
    expect(
      result_is_error(source("X {}\n  n {Integer} value: 1, cost: 1\n")),
      "cost is not an item: the checker works out every cost",
    ),
    expect(
      result_is_error(source("X {}\n  x {Integer}\tvalue: 0..9\n")),
      "tabs are rejected",
    ),
    expect(
      result_is_error(source("# " <> string.repeat("x", 99) <> "\n")),
      "101 characters are too many",
    ),
    expect(
      is_ok(source("# " <> string.repeat("x", 98) <> "\n")),
      "100 characters fit",
    ),
  ])
}

fn json(text: String) -> printer.PV {
  let assert Ok(v) = printer.parse_json(text)
  v
}

/// Printing is parsing run backwards, checked by reading the text back.
fn printing() -> Outcome {
  let #(o, _) = load("examples/orders/orders.sheaf")
  let #(d, _) = load("priv/stdlib/dates.sheaf")
  let order =
    printer.print(
      o,
      "Order",
      json(
        "{\"number\": 1042, \"lines\": [{\"sku\": \"ABC-0001\", \"units\": 3, \"price\": 19.9}]}",
      ),
    )
  let leap =
    printer.print(
      d,
      "Date",
      json("{\"year\": 2024, \"month\": 2, \"day\": 29}"),
    )
  let not_leap =
    printer.print(
      d,
      "Date",
      json("{\"year\": 2023, \"month\": 2, \"day\": 29}"),
    )
  let rounding =
    printer.print(
      o,
      "Line",
      json("{\"sku\": \"ABC-0001\", \"units\": 3, \"price\": 19.999}"),
    )
  let typo =
    printer.print(
      o,
      "Line",
      json("{\"sku\": \"ABC-0001\", \"unit\": 3, \"price\": 1}"),
    )
  let base = base(False)
  let loose =
    "X {}\n  a  {Integer}   value:  0..9   \n  b {Integer} value: a*2 # twice\n"
  all([
    expect(order == Ok("order 1042\nABC-0001 x3 @ 19.90\n"), "order prints"),
    expect(leap == Ok("2024-02-29"), "dates pad their digits"),
    expect(result_is_error(not_leap), "an invalid date does not print"),
    expect(result_is_error(rounding), "printing never rounds"),
    expect(result_is_error(typo), "unknown fields are refused"),
    expect(
      printer.format(base, loose, "x.sheaf")
        == Ok(
        "X {}\n  a {Integer} value: 0..9\n  b {Integer} value: a * 2 # twice\n",
      ),
      "fmt: canonical spacing, comments kept",
    ),
    expect(
      printer.format(base, prelude(), "language.sheaf") == Ok(prelude()),
      "language.sheaf is formatted",
    ),
    expect(
      printer.print_text(o, "Line", "ABC-0001 x3 @ 19.90\n")
        == Ok("ABC-0001 x3 @ 19.90\n"),
      "data prints its values",
    ),
    expect(
      case
        printer.print_code(o, "Line", fn(f) {
          read_file(program.join(cwd(), f))
        })
      {
        Ok(code) ->
          string.contains(code, "big {True | False} (line_total)")
          && string.starts_with(code, "#")
        Error(_) -> False
      },
      "a type prints its code, with its comment",
    ),
  ])
}

const filter_src =
  "Item {}
  d {Digit}
  w {Integer} value: 0..9
Box {}
  items {Item} qty: 1..
  heavy {Integer} count: items, filter: items.w >= 5
  hw {Integer} sum: items.w, filter: items.w >= 5
  ok {Claims} hw >= 0
"

/// {Type n} makes a list (no count means one); a filter keeps the items that
/// meet a condition; a list appears only inside a fold.
fn lists_and_filters() -> Outcome {
  let assert Ok(#(p, rep)) = source(filter_src)
  let b = program.check(p, "Box", "1726")
  let #(o, _) = load("examples/orders/orders.sheaf")
  let assert Ok(order) = read_file(cwd() <> "/examples/orders/order_1042.txt")
  let ord = program.check(o, "Order", order)
  let refused = fn(src) {
    case source(src) {
      Ok(#(_, r)) -> check.errors(r) != []
      Error(_) -> True
    }
  }
  all([
    expect(check.errors(rep) == [], "filters check clean"),
    expect(num(get(p, b.value, "heavy")) == "2", "count through a filter"),
    expect(num(get(p, b.value, "hw")) == "13", "sum through a filter"),
    expect(
      list.key_find(rep.claims, "Box.ok") |> is_ok,
      "claim through a filter",
    ),
    expect(num(get(o, ord.value, "big_lines")) == "1", "orders: big lines"),
    expect(
      num(get(o, ord.value, "big_total")) == "1200.00",
      "orders: big total",
    ),
    expect(
      refused(filter_src <> "  bad {Integer} value: items\n"),
      "a list outside a fold is refused",
    ),
    expect(
      refused("X {}\n  a {Digit}\n  b {Integer} count: a\n"),
      "one value is not a list",
    ),
  ])
}

/// Readings settled in the syntax review: a "-" position is a sign, places
/// on a refinement line is enforced, and a bare {True} field is an error.
fn context_paths() -> Outcome {
  let #(p, rep) = load("examples/book/book.sheaf")
  let assert Ok(good) = read_file("examples/book/book.txt")
  let assert Ok(unknown) = read_file("examples/book/book_unknown.txt")
  let ok = program.check(p, "Book", good)
  let bad = program.check(p, "Book", unknown)
  let lib =
    "Item {}\n  n {Integer}\n  within {Needs} n <= Box.limit\n  text {Text}\n    1. {n}\n    2. {Newline}\n\n"
    <> "Box {}\n  limit {Integer}\n  items {Item} qty: 0..\n  text {Text}\n    1. {limit}\n    2. {Newline}\n    3. {items}\n"
  let assert Ok(#(bp, brep)) = source(lib)
  let box = program.check(bp, "Box", "5\n3\n4\n")
  let over = program.check(bp, "Box", "5\n3\n7\n")
  let alone = program.check(bp, "Item", "3\n")
  let assert Ok(#(_, escaped)) =
    source(lib <> "\nShelf {}\n  items {Item} qty: 0..\n")
  let assert Ok(#(_, text_cmp)) =
    source(
      "Item {}\n  n {Natural}\n  text {Text}\n    1. {n}\n    2. {Newline}\n\n"
      <> "Box {}\n  items {Item} qty: 0..\n  bigs {Integer} count: items, filter: items.n > 5\n"
      <> "  text {Text}\n    1. {items}\n",
    )
  let assert Ok(#(_, not_rec)) =
    source("Two {\"2\"}\nR {}\n  a {Integer} value: Two.x\n")
  all([
    expect(check.errors(rep) == [], "book checks clean: " <> msgs(rep)),
    expect(ok.ok, "every order's customer exists"),
    expect(
      !bad.ok
        && list.any(bad.failures, fn(f) {
        string.contains(f, "Book.each_order_has_its_customer")
        && string.contains(f, "orders item 2: customer is")
      }),
      "an unknown customer is caught, naming the order",
    ),
    expect(
      list.any(alone.failures, fn(f) {
        string.contains(f, "there is no Box around this Item")
      }),
      "an Item alone has no Box around it",
    ),
    expect(check.errors(brep) == [], "a rule on an outer field: " <> msgs(brep)),
    expect(box.ok, "items within the box limit"),
    expect(
      !over.ok
        && list.any(over.failures, fn(f) { string.contains(f, "within") }),
      "an item above the box limit breaks its rule",
    ),
    expect(
      string.contains(msgs(escaped), "Shelf holds it without one around"),
      "a holder outside the context is an error",
    ),
    expect(string.contains(msgs(not_rec), "is not a record"), "non-record head"),
    expect(
      string.contains(msgs(text_cmp), "n is Natural, not a number"),
      "a filter's comparison needs numbers: " <> msgs(text_cmp),
    ),
    expect(
      list.contains(rep.costs, #("Book", "O(customers.qty + orders.qty)")),
      "cost of a relation",
    ),
  ])
}

const tied_src =
  "Element {Integer} value: 0..9
  1. {Digit}

Mul {}
  left {Element}
  right {Element}
  out {Element}

Holder {}
  m {Mul}
  half {Needs} m.out <= 4
"

/// A field typed by a record holds its values, so a path reaches the record's
/// fields through it, and a rule in the record that holds both ties them
/// together (examples/xor).
fn tied_by_rules() -> Outcome {
  let assert Ok(#(p, rep)) = source(tied_src)
  let good = program.check(p, "Holder", "123")
  let half = program.check(p, "Holder", "125")
  let #(x, xrep) = load("examples/xor/xor.sheaf")
  let run = fn(name) {
    let assert Ok(text) = read_file("examples/xor/" <> name <> ".txt")
    program.check(x, "Assoc", text)
  }
  let refused_by = fn(o: program.Outcome, what) {
    !o.ok && list.any(o.failures, fn(f) { string.contains(f, what) })
  }
  all([
    expect(check.errors(rep) == [], "fields through a record: " <> msgs(rep)),
    expect(good.ok, "a value of the record"),
    expect(refused_by(half, "Holder.half"), "a rule through a field"),
    expect(check.errors(xrep) == [], "examples/xor: " <> msgs(xrep)),
    expect(run("xor").ok, "products that fit their rules"),
    expect(
      refused_by(run("xor_bc"), "Assoc.bc_takes_b_and_c"),
      "a rule tying a product to the inputs",
    ),
    expect(
      refused_by(run("xor_ab_c"), "Assoc.ab_c_takes_ab_out_and_c"),
      "a rule tying a product to another product",
    ),
  ])
}

fn review_readings() -> Outcome {
  let #(t, trep) = load("examples/temperature/temperature.sheaf")
  let reading = program.check(t, "Reading", "oslo -12")
  let #(m, _) = load("examples/shop/money.sheaf")
  let refused = fn(src) {
    case source(src) {
      Ok(#(_, r)) -> check.errors(r) != []
      Error(_) -> True
    }
  }
  all([
    expect(check.errors(trep) == [], "temperature checks clean"),
    expect(num(get(t, reading.value, "degrees")) == "-12", "a sign is read"),
    expect(num(get(t, reading.value, "freezing")) == "TRUE", "and used"),
    expect(!program.check(t, "Temperature", "-95").ok, "range still applies"),
    expect(
      printer.print(t, "Temperature", json("-7")) == Ok("-7"),
      "a sign is printed",
    ),
    expect(!program.check(m, "Money", "19.9").ok, "places on a refinement"),
    expect(program.check(m, "Money", "19.90").ok, "two places fit"),
    expect(refused("X {}\n  a {Integer}\n  ok {True}\n"), "bare {True}"),
    expect(
      result_is_error(source("X {}\n  v {Integer} value: 5..5\n")),
      "a range spans more than one value",
    ),
    expect(
      case source("X {}\n  v {Digit}\n  w {Integer} value: 5\n") {
        Ok(#(p, _)) -> {
          let x = program.check(p, "X", "7")
          x.ok && num(get(p, x.value, "w")) == "5"
        }
        Error(_) -> False
      },
      "value: 5 computes a fixed value",
    ),
    expect(
      result_is_error(source("X {}\n  v {5}\n")),
      "a stored field with one possible text holds no data",
    ),
  ])
}

const tree_src =
  "Node {}
  w {Integer} value: 0..9
  kids {Node} qty: 0..
  kid_count {Integer} count: kids
  kid_nodes {Integer} sum: kids.nodes
  nodes {Integer} value: kid_count + kid_nodes
  kid_weight {Integer} sum: kids.weight
  weight {Integer} value: w + kid_weight
  ok {Claims} weight >= 0
  text {Text}
    1. {\"(\"}
    2. {w}
    3. {kids}
    4. {\")\"}
"

const grid_src =
  "Cell {}
  d {Digit}
Row {}
  cells {Cell} qty: 0..
  n {Integer} count: cells
  text {Text}
    1. {cells}
    2. {\";\"}
Grid {}
  rows {Row} qty: 0..
  total {Integer} sum: rows.n
"

const split_src =
  "Split {}
  total {Decimal} value: -10..10, places: 2
  people {Integer} value: 1..20
  text {Text}
    1. {total}
    2. {\" \"}
    3. {people}
  share {Decimal} value: total / people, places: 2, round: Half_Even
  share_low {Claims} share >= -10
  share_high {Claims} share <= 10
  down {Decimal} value: total / people, places: 1, round: Floor
  up {Decimal} value: total / people, places: 1, round: Ceiling
  whole {Integer} value: total, round: Half_Up
"

const third_src =
  "Third {}
  total {Decimal} value: 0..1, places: 2
  third {Decimal} value: total / 3, places: 2, round: Half_Even
  close {Claims} third <= 0.33
"

// After value:, a range or a choice checks a number read from the text; a
// number, a path or a calculation works it out, so it is not in the text.
fn value_checks_or_works_out() -> Outcome {
  let ticket = fn(seats) {
    "Ticket {}\n  seats {Integer} value: "
    <> seats
    <> "\n  price {Integer} value: 1..500\n  total {Integer} value: seats * price\n"
  }
  let read = fn(seats, text) {
    case
      source(
        ticket(seats)
        <> "  text {Text}\n    1. {seats}\n    2. {\" x \"}\n    3. {price}\n",
      )
    {
      Ok(#(p, _)) -> {
        let x = program.check(p, "Ticket", text)
        case x.ok {
          True -> num(get(p, x.value, "total"))
          False -> "refused"
        }
      }
      Error(e) -> model.error_text(e)
    }
  }
  let assert Ok(#(fixed, fixed_rep)) = source(ticket("2"))
  let fixed_total = fn(text) {
    let x = program.check(fixed, "Ticket", text)
    case x.ok {
      True -> num(get(fixed, x.value, "total"))
      False -> "refused"
    }
  }
  let old = case
    source("X {}\n  a {Integer} value: 0..9\n  b {Integer} calc: a * 2\n")
  {
    Ok(_) -> ""
    Error(e) -> model.error_text(e)
  }
  all([
    expect(read("2 | 3", "2 x 40") == "80", "a choice reads the number"),
    expect(read("2 | 3", "4 x 40") == "refused", "and checks it"),
    expect(read("1..9", "3 x 40") == "120", "a range reads the number"),
    expect(
      check.errors(fixed_rep) == [],
      "value: 2 checks clean: " <> msgs(fixed_rep),
    ),
    expect(fixed_total("40") == "80", "value: 2 is always 2, not in the text"),
    expect(
      fixed_total("2 x 40") == "refused",
      "so the text holds only the price",
    ),
    expect(
      string.contains(read("2", "2 x 40"), "computed"),
      "a shape cannot name a worked-out field",
    ),
    expect(string.contains(old, "calc: is gone"), "calc: is refused: " <> old),
  ])
}

fn division_and_rounding() -> Outcome {
  let assert Ok(#(p, rep)) = source(split_src)
  let at = fn(text, name) {
    let x = program.check(p, "Split", text)
    case x.ok {
      True -> num(get(p, x.value, name))
      False -> "refused"
    }
  }
  let errors_of = fn(src) {
    case source(src) {
      Ok(#(_, r)) -> msgs(r)
      Error(e) -> model.error_text(e)
    }
  }
  let refused_with = fn(line, why) {
    string.contains(
      errors_of(
        "X {}\n  a {Integer} value: -5..5\n  b {Integer} value: 10 | 30\n  text {Text}\n    1. {a}\n    2. {\" \"}\n    3. {b}\n"
        <> line
        <> "\n",
      ),
      why,
    )
  }
  let #(_, third_rep) = case source(third_src) {
    Ok(r) -> r
    Error(_) -> #(p, check.empty_report())
  }
  all([
    expect(check.errors(rep) == [], "Split checks clean: " <> msgs(rep)),
    expect(at("10.00 3", "share") == "3.33", "10 / 3"),
    expect(at("0.05 2", "share") == "0.02", "a tie goes to even, down"),
    expect(at("0.15 2", "share") == "0.08", "a tie goes to even, up"),
    expect(at("-0.15 2", "share") == "-0.08", "and below 0"),
    expect(at("-1.00 3", "down") == "-0.4", "Floor below 0"),
    expect(at("-1.00 3", "up") == "-0.3", "Ceiling below 0"),
    expect(at("1.00 3", "down") == "0.3", "Floor above 0"),
    expect(at("1.00 3", "up") == "0.4", "Ceiling above 0"),
    expect(at("-2.50 1", "whole") == "-3", "Half_Up goes away from zero"),
    expect(at("9.00 3", "up") == "3.0", "an exact quotient is kept"),
    expect(
      check.errors(third_rep) == [],
      "half a unit proves third <= 0.33: " <> msgs(third_rep),
    ),
    expect(
      string.contains(
        errors_of(string.replace(third_src, "Half_Even", "Floor")),
        "cannot prove third <= 0.33",
      ),
      "Floor is only within one unit",
    ),
    expect(
      refused_with(
        "  q {Decimal} value: b / a, places: 2, round: Half_Even",
        "cannot prove the divisor a is never 0",
      ),
      "a divisor that may be 0",
    ),
    expect(
      !refused_with(
        "  q {Decimal} value: a / b, places: 2, round: Half_Even",
        "divisor",
      ),
      "a choice of values that leaves out 0",
    ),
    expect(
      refused_with(
        "  q {Decimal} value: a / b, round: Half_Even",
        "says how many places it rounds to",
      ),
      "a rounded Decimal names its places",
    ),
    expect(
      refused_with(
        "  q {Integer} value: a + b, round: Floor",
        "nothing to round",
      ),
      "round: on a calculation that never needs it",
    ),
    expect(
      refused_with(
        "  q {Integer} value: a / b, round: X",
        "is not a rounding rule",
      ),
      "round: names a rule",
    ),
    expect(
      refused_with(
        "  q {Decimal} value: a / b, places: 2",
        "names its rounding rule",
      ),
      "a quotient without round:",
    ),
    expect(
      refused_with(
        "  q {Decimal} value: a * b, places: 2",
        "rounding never happens implicitly",
      )
        == False,
      "a product of whole numbers needs no rounding",
    ),
  ])
}

fn timed(f: fn() -> a) -> #(a, Float) {
  let t = now_ms()
  let x = f()
  #(x, now_ms() -. t)
}

/// Parsing and checking stay linear: a deep chain, a wide tree and a long
/// sequence, each within a time budget generous enough for a slow machine.
fn speed() -> Outcome {
  let #(p, _) = load("examples/proofs/proofs.sheaf")
  let #(chain, t1) =
    timed(fn() { program.check(p, "Chain", string.repeat("+1", 200)) })
  let assert Ok(#(tp, trep)) = source(tree_src)
  let wide = "(1" <> string.repeat("(2)", 5000) <> ")"
  let #(tree, t2) = timed(fn() { program.check(tp, "Node", wide) })
  let #(o, _) = load("examples/orders/orders.sheaf")
  let lines = string.repeat("ABC-0001 x3 @ 19.99\n", 2000)
  let #(order, t3) =
    timed(fn() { program.check(o, "Order", "order 7\n" <> lines) })
  let assert Ok(#(_, grep)) = source(grid_src)
  all([
    expect(num(get(p, chain.value, "links")) == "199", "200-deep chain"),
    expect(t1 <. 1500.0, "deep chain in time: " <> float_text(t1)),
    expect(num(get(tp, tree.value, "nodes")) == "5000", "5000 children"),
    expect(t2 <. 4000.0, "wide tree in time: " <> float_text(t2)),
    expect(num(get(o, order.value, "line_count")) == "2000", "2000 lines"),
    expect(t3 <. 4000.0, "long order in time: " <> float_text(t3)),
    expect(
      list.key_find(trep.claims, "Node.ok") |> is_ok,
      "induction through a sum",
    ),
    expect(check.errors(grep) == [], "nested fold costs the flattened size"),
    expect(
      list.key_find(grep.costs, "Grid") == Ok("O(rows.cells.qty + rows.qty)"),
      "grid cost is a sum",
    ),
  ])
}

fn float_text(x: Float) -> String {
  int.to_string(float.round(x)) <> " ms"
}

/// 'if:' belongs to cases; a type never narrows another by a condition; a
/// filter takes a condition written through its list; a relation between two
/// lists is a rule in the record that holds both. Every old form says what
/// to write instead.
fn conditions_filters_relations() -> Outcome {
  let refused = fn(text, needle) {
    case source(text) {
      Error(e) -> string.contains(e.msg, needle)
      Ok(_) -> False
    }
  }
  let flagged = fn(text, needle) {
    case source(text) {
      Ok(#(_, r)) -> string.contains(msgs(r), needle)
      Error(_) -> False
    }
  }
  let box =
    "Item {}\n  d {Digit}\n  w {Integer} value: 0..9\n"
    <> "Box {}\n  items {Item} qty: 1..\n"
  let counted = fn(filter) {
    let assert Ok(#(p, _)) =
      source(box <> "  n {Integer} count: items, filter: " <> filter <> "\n")
    num(get(p, program.check(p, "Box", "1726").value, "n"))
  }
  let rel = fn(unique, customer, line) {
    "Customer {}\n  code {Natural}"
    <> unique
    <> "\n  text {Text}\n    1. {code}\n    2. {Newline}\n\n"
    <> "Order {}\n  customer {"
    <> customer
    <> "}\n  text {Text}\n    1. {customer}\n    2. {Newline}\n\n"
    <> "Book {}\n  customers {Customer} qty: 1..\n  orders {Order} qty: 0..\n"
    <> line
    <> "\n"
  }
  let tie = "  ok {Needs} orders.customer = customers.code"
  all([
    expect(
      refused(
        "Order {}\n  total {Decimal}\nBig_Order {Order} if: total >= 1000.00\n",
        "'Big_Order {Order} if: ...' is gone",
      ),
      "a type narrowing a record by a condition",
    ),
    expect(
      refused(
        "Line {}\n  w {Integer}\nCart {}\n  lines {Line} qty: 0..9\n  n {Integer} count: lines.Big_Line\n",
        "'lines.Big_Line' is gone",
      ),
      "a type name in a path",
    ),
    expect(
      refused("Money {Decimal} places: 2, if: value >= 0.00\n", "value: 0.00.."),
      "a number is restricted with value:",
    ),
    expect(
      refused(
        box <> "  n {Integer} count: items, filter: Heavy\n",
        "takes a condition, not a type",
      ),
      "filter: by a type",
    ),
    expect(
      refused(
        box <> "  n {Integer} count: items, filter: w >= 5\n",
        "filter: items.w >= 5",
      ),
      "a field not written through the list",
    ),
    expect(
      refused(
        box <> "  n {Integer} count: items, filter: items.w >= Box.limit\n",
        "a filter compares each item with a number",
      ),
      "a filter against another record",
    ),
    expect(
      refused(
        box
          <> "  limit {Integer}\n  n {Integer} count: items, filter: items.w >= limit\n",
        "a filter compares each item with a number",
      ),
      "a filter against another field",
    ),
    expect(
      refused(
        box <> "  n {Integer} value: 1, filter: items.w >= 5\n",
        "beside count: or sum:",
      ),
      "filter: with no fold",
    ),
    expect(
      flagged(
        box <> "  n {Integer} count: items, filter: items.zzz >= 5\n",
        "zzz",
      ),
      "a filter naming no field",
    ),
    expect(counted("items.w >= 6") == "2", "a condition"),
    expect(
      counted("items.w >= 6 & items.w <= 6") == "1",
      "conditions joined by &",
    ),
    expect(counted("items.w = 6 | 7") == "2", "a choice of values"),
    expect(counted("items.w = 3") == "0", "no item meets it"),
    expect(
      is_ok(source(rel(" unique: True", "Natural", tie))),
      "a relation checks clean",
    ),
    expect(
      flagged(rel("", "Natural", tie), "must be unique"),
      "a relation needs a unique key",
    ),
    expect(
      flagged(
        rel(
          " unique: True",
          "Natural",
          "  ok {Needs} orders.customer >= customers.code",
        ),
        "uses = only",
      ),
      "a relation uses =",
    ),
    expect(
      flagged(
        rel(
          " unique: True",
          "Natural",
          "  ok {Claims} orders.customer = customers.code",
        ),
        "a rule, not a claim",
      ),
      "a relation is not a claim",
    ),
    expect(
      flagged(
        rel(
          " unique: True",
          "Natural",
          tie <> " & orders.customer = customers.code",
        ),
        "a line of its own",
      ),
      "a relation is alone on its line",
    ),
    expect(
      flagged(rel(" unique: True", "Digit", tie), "same type"),
      "a relation compares the same type",
    ),
  ])
}

pub fn main() {
  let tests = [
    #("bootstrap", bootstrap),
    #("decimals", decimals),
    #("last line without newline", last_line_without_newline),
    #("syntax errors", syntax_errors),
    #("And_Gate short circuit", and_gate_short_circuit),
    #("Bounded_Range rule", bounded_range_rule),
    #("mistakes file", mistakes),
    #("geometric mistakes", geometric_mistakes),
    #("sequents", sequents_print),
    #("mapping outputs and inputs", mapping_outputs_and_inputs),
    #("claims and costs", claims_and_costs),
    #("libraries check clean", libraries_clean),
    #("orders", orders),
    #("dates", dates),
    #("recursion, mappings, bytes", recursion_mapping_bytes),
    #("ambiguity", ambiguity),
    #("project scope", scope),
    #("graphs", graphs),
    #("mapping grids", grids),
    #("speed, depth, nested costs", speed),
    #("type intersection", intersection),
    #("spacing and line length", spacing),
    #("printing and fmt", printing),
    #("lists and filters", lists_and_filters),
    #("review readings", review_readings),
    #("context paths", context_paths),
    #("records tied by rules", tied_by_rules),
    #("conditions, filters and relations", conditions_filters_relations),
    #("division and rounding", division_and_rounding),
    #("value: checks or works out", value_checks_or_works_out),
    #("rules, claims and mapping inputs", rules_claims_and_inputs),
  ]
  let failed =
    list.fold(tests, 0, fn(failed, t) {
      case { t.1 }() {
        Pass -> {
          io.println("ok    " <> t.0)
          failed
        }
        Fail(why) -> {
          io.println("FAIL  " <> t.0 <> ": " <> why)
          failed + 1
        }
      }
    })
  io.println(case failed {
    0 -> "\nall " <> int.to_string(list.length(tests)) <> " passed"
    n -> "\n" <> int.to_string(n) <> " failed"
  })
  case failed {
    0 -> Nil
    _ -> exit(1)
  }
  let _ = None
  Nil
}

/// Rules are 'name {Needs} condition' and claims 'name {Claims} condition';
/// a mapping's inputs go in parentheses after its type. The old forms, a
/// field that could only be TRUE or FALSE, and a bare alias are refused.
fn rules_claims_and_inputs() -> Outcome {
  let refused = fn(text, needle) {
    case source(text) {
      Error(e) -> string.contains(e.msg, needle)
      Ok(_) -> False
    }
  }
  let r = "R {}\n  a {Integer} value: 0..9\n  b {Integer} value: a + 1\n"
  let assert Ok(#(p, rep)) =
    source(
      r
      <> "  ok {Needs} a <= 8\n  pos {Claims} a >= 0\n  big {True | False} (a)\n"
      <> "    {True} if: a >= 5\n    {False} if: a <= 4\n",
    )
  let o = program.check(p, "R", "3")
  let refused_rule = program.check(p, "R", "9")
  all([
    expect(check.errors(rep) == [], "the new forms check clean"),
    expect(o.ok && num(get(p, o.value, "ok")) == "TRUE", "a rule holds"),
    expect(num(get(p, o.value, "big")) == "FALSE", "a mapping on (a)"),
    expect(!refused_rule.ok, "a failed rule refuses the record"),
    expect(list.key_find(rep.claims, "R.pos") |> is_ok, "a claim is proved"),
    expect(refused(r <> "  ok {True} if: a <= 8\n", "{Needs}"), "old rule"),
    expect(refused(r <> "  pos {Claim} if: a >= 0\n", "{Claims}"), "old claim"),
    expect(
      refused(r <> "  ok {Needs} if: a <= 8\n", "no if:"),
      "{Needs} takes no if:",
    ),
    expect(refused(r <> "  ok {Needs}\n", "condition"), "{Needs} alone"),
    expect(
      refused(r <> "  pos {Claims} a >= 0 & b >= 0\n", "one comparison"),
      "a claim holds one comparison",
    ),
    expect(refused(r <> "  t {True}\n", "{True | False}"), "a {True} field"),
    expect(
      refused(r <> "  t {False} value: a\n", "{True | False}"),
      "a {False} field",
    ),
    expect(
      refused(r <> "  t {Integer} value: a, if: a = 1\n", "only for the cases"),
      "if: on a field line",
    ),
    expect(
      refused(
        r <> "  big {True | False} from: a\n    {True} if: a >= 0\n",
        "from: is gone",
      ),
      "from: is gone",
    ),
    expect(
      refused(
        r <> "  big {True | False} (a & b)\n    {True} if: a >= 0\n",
        "comma",
      ),
      "inputs joined by &",
    ),
    expect(
      refused(
        r <> "  big {True | False} (a, b, a)\n    {True} if: a >= 0\n",
        "one or two inputs",
      ),
      "three inputs",
    ),
    expect(
      refused(r <> "  big {True | False} (a)\n", "needs case lines"),
      "a mapping without cases",
    ),
    expect(
      refused(
        r <> "  t {True} (a)\n    {True} if: a >= 0\n",
        "always gives that value",
      ),
      "a mapping whose only output is {True}",
    ),
    expect(refused("Yes {True}\n", "adds nothing"), "an alias of True"),
    expect(refused("Must {Needs}\n", "adds nothing"), "an alias of Needs"),
    expect(refused("Two_Digits {Digit}\n", "adds nothing"), "a bare alias"),
    expect(is_ok(source("Two_Digits {Digit} qty: 2\n")), "a refinement adds"),
  ])
}
