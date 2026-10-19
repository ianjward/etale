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
        "Thing {}\n  a {Integer}\n  b {Integer} val = 1 & a = 2 | a = 3\n",
      )),
      "& mixed with |",
    ),
    expect(
      result_is_error(source("Two {\"a\" | \"b\"} val = \"a\"\n")),
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
      "rounding never happens", "cost promise broken",
      "not a number, so it cannot be multiplied", "must always sit inside",
    ],
    fn(needle) { expect(string.contains(text, needle), needle) },
  )
  |> all
}

fn geometric_mistakes() -> Outcome {
  let #(_, rep) = load("examples/mistakes/geometric.sheaf")
  let text = msgs(rep)
  let wrapped =
    "Clock {}\n  hour {Integer} val = 0..23\n"
    <> "  later {Integer} val = hour + 5 & mod = 24\n  in_day {Fact} later <= 23\n"
  let assert Ok(#(_, ok)) = source(wrapped)
  let assert Ok(#(table, _)) =
    source(
      "Row {}\n  p {Decimal} unique\n  nl {Newline}\nTable {}\n  rows {Row 1..}\n",
    )
  all([
    expect(
      list.length(string.split(text, "needs a positive number written out"))
        == 3,
      "mod needs a positive written divisor",
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
    has(orders, "Big_Line(t) ⊣⊢ Line(t) ∧ t.line_total ≥ 500.00"),
    has(orders, "Order(t) ⊢ t.total = t.lines.line_total.sum"),
    has(orders, "Line(t) ∧ t.line_total ≥ 500.00 ⊢ t.big = TRUE"),
    has(orders, "∧ Line{1..}(lines)"),
    has(
      book,
      "Its_Customer(t) ⊣⊢ Customer(t) ∧ t.code = around(t, Order).customer",
    ),
    has(book, "around(t, Book).customers.Its_Customer.qty = 1"),
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
      "Two {\"x\" | \"y\"}\nM {}\n  a {Fact}\n  out {a -> Two}\n    | {\"x\"} a = True\n    | {\"x\"} a = False\n",
    )
  let assert Ok(#(_, r2)) =
    source("M {}\n  t {Text}\n  out {t -> Fact}\n    | {True} t = \"a\"\n")
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
      "examples/orders/orders.sheaf", "examples/proofs/proofs.sheaf",
      "examples/meeting/meeting.sheaf",
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
    expect(program.check(p, "Big_Order", t).ok, "is a Big_Order"),
    expect(
      program.check(p, "Order", small).ok
        && !program.check(p, "Big_Order", small).ok,
      "filter",
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
      num(get(q, program.check(q, "Byte", "01000001").value, "value")) == "65",
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
  expect(!o.ok && o.ambiguous, "aaa splits two ways")
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
    program.bundle_text([#("a/x.sheaf", "X {\"x\"}"), #("a/y.sheaf", "Y {X}\n")])
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
        == [#("a/x.sheaf", "X {\"x\"}\n"), #("a/y.sheaf", "Y {X}\n")],
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
    expect(list.any(g.nodes, fn(n) { n.id == "Big_Order" }), "Big_Order node"),
    expect(wires > 10, "wires"),
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
const spec_decls = 130

const inter_src =
  "Letters {Uppercase 3}
Code {Text}
  1. {Letters}
  2. {\"-\"}
  3. {Digit 1..}
Short_Text {Character 0..8}
Short_Code {Code & Short_Text}
Four {Integer}
  1. {Digit 4}
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
  weight  {Integer}   val = 0..50
  space   {\" \"}
  zone    {Zone}
  spare  {Integer}   val = 0..9
  more    {Integer}   val = weight +  spare+1
  check   {True}      spare  >=  0 & weight <= 50
  tier    {weight&zone->Tier}
    | {\"light\"}   weight = 0..5   &  zone = \"A\"
    | {\"heavy\"} weight = 6..50&zone = \"A\"
    | {\"far\"}     zone = \"B\"   
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
      is_ok(source("X {}\n  x {Integer} val=1..2 & places=0\n")),
      "comparisons take any spacing",
    ),
    expect(
      result_is_error(source("X {}\n  x {Digit} qty = 2\n")),
      "qty is no longer a setting",
    ),
    expect(
      result_is_error(source("X {\"a\" | \"b\" 2}\n")),
      "a count goes after a single item",
    ),
    expect(
      result_is_error(source("X {}\n  n {Integer} val = 1 & cost = 1\n")),
      "cost is written as a promise, cost <= ...",
    ),
    expect(
      result_is_error(source("X {}\n  x {Integer}\tval = 1\n")),
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
    "X {}\n  a  {Integer}   val = 0..9   \n  b {Integer} val = a*2 # twice\n"
  all([
    expect(order == Ok("order 1042\nABC-0001 x3 @ 19.90\n"), "order prints"),
    expect(leap == Ok("2024-02-29"), "dates pad their digits"),
    expect(result_is_error(not_leap), "an invalid date does not print"),
    expect(result_is_error(rounding), "printing never rounds"),
    expect(result_is_error(typo), "unknown fields are refused"),
    expect(
      printer.format(base, loose, "x.sheaf")
        == Ok(
        "X {}\n  a {Integer} val = 0..9\n  b {Integer} val = a * 2 # twice\n",
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
        printer.print_code(o, "Big_Line", fn(f) {
          read_file(program.join(cwd(), f))
        })
      {
        Ok(code) ->
          string.contains(code, "Big_Line {Line} line_total >= 500.00")
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
  w {Integer} val = 0..9
Heavy {Item} w >= 5
Box {}
  items {Item 1..}
  heavy {Integer} val = items.Heavy.qty
  hw {Integer} val = items.Heavy.w.sum
  ok {Fact} hw >= 0
"

/// {Type n} makes a list (no count means one); a type-named step filters it;
/// a list appears only inside a fold.
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
      refused(filter_src <> "  bad {Integer} val = items.Heavy\n"),
      "a list outside a fold is refused",
    ),
    expect(
      refused("X {}\n  a {Digit}\n  b {Integer} val = a.qty\n"),
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
  let alone = program.check(p, "Order", "1041 C001\n")
  let lib =
    "Item {}\n  n {Integer}\n  nl {Newline}\n\n"
    <> "Big {Item} n > Box.limit\n\n"
    <> "Box {}\n  limit {Integer}\n  nl {Newline}\n  items {Item 0..}\n"
    <> "  bigs {Integer} val = items.Big.qty\n"
  let assert Ok(#(bp, brep)) = source(lib)
  let box = program.check(bp, "Box", "5\n3\n7\n9\n")
  let assert Ok(#(_, escaped)) =
    source(
      lib
      <> "\nShelf {}\n  items {Item 0..}\n  bigs {Integer} val = items.Big.qty\n",
    )
  let assert Ok(#(_, text_cmp)) =
    source(
      string.replace(lib, "n {Integer}", "n {Natural}")
      |> string.replace("limit {Integer}", "limit {Natural}"),
    )
  let assert Ok(#(_, not_rec)) =
    source("Two {\"2\"}\nR {}\n  a {Integer} val = Two.x\n")
  let assert Ok(#(_, promised)) =
    source(
      "C {}\n  k {Natural}\n  nl {Newline}\n\nMine {C} k = O.k\n\n"
      <> "O {}\n  k {Natural}\n  nl {Newline}\n"
      <> "  n {Integer} val = B.cs.Mine.qty & cost <= B.cs.qty\n\n"
      <> "B {}\n  cs {C 0..}\n  os {O 0..}\n",
    )
  all([
    expect(check.errors(rep) == [], "book checks clean: " <> msgs(rep)),
    expect(ok.ok, "every order's customer exists"),
    expect(
      !bad.ok
        && list.any(bad.failures, fn(f) { string.contains(f, "Order.known") }),
      "an unknown customer is caught after the parse",
    ),
    expect(
      list.any(alone.failures, fn(f) {
        string.contains(f, "there is no Book around this Order")
      }),
      "an Order alone has no Book around it",
    ),
    expect(check.errors(brep) == [], "filter by an outer field: " <> msgs(brep)),
    expect(num(get(bp, box.value, "bigs")) == "2", "items above the box limit"),
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
      check.errors(promised) == [],
      "cost names the outer list: " <> msgs(promised),
    ),
    expect(
      list.contains(rep.costs, #("Order", "O(Book.customers.qty)")),
      "cost of a lookup",
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
      result_is_error(source("X {}\n  v {Integer} val = 5..5\n")),
      "a range spans more than one value",
    ),
    expect(
      case source("X {}\n  v {5}\n  w {Integer} val = 5\n") {
        Ok(#(p, _)) -> {
          let x = program.check(p, "X", "5")
          x.ok && num(get(p, x.value, "w")) == "5"
        }
        Error(_) -> False
      },
      "a fixed value is a literal; val = 5 computes",
    ),
  ])
}

const tree_src =
  "Node {}
  open {\"(\"}
  w {Integer} val = 0..9
  kids {Node 0..}
  close {\")\"}
  nodes {Integer} val = kids.qty + kids.nodes.sum
  weight {Integer} val = w + kids.weight.sum
  ok {Fact} weight >= 0
"

const grid_src =
  "Cell {}
  d {Digit}
Row {}
  cells {Cell 0..}
  end {\";\"}
  n {Integer} val = cells.qty
Grid {}
  rows {Row 0..}
  total {Integer} val = rows.n.sum & cost <= rows.cells.qty + rows.qty
"

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
