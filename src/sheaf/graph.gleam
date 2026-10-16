//// The graph of a program: one node per declaration, one row per field, item
//// or position, and two kinds of wire:
////
////   relations   from a row to a type it names, labelled with how:
////               holds (a field or position of that type), one of (a union
////               item), refines (a refinement's base), and (an intersection),
////               gives (a mapping's output), filters (a path step that names
////               the type) and reaches (a path that starts with the type,
////               the record around this one)
////   data wires  between rows of one record: a computed field, rule or mapping
////               reads the fields its wire comes from
////
//// Types declared in language.sheaf itself (Digit, Text, True, ...) are left
//// out: they are the alphabet every file uses, not part of its theory.
////
//// Because a name resolves only to a type declared above it, type wires never
//// form a cycle, so the layout reads left to right: base types first.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import sheaf/evaluate
import sheaf/model.{type Decl, type Item, TypeItem}
import sheaf/program.{type Program}

pub type Row {
  Row(name: String, label: String, role: String, detail: String)
}

pub type GNode {
  GNode(
    id: String,
    kind: String,
    rows: List(Row),
    external: Bool,
    file: String,
    line: Int,
    doc: String,
    info: List(#(String, String)),
  )
}

pub type Wire {
  /// 'to.row' names the type 'from', in the way 'kind' says.
  TypeWire(from: String, to: String, row: String, kind: String)
  DataWire(node: String, from_row: String, to_row: String)
}

pub type Graph {
  Graph(nodes: List(GNode), edges: List(Wire))
}

pub const node_w = 300.0

pub const head_h = 36.0

pub const row_h = 24.0

pub fn node_h(n: GNode) -> Float {
  head_h +. int.to_float(list.length(n.rows)) *. row_h +. 10.0
}

/// y of a row's pins, relative to the node's top.
pub fn row_y(n: GNode, row: String) -> Float {
  let i = case
    list.index_map(n.rows, fn(r, i) { #(r.name, i) }) |> list.key_find(row)
  {
    Ok(i) -> i
    Error(_) -> 0
  }
  head_h +. int.to_float(i) *. row_h +. row_h /. 2.0 +. 2.0
}

fn type_refs(items: List(Item)) -> List(String) {
  list.filter_map(items, fn(i) {
    case i {
      TypeItem(t) -> Ok(t)
      _ -> Error(Nil)
    }
  })
}

fn preds_text(b: model.Block) -> String {
  case model.block_text(b) {
    "" -> ""
    t -> " " <> t
  }
}

fn rows_of(d: Decl) -> List(Row) {
  case d.kind {
    model.Record ->
      list.map(d.fields, fn(f) {
        let base = case f.mapping {
          Some(m) -> "{" <> model.mapping_text(m) <> "}"
          None -> model.box_text(f.items, f.preds)
        }
        let preds = preds_text(f.preds)
        let detail = case f.mapping {
          Some(m) ->
            list.map(m.cases, fn(c) {
              "| {"
              <> model.item_text(c.output)
              <> "} "
              <> model.block_text(c.preds)
            })
            |> string.join("\n")
          None -> ""
        }
        Row(
          f.name,
          f.name <> " " <> base <> preds,
          model.role_text(f.role),
          detail,
        )
      })
    model.Union ->
      list.map(d.items, fn(i) {
        Row(model.item_text(i), model.item_text(i), "item", "")
      })
    model.Intersection ->
      list.index_map(d.items, fn(i, k) {
        Row(
          model.item_text(i),
          model.item_text(i),
          case k {
            0 -> "reading"
            _ -> "and"
          },
          "",
        )
      })
    model.Refine -> [
      Row(
        "base",
        model.box_text(d.items, d.preds) <> preds_text(d.preds),
        "base",
        "",
      ),
    ]
    model.Layout -> {
      let head =
        Row(
          "base",
          model.box_text(d.items, d.preds) <> preds_text(d.preds),
          "base",
          "",
        )
      [
        head,
        ..list.map(d.positions, fn(p) {
          Row(
            int.to_string(p.number),
            int.to_string(p.number)
              <> ". "
              <> model.box_text(p.items, p.preds)
              <> preds_text(p.preds),
            "position",
            "",
          )
        })
      ]
    }
  }
}

/// Each row with the types it names and how: (row, [(type, kind)]).
fn row_types(d: Decl) -> List(#(String, List(#(String, String)))) {
  let tag = fn(ts: List(String), kind: String) {
    list.map(ts, fn(t) { #(t, kind) })
  }
  let in_preds = fn(b: model.Block) {
    list.flat_map(block_paths(b), fn(p) {
      case p {
        [head, _, ..rest] -> {
          let reach = case is_type(head) {
            True -> [#(head, "reaches")]
            False -> []
          }
          let filters = list.filter(list.drop(p, 1), is_type) |> tag("filters")
          let _ = rest
          list.append(reach, filters)
        }
        _ -> []
      }
    })
  }
  case d.kind {
    model.Record ->
      list.map(d.fields, fn(f) {
        let own = case f.mapping {
          Some(m) -> tag(type_refs(m.outputs), "gives")
          None -> tag(type_refs(f.items), "holds")
        }
        let cases = case f.mapping {
          Some(m) -> list.flat_map(m.cases, fn(c) { in_preds(c.preds) })
          None -> []
        }
        #(f.name, list.flatten([own, in_preds(f.preds), cases]) |> list.unique)
      })
    model.Union ->
      list.map(d.items, fn(i) {
        #(model.item_text(i), tag(type_refs([i]), "one of"))
      })
    model.Intersection ->
      list.map(d.items, fn(i) {
        #(model.item_text(i), tag(type_refs([i]), "and"))
      })
    model.Refine -> [
      #(
        "base",
        list.append(tag(type_refs(d.items), "refines"), in_preds(d.preds)),
      ),
    ]
    model.Layout -> [
      #(
        "base",
        list.append(tag(type_refs(d.items), "refines"), in_preds(d.preds)),
      ),
      ..list.map(d.positions, fn(p) {
        #(int.to_string(p.number), tag(type_refs(p.items), "holds"))
      })
    ]
  }
}

fn is_type(s: String) -> Bool {
  case string.first(s) {
    Ok(c) -> string.uppercase(c) == c && string.lowercase(c) != c
    Error(_) -> False
  }
}

fn value_paths(v: model.Value) -> List(List(String)) {
  case v {
    model.VPath(p) -> [p]
    model.VArith(_, ts) | model.VMulti(ts) -> list.flat_map(ts, value_paths)
    _ -> []
  }
}

fn block_paths(b: model.Block) -> List(List(String)) {
  list.flat_map(b.clauses, fn(c) {
    case c {
      model.Plain(p, _, v) -> [p, ..value_paths(v)]
      model.Setting(_, v) -> value_paths(v)
      model.Flag(_) -> []
    }
  })
}

/// The graph of the declarations in `file`, plus the types from other files they use.
pub fn build(p: Program, file: String) -> Graph {
  let mine = list.filter(program.ordered(p), fn(d) { d.file == file })
  let names = list.map(mine, fn(d) { d.name })
  let alphabet = fn(t: String) {
    case dict.get(p.decls, t) {
      Ok(d) -> d.file == program.prelude_name && file != program.prelude_name
      Error(_) -> True
    }
  }
  let used =
    list.flat_map(mine, fn(d) {
      list.flat_map(row_types(d), fn(rt) { list.map(rt.1, fn(x) { x.0 }) })
    })
    |> list.unique
    |> list.filter(fn(t) {
      !list.contains(names, t) && dict.has_key(p.decls, t) && !alphabet(t)
    })
  let costs = dict.from_list(p.report.costs)
  let checks = list.append(p.report.mappings, p.report.claims)
  let node_of = fn(d: Decl, external: Bool) {
    let info =
      [
        #("declared", d.file <> ":" <> int.to_string(d.line)),
        #("kind", model.kind_text(d.kind)),
      ]
      |> list.append(case dict.get(costs, d.name) {
        Ok(c) -> [#("cost", c)]
        Error(_) -> []
      })
      |> list.append(
        list.filter_map(checks, fn(c) {
          case string.split_once(c.0, ".") {
            Ok(#(t, field)) if t == d.name -> Ok(#(field, c.1))
            _ -> Error(Nil)
          }
        }),
      )
    let rows = case external {
      True -> []
      False -> rows_of(d)
    }
    GNode(
      d.name,
      model.kind_text(d.kind),
      rows,
      external,
      d.file,
      d.line,
      d.doc,
      info,
    )
  }
  let ext_nodes =
    list.filter_map(program.ordered(p), fn(d) {
      case list.contains(used, d.name) {
        True -> Ok(node_of(d, True))
        False -> Error(Nil)
      }
    })
  let own_nodes = list.map(mine, fn(d) { node_of(d, False) })
  let type_wires =
    list.flat_map(mine, fn(d) {
      list.flat_map(row_types(d), fn(rt) {
        list.filter_map(rt.1, fn(tk) {
          let #(t, kind) = tk
          case
            t != d.name && { list.contains(names, t) || list.contains(used, t) }
          {
            True -> Ok(TypeWire(t, d.name, rt.0, kind))
            False -> Error(Nil)
          }
        })
      })
      |> list.unique
    })
  let data_wires =
    list.flat_map(mine, fn(d) {
      case d.kind {
        model.Record ->
          list.flat_map(d.fields, fn(f) {
            let deps = case f.mapping {
              Some(m) -> m.inputs
              None -> evaluate.deps(f.preds)
            }
            list.filter_map(deps, fn(dep) {
              case model.field(d, dep) {
                Some(_) if dep != f.name -> Ok(DataWire(d.name, dep, f.name))
                _ -> Error(Nil)
              }
            })
          })
        _ -> []
      }
    })
  Graph(list.append(ext_nodes, own_nodes), list.append(type_wires, data_wires))
}

// ---------------------------------------------------------------- layout

/// World positions (top-left corners), columns by type depth, left to right.
pub fn layout(g: Graph) -> Dict(String, #(Float, Float)) {
  layout_with(g, dict.new())
}

/// The same, reserving `extra` height below some nodes (for drawn tables).
pub fn layout_with(
  g: Graph,
  extra: Dict(String, Float),
) -> Dict(String, #(Float, Float)) {
  let preds =
    list.fold(g.edges, dict.new(), fn(acc, e) {
      case e {
        // a type is drawn after what it is built from; reaching up does not count
        TypeWire(from, to, _, kind) if kind != "reaches" ->
          dict.upsert(acc, to, fn(x) {
            case x {
              Some(xs) -> [from, ..xs]
              None -> [from]
            }
          })
        _ -> acc
      }
    })
  let depth =
    list.fold(g.nodes, dict.new(), fn(acc, n) {
      let parents = result_or(dict.get(preds, n.id), [])
      let d =
        list.fold(parents, 0, fn(m, p) {
          int.max(m, result_or(dict.get(acc, p), 0) + 1)
        })
      dict.insert(acc, n.id, d)
    })
  let cols =
    list.fold(g.nodes, dict.new(), fn(acc, n) {
      let d = result_or(dict.get(depth, n.id), 0)
      dict.upsert(acc, d, fn(x) {
        case x {
          Some(xs) -> list.append(xs, [n])
          None -> [n]
        }
      })
    })
  let ncols = dict.size(cols)
  int.range(0, ncols, [], fn(acc, i) { [i, ..acc] })
  |> list.reverse
  |> list.fold(dict.new(), fn(pos, c) {
    let col = result_or(dict.get(cols, c), [])
    // order a column by the mean height of its parents, to keep wires short
    let col =
      list.sort(col, fn(a, b) {
        float.compare(parent_mean(a, preds, pos), parent_mean(b, preds, pos))
      })
    let x = int.to_float(c) *. { node_w +. 120.0 }
    let #(pos, _) =
      list.fold(col, #(pos, 0.0), fn(acc, n) {
        let #(pos, y) = acc
        let y = float.max(y, parent_mean(n, preds, pos) -. 20.0)
        #(
          dict.insert(pos, n.id, #(x, y)),
          y +. node_h(n) +. result_or(dict.get(extra, n.id), 0.0) +. 36.0,
        )
      })
    pos
  })
}

fn parent_mean(n: GNode, preds, pos: Dict(String, #(Float, Float))) -> Float {
  let ys =
    result_or(dict.get(preds, n.id), [])
    |> list.filter_map(fn(p) {
      case dict.get(pos, p) {
        Ok(#(_, y)) -> Ok(y)
        Error(_) -> Error(Nil)
      }
    })
  case ys {
    [] -> 0.0
    _ -> float.sum(ys) /. int.to_float(list.length(ys))
  }
}

fn result_or(r: Result(a, b), d: a) -> a {
  case r {
    Ok(x) -> x
    Error(_) -> d
  }
}

pub fn bounds(
  g: Graph,
  pos: Dict(String, #(Float, Float)),
) -> #(Float, Float, Float, Float) {
  list.fold(g.nodes, #(0.0, 0.0, 0.0, 0.0), fn(acc, n) {
    let #(x, y) = result_or(dict.get(pos, n.id), #(0.0, 0.0))
    #(
      float.min(acc.0, x),
      float.min(acc.1, y),
      float.max(acc.2, x +. node_w),
      float.max(acc.3, y +. node_h(n)),
    )
  })
}

// ---------------------------------------------------------------- static SVG

fn esc(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
}

fn f(x: Float) -> String {
  float.to_string(float.to_precision(x, 1))
}

pub fn role_fill(role: String) -> String {
  case role {
    "stored" | "item" | "base" | "position" -> "var(--stored)"
    "computed" -> "var(--computed)"
    "mapping" -> "var(--mapping)"
    _ -> "var(--rule)"
  }
}

fn truncate(s: String, n: Int) -> String {
  case string.length(s) > n {
    True -> string.slice(s, 0, n - 1) <> "…"
    False -> s
  }
}

pub fn to_svg(
  g: Graph,
  pos: Dict(String, #(Float, Float)),
  title: String,
) -> String {
  let #(x0, y0, x1, y1) = bounds(g, pos)
  let pad = 40.0
  let w = x1 -. x0 +. 2.0 *. pad
  let h = y1 -. y0 +. 2.0 *. pad +. 30.0
  let at = fn(id) { result_or(dict.get(pos, id), #(0.0, 0.0)) }
  let node_by = fn(id) { list.find(g.nodes, fn(n) { n.id == id }) }
  let wires =
    list.filter_map(g.edges, fn(e) {
      case e {
        TypeWire(from, to, row, _) ->
          case node_by(to) {
            Ok(tn) -> {
              let #(ax, ay) = at(from)
              let #(bx, by) = at(to)
              let sx = ax +. node_w
              let sy = ay +. head_h /. 2.0
              let ey = by +. row_y(tn, row)
              let dx = float.max(60.0, { bx -. sx } /. 2.0)
              Ok(
                "<path class=\"tw\" d=\"M"
                <> f(sx)
                <> ","
                <> f(sy)
                <> " C"
                <> f(sx +. dx)
                <> ","
                <> f(sy)
                <> " "
                <> f(bx -. dx)
                <> ","
                <> f(ey)
                <> " "
                <> f(bx -. 4.0)
                <> ","
                <> f(ey)
                <> "\" marker-end=\"url(#a)\"/>",
              )
            }
            Error(_) -> Error(Nil)
          }
        DataWire(node, from_row, to_row) ->
          case node_by(node) {
            Ok(n) -> {
              let #(x, y) = at(node)
              let ya = y +. row_y(n, from_row)
              let yb = y +. row_y(n, to_row)
              let bulge = 26.0 +. float.absolute_value(yb -. ya) /. 6.0
              Ok(
                "<path class=\"dw\" d=\"M"
                <> f(x)
                <> ","
                <> f(ya)
                <> " C"
                <> f(x -. bulge)
                <> ","
                <> f(ya)
                <> " "
                <> f(x -. bulge)
                <> ","
                <> f(yb)
                <> " "
                <> f(x -. 4.0)
                <> ","
                <> f(yb)
                <> "\" marker-end=\"url(#d)\"/>",
              )
            }
            Error(_) -> Error(Nil)
          }
      }
    })
    |> string.join("\n")
  let boxes =
    list.map(g.nodes, fn(n) {
      let #(x, y) = at(n.id)
      let hh = node_h(n)
      let cls = case n.external {
        True -> "node ext"
        False -> "node"
      }
      let rows =
        list.index_map(n.rows, fn(r, i) {
          let ry = y +. head_h +. int.to_float(i) *. row_h
          "<rect x=\""
          <> f(x +. 6.0)
          <> "\" y=\""
          <> f(ry +. 2.0)
          <> "\" width=\"5\" height=\"20\" rx=\"2\" style=\"fill:"
          <> role_fill(r.role)
          <> "\"/><text class=\"row\" x=\""
          <> f(x +. 18.0)
          <> "\" y=\""
          <> f(ry +. 16.5)
          <> "\">"
          <> esc(truncate(r.label, 40))
          <> "</text><circle class=\"pin\" cx=\""
          <> f(x)
          <> "\" cy=\""
          <> f(ry +. row_h /. 2.0 +. 2.0)
          <> "\" r=\"3.5\"/>"
        })
        |> string.concat
      "<g class=\""
      <> cls
      <> "\"><rect class=\"body\" x=\""
      <> f(x)
      <> "\" y=\""
      <> f(y)
      <> "\" width=\""
      <> f(node_w)
      <> "\" height=\""
      <> f(hh)
      <> "\" rx=\"9\"/><text class=\"title\" x=\""
      <> f(x +. 14.0)
      <> "\" y=\""
      <> f(y +. 23.0)
      <> "\">"
      <> esc(n.id)
      <> "</text><text class=\"kind\" x=\""
      <> f(x +. node_w -. 22.0)
      <> "\" y=\""
      <> f(y +. 23.0)
      <> "\">"
      <> n.kind
      <> "</text><circle class=\"pin out\" cx=\""
      <> f(x +. node_w)
      <> "\" cy=\""
      <> f(y +. head_h /. 2.0)
      <> "\" r=\"4.5\"/>"
      <> rows
      <> "</g>"
    })
    |> string.join("\n")
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\""
  <> f(x0 -. pad)
  <> " "
  <> f(y0 -. pad -. 30.0)
  <> " "
  <> f(w)
  <> " "
  <> f(h)
  <> "\" width=\""
  <> f(w)
  <> "\" height=\""
  <> f(h)
  <> "\">\n<style>"
  <> svg_style
  <> "</style>\n<defs><marker id=\"a\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto\"><path d=\"M0,0L10,5L0,10z\" class=\"ah\"/></marker><marker id=\"d\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto\"><path d=\"M0,0L10,5L0,10z\" class=\"dh\"/></marker></defs>\n<rect x=\""
  <> f(x0 -. pad)
  <> "\" y=\""
  <> f(y0 -. pad -. 30.0)
  <> "\" width=\""
  <> f(w)
  <> "\" height=\""
  <> f(h)
  <> "\" class=\"bg\"/>\n<text class=\"heading\" x=\""
  <> f(x0)
  <> "\" y=\""
  <> f(y0 -. 26.0)
  <> "\">"
  <> esc(title)
  <> " — data flow</text>\n"
  <> wires
  <> "\n"
  <> boxes
  <> "\n</svg>\n"
}

const svg_style =
  ":root{--bg:#f6f5f1;--panel:#ffffff;--ink:#1d2127;--muted:#68717d;--line:#a3abb5;--accent:#2f6db3;--stored:#7aa7d8;--computed:#6fb37d;--mapping:#a58bd0;--rule:#d9a441;--stroke:#d5d9de}
@media (prefers-color-scheme:dark){:root{--bg:#14171b;--panel:#1d2127;--ink:#e7e9ec;--muted:#98a1ab;--line:#5b6470;--accent:#7fb0ec;--stroke:#343a42}}
.bg{fill:var(--bg)}.body{fill:var(--panel);stroke:var(--stroke)}.ext .body{fill:var(--bg);stroke-dasharray:4 3}
text{font:12px ui-monospace,Menlo,Consolas,monospace;fill:var(--ink)}.title{font:600 13.5px system-ui,sans-serif}
.kind{font:11px system-ui,sans-serif;fill:var(--muted);text-anchor:end}.heading{font:600 16px system-ui,sans-serif}
.pin{fill:var(--panel);stroke:var(--line);stroke-width:1.4}.out{fill:var(--accent);stroke:none}
.tw{fill:none;stroke:var(--line);stroke-width:1.4}.dw{fill:none;stroke:var(--accent);stroke-width:1.4;opacity:.8}
.ah{fill:var(--line)}.dh{fill:var(--accent)}"
