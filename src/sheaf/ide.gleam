//// The workspace: an infinite, zoomable canvas where code, the data-flow graph
//// and live output sit side by side.
////
////   code panels   the .sheaf source, editable; every pause re-parses and re-checks
////   node graph    one node per type, one row (with pins) per field; type wires
////                 run from a type to the rows that use it, data wires between
////                 the fields a computed field, rule or mapping reads
////   probes        a text checked against a type; its values appear on the node's
////                 rows, and its wire turns red when a rule fails
////   tables        every mapping drawn as a grid of cells coloured by the case
////                 that covers them: coverage and disjointness made visible
////
//// Gleam owns all state and decides what to draw; ide_ffi.mjs runs the canvas.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import sheaf/check.{type Grid, type Report}
import sheaf/decimal
import sheaf/evaluate.{type Val, VInvalid, VNumber, VRecord, VSeqv, VText}
import sheaf/graph.{type GNode, type Graph, DataWire, TypeWire}
import sheaf/model
import sheaf/program.{type Outcome, type Program}

// ---------------------------------------------------------------- host

pub type Ctx

pub type App {
  App(
    init: fn(Float, Float, Bool, Bool, List(#(String, String))) -> Model,
    frame: fn(Model, Float) -> Model,
    down: fn(Model, Float, Float, Int, String, Bool) -> Model,
    move: fn(Model, Float, Float) -> Model,
    up: fn(Model, Float, Float) -> Model,
    wheel: fn(Model, Float, Float, Float, Float, Bool) -> Model,
    key: fn(Model, String) -> Model,
    edit: fn(Model, String, String) -> Model,
    command: fn(Model, String) -> Model,
    resize: fn(Model, Float, Float) -> Model,
    view: fn(Model, Ctx) -> Nil,
  )
}

@external(javascript, "./ide_ffi.mjs", "start")
fn ffi_start(app: App, files: Files) -> Nil

pub type Files

@external(javascript, "./ide_ffi.mjs", "clear")
fn clear(c: Ctx, color: String) -> Nil

@external(javascript, "./ide_ffi.mjs", "world")
fn world(c: Ctx, x: Float, y: Float, z: Float) -> Nil

@external(javascript, "./ide_ffi.mjs", "screen")
fn screen(c: Ctx) -> Nil

@external(javascript, "./ide_ffi.mjs", "rect")
fn rect(
  c: Ctx,
  x: Float,
  y: Float,
  w: Float,
  h: Float,
  r: Float,
  fill: String,
  stroke: String,
  lw: Float,
  dash: Float,
) -> Nil

@external(javascript, "./ide_ffi.mjs", "curve")
fn curve(
  c: Ctx,
  x1: Float,
  y1: Float,
  cx1: Float,
  cy1: Float,
  cx2: Float,
  cy2: Float,
  x2: Float,
  y2: Float,
  color: String,
  lw: Float,
  dash: Float,
  offset: Float,
) -> Nil

@external(javascript, "./ide_ffi.mjs", "circle")
fn circle(
  c: Ctx,
  x: Float,
  y: Float,
  r: Float,
  fill: String,
  stroke: String,
  lw: Float,
) -> Nil

@external(javascript, "./ide_ffi.mjs", "arrow")
fn arrow(
  c: Ctx,
  x: Float,
  y: Float,
  angle: Float,
  size: Float,
  color: String,
) -> Nil

@external(javascript, "./ide_ffi.mjs", "text")
fn text(
  c: Ctx,
  x: Float,
  y: Float,
  s: String,
  font: String,
  color: String,
  align: String,
  max_w: Float,
) -> Nil

@external(javascript, "./ide_ffi.mjs", "dots")
fn dots(
  c: Ctx,
  x0: Float,
  y0: Float,
  x1: Float,
  y1: Float,
  step: Float,
  r: Float,
  color: String,
) -> Nil

@external(javascript, "./ide_ffi.mjs", "panel")
fn panel(
  c: Ctx,
  id: String,
  kind: String,
  x: Float,
  y: Float,
  w: Float,
  h: Float,
  title: String,
  body: String,
  status: String,
  state: String,
  opacity: Float,
  buttons: List(#(String, String)),
  scroll_line: Int,
  readonly: Bool,
  editing: Bool,
  links: List(String),
  notes: List(#(Int, String, String)),
) -> Nil

@external(javascript, "./ide_ffi.mjs", "set_results")
fn set_results(
  c: Ctx,
  query: String,
  items: List(#(String, String, String, String, String)),
) -> Nil

@external(javascript, "./ide_ffi.mjs", "card")
fn card(
  c: Ctx,
  title: String,
  body: String,
  state: String,
  x: Float,
  y: Float,
  links: List(String),
) -> Nil

@external(javascript, "./ide_ffi.mjs", "info")
fn info(c: Ctx, title: String, lines: List(#(String, String))) -> Nil

@external(javascript, "./ide_ffi.mjs", "status")
fn status(c: Ctx, s: String) -> Nil

@external(javascript, "./ide_ffi.mjs", "set_files")
fn set_files(c: Ctx, items: List(#(String, String)), current: String) -> Nil

@external(javascript, "./ide_ffi.mjs", "set_theme")
fn set_theme(c: Ctx, dark: Bool) -> Nil

@external(javascript, "./ide_ffi.mjs", "download")
fn download(name: String, content: String) -> Nil

@external(javascript, "./ide_ffi.mjs", "set_mode")
fn set_mode(
  c: Ctx,
  view: String,
  autocompile: Bool,
  levels: Int,
  focused: Bool,
  probes_on: Bool,
) -> Nil

@external(javascript, "./ide_ffi.mjs", "sin")
fn sin(x: Float) -> Float

@external(javascript, "./ide_ffi.mjs", "cos")
fn cos(x: Float) -> Float

@external(javascript, "./ide_ffi.mjs", "cursor")
fn cursor(c: Ctx, kind: String) -> Nil

@external(javascript, "./ide_ffi.mjs", "exp")
fn exp(x: Float) -> Float

@external(javascript, "./ide_ffi.mjs", "atan2")
fn atan2(y: Float, x: Float) -> Float

@external(javascript, "./ide_ffi.mjs", "now")
fn now() -> Float

/// Files made with New in an earlier visit, as (path, text), oldest first;
/// none when the browser keeps no storage.
@external(javascript, "./ide_ffi.mjs", "load_created")
fn load_created() -> List(#(String, String))

@external(javascript, "./ide_ffi.mjs", "save_created")
fn save_created(files: List(#(String, String))) -> Nil

/// The browser entry point: window.SHEAF_FILES holds language.sheaf, the
/// standard library and the examples as an in-memory folder.
pub fn main() -> Nil {
  ffi_start(app(), files_global())
}

@external(javascript, "./ide_ffi.mjs", "files")
fn files_global() -> Files

pub fn app() -> App {
  App(init, frame, down, move, up, wheel, key, edit, command, resize, view)
}

// ---------------------------------------------------------------- model

pub type Cam {
  Cam(x: Float, y: Float, z: Float)
}

pub type Drag {
  NoDrag
  Pan(sx: Float, sy: Float, cx: Float, cy: Float, moved: Bool)
  /// Pressing a type: a drag moves it, a click (no movement) centres it.
  MoveNode(id: String, dx: Float, dy: Float, sx: Float, sy: Float, moved: Bool)
  MovePanel(id: String, dx: Float, dy: Float)
}

pub type Panel {
  Panel(id: String, path: String, x: Float, y: Float, w: Float, h: Float)
}

pub type Probe {
  Probe(
    id: String,
    type_name: String,
    text: String,
    x: Float,
    y: Float,
    outcome: Option(Outcome),
  )
}

/// What the last compile of a file found, and the texts it read.
pub type FileState {
  FileState(text: String, errors: Int, proved: Bool, deps: Dict(String, String))
}

/// A file's colour: core (blue), compiled (green), proved (purple), changed
/// since its compile (yellow), affected by a file it uses (orange), refused
/// (red), or outside this file's scope (grey, dashed).
pub type Status {
  Core
  Compiled
  Proved
  Changed
  Affected(by: String)
  Errors(n: Int)
  Outside
}

/// A place to come back to: which file was the working file, and which line
/// of which file was looked at.
pub type Loc {
  Loc(main: String, path: String, line: Int, label: String)
}

/// A file shown because the hovered line names one of its types.
pub type Peek {
  Peek(path: String, line: Int, outside: Bool)
}

pub type Model {
  Model(
    files: Dict(String, String),
    base: Result(Program, String),
    boot_ms: Float,
    main: String,
    program: Option(Program),
    report: Report,
    error: String,
    check_ms: Float,
    graph: Graph,
    pos: Dict(String, #(Float, Float)),
    moved: Dict(String, #(Float, Float)),
    panels: List(Panel),
    probes: List(Probe),
    grids: Dict(String, Grid),
    cam: Cam,
    goal: Option(Cam),
    drag: Drag,
    selected: Option(String),
    hover: Option(#(String, String)),
    mouse: #(Float, Float),
    w: Float,
    h: Float,
    dark: Bool,
    reduced: Bool,
    t: Float,
    next_id: Int,
    /// The type at the centre, with the types around it on rings.
    focus: Option(String),
    /// How many rings: 1 shows the types one relation away, 2 adds theirs.
    levels: Int,
    /// Where each node is heading; 'pos' eases toward it every frame.
    target: Dict(String, #(Float, Float)),
    /// The ring of each shown type while focused (0 is the centre).
    rings: Dict(String, Int),
    /// Centre and radii of the rings, drawn as faint guides.
    orbit: #(Float, Float, List(Float)),
    /// The type and row under the pointer in the code panel, if any.
    code_hover: Option(#(String, String)),
    /// "code": the working file in the middle; "types": the type graph.
    view: String,
    /// Compile on every pause in typing, or only with the Compile button.
    autocompile: Bool,
    states: Dict(String, FileState),
    /// Files faded in for the hovered line, and when the line was left.
    peeks: List(Peek),
    peek_t: Float,
    /// Files clicked to stay; the panel under the pointer.
    pinned: List(String),
    over: String,
    /// Files outside the scope that a hovered line has named.
    strangers: List(String),
    /// The hovered line of the working file and its height in the panel.
    code_line: Int,
    code_y: Float,
    /// Panels being edited; every other file is explored: read-only, with
    /// its type names as links.
    editing: List(String),
    /// The type name under the pointer, whose chain the chip shows.
    hover_type: String,
    /// A line to scroll to and highlight, per file, after following a link.
    marks: Dict(String, Int),
    /// Files opened by following a link (language.sheaf, say).
    opened: List(String),
    /// Files typed in whose text has not reached the model yet.
    dirty: List(String),
    /// What each file was when last compiled on purpose: its text and the
    /// texts of the files it read. Green means the text is still this.
    committed: Dict(String, #(String, Dict(String, String))),
    /// Places to go back and forward to, most recent first.
    back: List(Loc),
    fwd: List(Loc),
    /// The last jump: where it came from and where it landed (for markers).
    came: Option(#(Loc, Loc)),
    /// Where the hovered type name is on screen, for its preview card.
    hover_at: #(Float, Float),
    /// The line clicked in each file, highlighted blue.
    picked: Dict(String, Int),
    /// Files locked against editing, and core files unlocked by hand.
    locked: List(String),
    unlocked: List(String),
    /// The centre of the working file on the canvas, and where each file
    /// sat when it was the working file, so going back glides home.
    origin: #(Float, Float),
    homes: Dict(String, #(Float, Float)),
    /// A timed camera glide (from, to, start), and what to do on arrival.
    glide: Option(#(Cam, Cam, Float, Float)),
    pending: Option(fn(Model) -> Model),
    /// The canvas search and what it found.
    search_q: String,
    hits: List(Hit),
    /// Whether probes are shown (off until asked for).
    probes_on: Bool,
    /// Files made with New, listed in the file menu after the examples, and
    /// kept in browser storage so a reload brings them back.
    created: List(String),
    /// Files whose pane was closed: kept off the canvas until opened again.
    closed: List(String),
  )
}

/// A search result: a type, a field, or a line of text, and where it is.
pub type Hit {
  Hit(kind: String, label: String, path: String, line: Int, snippet: String)
}

/// A pane fits 100 characters, the longest line the grammar allows, so it
/// never scrolls sideways (the page sets the font size to match).
const code_w = 820.0

const probe_w = 380.0

/// Examples: the file, then probes (type, text) checked live against it.
fn presets() -> List(#(String, String, List(#(String, String)))) {
  [
    #(
      "/examples/orders/orders.sheaf",
      "Orders: folds, a mapping, a filtered list",
      [
        #("Order", "order 1042\nABC-0001 x3 @ 19.99\nXYZ-0420 x10 @ 120.00\n"),
        #("Line", "QRS-0007 x2 @ 400.00\n"),
      ],
    ),
    #(
      "/examples/proofs/proofs.sheaf",
      "Proofs: claims, induction, a two-input table",
      [
        #("Window", "3..25"),
        #("Chain", "+3+4+5"),
        #("Parcel", "7 A"),
      ],
    ),
    #("/priv/stdlib/dates.sheaf", "Dates: leap years as chained tables", [
      #("Date", "2024-02-29"),
    ]),
    #("/priv/stdlib/bits.sheaf", "Bits and bytes: proved bounds", [
      #("Byte", "01000001"),
    ]),
    #("/priv/stdlib/logic.sheaf", "Logic gates as tables", [
      #("Implies_Gate", "TRUEFALSE"),
    ]),
    #(
      "/examples/shop/orders/orders.sheaf",
      "Shop: a project in folders, no imports",
      [
        #("Order", "2026-10-15\nABC123 19.99\nXYZ042 5.00\n"),
      ],
    ),
    #("/examples/book/book.sheaf", "Book: an order belongs to a customer", [
      #(
        "Book",
        "C001 Ada Lovelace\nC002 Alan Turing\n---\n1041 C001\n1042 C009\n",
      ),
    ]),
    #(
      "/examples/shop/orders/peek.sheaf",
      "Shop: reaching for a private type (outside scope)",
      [],
    ),
    #(
      "/examples/meeting/meeting.sheaf",
      "The standard library needs no import",
      [
        #("Meeting", "2024-02-29 room_4"),
      ],
    ),
    #(
      "/examples/mistakes/mistakes.sheaf",
      "Mistakes: what the checker reports",
      [],
    ),
  ]
}

fn init(
  w: Float,
  h: Float,
  dark: Bool,
  reduced: Bool,
  files: List(#(String, String)),
) -> Model {
  let #(files, created) = restore_created(dict.from_list(files), load_created())
  let t0 = now()
  let base = case dict.get(files, "/priv/language.sheaf") {
    Ok(text) ->
      case
        program.new(text, program.memory_fs(dict.new(), "/", "/", ""), True)
      {
        Ok(p) -> Ok(p)
        Error(e) -> Error(model.error_text(e))
      }
    Error(_) -> Error("language.sheaf is missing")
  }
  let boot = now() -. t0
  let m =
    Model(
      files,
      base,
      boot,
      "",
      None,
      check.empty_report(),
      "",
      0.0,
      graph.Graph([], []),
      dict.new(),
      dict.new(),
      [],
      [],
      dict.new(),
      Cam(-640.0, -120.0, 0.8),
      None,
      NoDrag,
      None,
      None,
      #(0.0, 0.0),
      w,
      h,
      dark,
      reduced,
      0.0,
      0,
      None,
      1,
      dict.new(),
      dict.new(),
      #(0.0, 0.0, []),
      None,
      "code",
      True,
      dict.new(),
      [],
      0.0,
      [],
      "",
      [],
      0,
      0.0,
      [],
      "",
      dict.new(),
      [],
      [],
      dict.new(),
      [],
      [],
      None,
      #(0.0, 0.0),
      dict.new(),
      [],
      [],
      #(0.0, 0.0),
      dict.new(),
      None,
      None,
      "",
      [],
      False,
      created,
      [],
    )
  open(m, "/examples/orders/orders.sheaf") |> fit(False)
}

/// Bring back the files made with New in an earlier visit. They join the
/// file menu marked "(new)"; the page still opens on the orders example. A
/// stored path the page now ships itself keeps its text under a numbered name.
fn restore_created(
  files: Dict(String, String),
  stored: List(#(String, String)),
) -> #(Dict(String, String), List(String)) {
  let #(files, created) =
    list.fold(stored, #(files, []), fn(acc, f) {
      let #(files, created) = acc
      let #(path, text) = f
      case
        string.starts_with(path, "/")
        && string.ends_with(path, ".sheaf")
        && !string.contains(path, "/../")
      {
        False -> acc
        True -> {
          let path = free_path(files, string.drop_end(path, 6), 1)
          #(dict.insert(files, path, text), [path, ..created])
        }
      }
    })
  #(files, list.reverse(created))
}

/// Keep the files made with New, text and all, so a reload brings them back.
fn save_new_files(m: Model) -> Model {
  save_created(list.map(m.created, fn(p) { #(p, file_text(m, p)) }))
  m
}

/// After a file's text changes: if it was made with New, save it.
fn keep_if_new(m: Model, path: String) -> Model {
  case list.contains(m.created, path) {
    True -> save_new_files(m)
    False -> m
  }
}

fn open(m: Model, path: String) -> Model {
  let preset = list.find(presets(), fn(p) { p.0 == path })
  let probes = case preset {
    Ok(#(_, _, ps)) ->
      list.index_map(ps, fn(p, i) {
        Probe("probe" <> int.to_string(i), p.0, p.1, 0.0, 0.0, None)
      })
    Error(_) -> []
  }
  let m =
    Model(
      ..m,
      main: path,
      panels: [Panel("code", path, 0.0, 0.0, code_w, 400.0)],
      probes: probes,
      moved: dict.new(),
      selected: None,
      next_id: list.length(probes),
      focus: None,
      rings: dict.new(),
      pos: dict.new(),
      target: dict.new(),
      code_hover: None,
      hover: None,
      peeks: [],
      pinned: [],
      strangers: [],
      code_line: 0,
      program: None,
      editing: [],
      hover_type: "",
      marks: dict.new(),
      opened: [],
      back: [],
      fwd: [],
      came: None,
      picked: dict.new(),
      origin: #(0.0, 0.0),
      homes: dict.new(),
    )
  let m = rebuild(m) |> place
  // what opens has been compiled: every clean file starts green
  dict.fold(m.states, m, fn(m, path, st) {
    case st.errors {
      0 -> commit(m, path)
      _ -> m
    }
  })
}

/// Choose another example: it becomes the working file, and the old one
/// moves aside as a pane (Back returns to it). Its probes come along hidden.
fn switch_to(m: Model, path: String) -> Model {
  case path == m.main, dict.has_key(m.files, path) {
    True, _ | _, False -> m
    False, True -> {
      let old = m.main
      let from = here(m)
      let preset = list.find(presets(), fn(p) { p.0 == path })
      let fresh = case preset {
        Ok(#(_, _, ps)) ->
          list.index_map(ps, fn(p, i) {
            Probe(
              "probe" <> int.to_string(m.next_id + i),
              p.0,
              p.1,
              0.0,
              0.0,
              None,
            )
          })
        Error(_) -> []
      }
      let m =
        Model(
          ..m,
          probes: list.append(m.probes, fresh),
          next_id: m.next_id + list.length(fresh),
        )
      // the new file takes a place of its own beside the old one
      let m = case dict.has_key(m.homes, path) {
        True -> m
        False ->
          Model(
            ..m,
            homes: dict.insert(m.homes, path, #(
              m.origin.0 +. code_w +. 2.0 *. file_w +. 400.0,
              m.origin.1,
            )),
          )
      }
      let m = navigate(m, path)
      // the old file stays on the canvas, beside the new one
      let m =
        Model(
          ..m,
          pinned: [old, ..list.filter(m.pinned, fn(q) { q != old })],
          opened: [old, ..list.filter(m.opened, fn(q) { q != old })],
          back: [from, ..m.back],
          fwd: [],
          came: None,
          probes: list.map(m.probes, fn(pr) { run_probe(m, pr) }),
        )
        |> place
      // compile what opens, as at the start: clean files start green
      dict.fold(m.states, m, fn(m, p, st) {
        case st.errors, dict.has_key(m.committed, p) {
          0, False -> commit(m, p)
          _, _ -> m
        }
      })
      |> glide_to_main
    }
  }
}

/// Make a new file and open it for editing as the working file. A bare
/// name goes in the working file's folder, so it sees that folder's types;
/// "folder/name" puts it elsewhere. A name already taken gets a number.
fn new_file(m: Model, name: String) -> Model {
  let name =
    string.trim(name)
    |> string.replace("\\", "/")
    |> string.replace(" ", "_")
  let name = case string.ends_with(name, ".sheaf") {
    True -> string.drop_end(name, 6)
    False -> name
  }
  let parts =
    string.split(name, "/") |> list.filter(fn(s) { s != "" && s != "." && s != ".." })
  case list.reverse(parts) {
    [] -> m
    [base, ..dirs] -> {
      let folder = case dirs {
        [] -> program.dirname(m.main)
        _ -> "/" <> string.join(list.reverse(dirs), "/")
      }
      let stem = folder <> "/" <> base
      let path = free_path(m.files, stem, 1)
      let title = string.replace(base, "-", "_")
      let text =
        "# "
        <> base
        <> ".sheaf: a new file. Types from the other files in "
        <> program.display_path(folder)
        <> "/\n# and the core library can be used here.\n"
        <> string.capitalise(title)
        <> " {}\n  text {Line_Text}\n  nl {Newline}\n"
      let m =
        Model(
          ..m,
          files: dict.insert(m.files, path, text),
          created: list.append(m.created, [path]),
        )
        |> save_new_files
      let m = switch_to(m, path)
      Model(..m, editing: ["code", ..list.filter(m.editing, fn(e) { e != "code" })])
    }
  }
}

fn free_path(files: Dict(String, String), stem: String, n: Int) -> String {
  let path = case n {
    1 -> stem <> ".sheaf"
    _ -> stem <> "_" <> int.to_string(n) <> ".sheaf"
  }
  case dict.has_key(files, path) {
    True -> free_path(files, stem, n + 1)
    False -> path
  }
}

/// A compile on purpose: the file's current text becomes its compiled text.
fn commit(m: Model, path: String) -> Model {
  case dict.get(m.states, path) {
    Ok(st) if st.errors == 0 ->
      Model(
        ..m,
        committed: dict.insert(m.committed, path, #(file_text(m, path), st.deps)),
      )
    _ -> m
  }
}

/// Make another file the working file, keeping the probes and the history.
fn navigate(m: Model, path: String) -> Model {
  case path == m.main {
    True -> m
    False -> {
      // where the new working file goes: where it was the centre before,
      // or where its pane sits now beside the old one
      let here_pane =
        list.find(m.panels, fn(pn) { pn.path == path && pn.id != "code" })
      // where the file is now wins (the canvas just glided there); a file
      // with no pane goes back to where it last was the working file
      let origin = case here_pane, dict.get(m.homes, path) {
        Ok(pn), _ -> #(pn.x +. pn.w /. 2.0, pn.y +. pn.h /. 2.0)
        _, Ok(o) -> o
        _, _ -> m.origin
      }
      let homes = dict.insert(m.homes, m.main, m.origin)
      let m =
        Model(
          ..m,
          origin: origin,
          homes: homes,
          closed: list.filter(m.closed, fn(q) { q != path }),
        )
      let moved =
        dict.filter(m.moved, fn(k, _) { string.starts_with(k, "panel:probe") })
      Model(
        ..m,
        main: path,
        panels: [Panel("code", path, 0.0, 0.0, code_w, 400.0)],
        moved: moved,
        selected: None,
        focus: None,
        rings: dict.new(),
        pos: dict.new(),
        target: dict.new(),
        code_hover: None,
        hover: None,
        peeks: [],
        pinned: [],
        strangers: [],
        opened: [],
        code_line: 0,
        editing: [],
        hover_type: "",
      )
      |> rebuild
      |> place
      |> glide_to_main
    }
  }
}

/// A camera that puts a pane in the middle of the screen at today's zoom.
fn centre_on(m: Model, pn: Panel) -> Cam {
  let z = m.cam.z
  Cam(
    pn.x +. pn.w /. 2.0 -. m.w /. 2.0 /. z,
    pn.y +. pn.h /. 2.0 -. { m.h +. 50.0 } /. 2.0 /. z,
    z,
  )
}

/// Move the camera smoothly so the working file is in the middle, at the
/// zoom it has now.
fn glide_to_main(m: Model) -> Model {
  case list.find(m.panels, fn(pn) { pn.id == "code" }) {
    Error(_) -> m
    Ok(pn) -> {
      glide_to(m, centre_on(m, pn))
    }
  }
}

/// Show a place: make its working file the centre, then bring its line up.
fn show_loc(m: Model, l: Loc) -> Model {
  let m = show_loc_inner(m, l)
  let id = case l.path == m.main {
    True -> "code"
    False -> "f:" <> l.path
  }
  case list.find(m.panels, fn(pn) { pn.id == id }) {
    Ok(pn) -> glide_to(m, centre_on(m, pn))
    Error(_) -> m
  }
}

fn show_loc_inner(m: Model, l: Loc) -> Model {
  let m = navigate(m, l.main)
  let m = Model(..m, closed: list.filter(m.closed, fn(q) { q != l.path }))
  case l.path == m.main {
    True -> Model(..m, marks: dict.insert(m.marks, l.path, l.line))
    False -> {
      let known = list.contains(candidates(m), l.path)
      let m =
        Model(
          ..m,
          marks: dict.insert(m.marks, l.path, l.line),
          pinned: [l.path, ..list.filter(m.pinned, fn(q) { q != l.path })],
          opened: case known {
            True -> m.opened
            False -> [l.path, ..m.opened]
          },
        )
      case known {
        True -> m
        False -> place(m)
      }
    }
  }
}

/// Close a pane and go back to the most recent place outside it (or to the
/// working file), gliding there; history up to that place is used up.
fn close_pane(m: Model, path: String) -> Model {
  case path == m.main {
    True -> close_main(m)
    False -> close_side(Model(..m, closed: [path, ..list.filter(m.closed, fn(q) { q != path })]), path)
  }
}

/// Close the working file: the most recent place in another file becomes
/// the centre (else a file still on the canvas, else the first example).
fn close_main(m: Model) -> Model {
  let path = m.main
  let others = fn(q: String) { q != path && dict.has_key(m.files, q) }
  let #(_, rest) = list.split_while(m.back, fn(l) { l.main == path })
  let target = case rest {
    [l, ..older] -> Ok(#(l, older))
    [] ->
      case
        list.find(list.flatten([m.pinned, m.opened, candidates(m)]), fn(q) {
          others(q) && !is_prelude(q)
        })
      {
        Ok(q) -> Ok(#(Loc(q, q, result_or(dict.get(m.marks, q), 1), line_label(m, q, 1)), []))
        Error(_) ->
          case list.find(presets(), fn(pr) { others(pr.0) }) {
            Ok(pr) -> Ok(#(Loc(pr.0, pr.0, 1, ""), []))
            Error(_) -> Error(Nil)
          }
      }
  }
  case target {
    Error(_) -> m
    Ok(#(l, older)) -> {
      let l = case is_prelude(l.main) {
        True -> Loc(..l, main: l.path)
        False -> l
      }
      let m =
        Model(
          ..m,
          closed: [path, ..list.filter(m.closed, fn(q) { q != path })],
          pinned: list.filter(m.pinned, fn(q) { q != path }),
          opened: list.filter(m.opened, fn(q) { q != path }),
          came: None,
        )
      let m = show_loc(m, l)
      Model(
        ..m,
        back: older,
        fwd: list.filter(m.fwd, fn(f) { f.main != path }),
        came: None,
        pinned: list.filter(m.pinned, fn(q) { q != path }),
        opened: list.filter(m.opened, fn(q) { q != path }),
      )
      |> place
    }
  }
}

fn close_side(m: Model, path: String) -> Model {
  let m =
    Model(
      ..m,
      pinned: list.filter(m.pinned, fn(q) { q != path }),
      opened: list.filter(m.opened, fn(q) { q != path }),
      marks: dict.delete(m.marks, path),
      came: case m.came {
        Some(#(_, dest)) if dest.path == path -> None
        c -> c
      },
    )
  let #(skipped, rest) = list.split_while(m.back, fn(l) { l.path == path })
  let _ = skipped
  case rest {
    [l, ..older] -> Model(..show_loc(m, l), back: older, came: None)
    [] ->
      place(m)
      |> glide_to_main
  }
}

/// Where the view is now: the last place landed on, or the working file.
fn here(m: Model) -> Loc {
  case m.came {
    Some(#(_, dest)) if dest.main == m.main -> dest
    _ -> {
      let line = result_or(dict.get(m.marks, m.main), 1)
      Loc(m.main, m.main, line, line_label(m, m.main, line))
    }
  }
}

fn go_back(m: Model) -> Model {
  case m.back {
    [] -> m
    [l, ..rest] -> {
      let cur = here(m)
      Model(..show_loc(m, l), back: rest, fwd: [cur, ..m.fwd], came: None)
    }
  }
}

fn go_forward(m: Model) -> Model {
  case m.fwd {
    [] -> m
    [l, ..rest] -> {
      let cur = here(m)
      Model(..show_loc(m, l), fwd: rest, back: [cur, ..m.back], came: None)
    }
  }
}

fn fs(m: Model) -> program.Fs {
  program.memory_fs(m.files, "/", "/", "/priv/stdlib")
}

fn rebuild(m: Model) -> Model {
  let t0 = now()
  case m.base {
    Error(e) -> Model(..m, error: e, program: None)
    Ok(base) -> {
      let base = program.Program(..base, fs: fs(m))
      case program.load(base, m.main) {
        Error(e) ->
          Model(
            ..m,
            error: model.error_text(e),
            check_ms: now() -. t0,
            report: check.empty_report(),
            states: dict.insert(
              m.states,
              m.main,
              FileState(file_text(m, m.main), 1, False, dict.new()),
            ),
          )
        Ok(#(p, rep)) -> {
          let m = record(m, p, rep)
          let file = program.display(p, m.main)
          let g = graph.build(p, file)
          let grids =
            list.fold(program.ordered(p), dict.new(), fn(acc, d) {
              case d.file == file && d.kind == model.Record {
                False -> acc
                True ->
                  list.fold(d.fields, acc, fn(acc, f) {
                    case check.mapping_grid(p.decls, p.index, d, f) {
                      Some(grid) ->
                        dict.insert(acc, d.name <> "." <> f.name, grid)
                      None -> acc
                    }
                  })
              }
            })
          let m =
            Model(
              ..m,
              program: Some(p),
              report: rep,
              error: "",
              graph: g,
              grids: grids,
            )
          let m =
            Model(..m, probes: list.map(m.probes, fn(pr) { run_probe(m, pr) }))
          Model(..m, check_ms: now() -. t0)
        }
      }
    }
  }
}

fn file_text(m: Model, path: String) -> String {
  result_or(dict.get(m.files, path), "")
}

fn is_core(path: String) -> Bool {
  string.starts_with(path, "/priv/")
}

/// After a compile: every file it read gets the text it read, its error
/// count, whether it proved claims, and the texts of the other files read.
fn record(m: Model, p: program.Program, rep: Report) -> Model {
  let errs = check.errors(rep)
  let read =
    dict.filter(p.loaded, fn(path, _) { string.starts_with(path, "/") })
    |> dict.map_values(fn(path, _) { file_text(m, path) })
  dict.fold(read, m, fn(m, path, text) {
    let shown = program.display(p, path)
    let n = list.count(errs, fn(d) { d.file == shown })
    let claims =
      list.count(rep.claims, fn(c) {
        case string.split_once(c.0, ".") {
          Ok(#(t, _)) ->
            case dict.get(p.decls, t) {
              Ok(d) -> d.file == shown
              Error(_) -> False
            }
          Error(_) -> False
        }
      })
    let deps = dict.delete(read, path)
    Model(
      ..m,
      states: dict.insert(
        m.states,
        path,
        FileState(text, n, claims > 0 && n == 0, deps),
      ),
    )
  })
}

/// Compile one file: the working file rebuilds everything; another file is
/// checked on its own, which records it and the files it reads.
fn compile(m: Model, path: String) -> Model {
  case path == m.main {
    True -> rebuild(m) |> place
    False ->
      case m.base {
        Error(_) -> m
        Ok(base) -> {
          let base = program.Program(..base, fs: fs(m))
          case program.load(base, path) {
            Ok(#(p, rep)) -> record(m, p, rep)
            Error(_) ->
              Model(
                ..m,
                states: dict.insert(
                  m.states,
                  path,
                  FileState(file_text(m, path), 1, False, dict.new()),
                ),
              )
          }
        }
      }
  }
}

/// A file's colour. A locked file cannot change, so it shows blue unless
/// it has errors or something it reads has changed.
fn file_state(m: Model, path: String) -> Status {
  case is_locked(m, path), dict.has_key(m.states, path) {
    True, False -> Core
    True, True ->
      case status_raw(m, path) {
        Errors(n) -> Errors(n)
        Affected(by) -> Affected(by)
        _ -> Core
      }
    False, _ -> status_raw(m, path)
  }
}

/// language.sheaf is always locked; the rest of the core library starts
/// locked; any file can be locked by hand.
fn is_locked(m: Model, path: String) -> Bool {
  is_prelude(path)
  || { is_core(path) && !list.contains(m.unlocked, path) }
  || list.contains(m.locked, path)
}

fn toggle(xs: List(String), x: String) -> List(String) {
  case list.contains(xs, x) {
    True -> list.filter(xs, fn(y) { y != x })
    False -> [x, ..xs]
  }
}

fn lock_toggle(m: Model, path: String) -> Model {
  case is_prelude(path), is_core(path) {
    True, _ -> m
    _, True -> Model(..m, unlocked: toggle(m.unlocked, path))
    _, False -> Model(..m, locked: toggle(m.locked, path))
  }
  |> fn(m) {
    // a file that becomes locked stops being edited
    case is_locked(m, path) {
      True ->
        Model(
          ..m,
          editing: list.filter(m.editing, fn(e) { id_path(m, e) != path }),
        )
      False -> m
    }
  }
}

/// Where a line is, for people: the type it declares or the field on it.
fn line_label(m: Model, path: String, line: Int) -> String {
  case m.program {
    None -> "line " <> int.to_string(line)
    Some(p) -> {
      let shown = program.display(p, path)
      let mine = list.filter(program.ordered(p), fn(d) { d.file == shown })
      let above =
        list.filter(mine, fn(d) { d.line <= line })
        |> list.last
      case above {
        Error(_) -> "line " <> int.to_string(line)
        Ok(d) ->
          case list.find(d.fields, fn(f) { f.line == line }) {
            Ok(f) -> d.name <> "." <> f.name
            Error(_) ->
              case list.find(d.positions, fn(ps) { ps.line == line }) {
                Ok(ps) -> d.name <> "." <> int.to_string(ps.number)
                Error(_) -> d.name
              }
          }
      }
    }
  }
}

fn status_raw(m: Model, path: String) -> Status {
  case list.contains(m.dirty, path) {
    True -> Changed
    False -> status_stored(m, path)
  }
}

fn status_stored(m: Model, path: String) -> Status {
  case dict.get(m.states, path) {
    Error(_) -> Changed
    Ok(st) -> {
      let text = file_text(m, path)
      case text != st.text, st.errors > 0, dict.get(m.committed, path) {
        True, _, _ -> Changed
        _, True, _ -> Errors(st.errors)
        _, _, Error(_) -> Changed
        _, _, Ok(#(ctext, _)) if ctext != text -> Changed
        _, _, Ok(#(_, deps)) -> {
          let by =
            dict.to_list(deps)
            |> list.find(fn(dt) {
              file_text(m, dt.0) != dt.1
              || case dict.get(m.states, dt.0) {
                Ok(ds) -> ds.errors > 0
                Error(_) -> False
              }
            })
          case by, st.proved {
            Ok(#(d, _)), _ -> Affected(program.display_path(d))
            _, True -> Proved
            _, False -> Compiled
          }
        }
      }
    }
  }
}

fn status_class(s: Status) -> String {
  case s {
    Core -> "core"
    Compiled -> "compiled"
    Proved -> "proved"
    Changed -> "changed"
    Affected(_) -> "affected"
    Errors(_) -> "errors"
    Outside -> "outside"
  }
}

fn status_text(s: Status) -> String {
  case s {
    Core -> "locked"
    Compiled -> "compiled"
    Proved -> "compiled · claims proved"
    Changed -> "changed · not compiled"
    Affected(by) -> "affected by " <> by
    Errors(n) -> int.to_string(n) <> " error" <> plural(n)
    Outside -> "outside this file's scope"
  }
}

fn status_color(p: Pal, s: Status) -> String {
  case s {
    Core -> p.st_core
    Compiled -> p.st_compiled
    Proved -> p.st_proved
    Changed -> p.st_changed
    Affected(_) -> p.st_affected
    Errors(_) -> p.st_errors
    Outside -> p.st_outside
  }
}

/// The colour of the file that declares a type.
fn type_status(m: Model, name: String) -> Status {
  case m.program {
    None -> Core
    Some(p) ->
      case dict.get(p.decls, name) {
        Ok(d) ->
          case d.file == program.prelude_name {
            True -> Core
            False -> file_state(m, "/" <> d.file)
          }
        Error(_) -> Core
      }
  }
}

/// What a type reduces to, step by step, down to the core: Money → Decimal,
/// Customer_Code → Text. A record ends in "record", a union in its items.
fn chain(m: Model, name: String) -> List(#(String, Status)) {
  chain_loop(m, name, [], 0)
}

fn chain_loop(m: Model, name: String, acc, depth: Int) {
  let step = #(name, type_status(m, name))
  case m.program, depth > 6 {
    None, _ | _, True -> list.reverse([step, ..acc])
    Some(p), False ->
      case dict.get(p.decls, name) {
        Error(_) ->
          case list.contains(model.builtin_numeric, name) {
            True -> list.reverse([#(name, Core), ..acc])
            False -> list.reverse([#(name, Outside), ..acc])
          }
        Ok(d) ->
          case d.file == program.prelude_name {
            True -> list.reverse([step, ..acc])
            False ->
              case d.kind, d.items {
                model.Record, _ ->
                  list.reverse([#("record", Core), step, ..acc])
                model.Union, its ->
                  list.reverse([#(model.items_text(its), Core), step, ..acc])
                _, [model.TypeItem(b), ..] ->
                  chain_loop(m, b, [step, ..acc], depth + 1)
                _, [it, ..] ->
                  list.reverse([#(model.item_text(it), Core), step, ..acc])
                _, [] -> list.reverse([step, ..acc])
              }
          }
      }
  }
}

/// Type names on a line of code, in order.
fn type_tokens(line: String) -> List(String) {
  string.to_graphemes(line <> " ")
  |> list.fold(#([], ""), fn(st, ch) {
    let #(out, cur) = st
    case is_name_char(ch) {
      True -> #(out, cur <> ch)
      False ->
        case cur != "" && is_upper(cur) {
          True -> #([cur, ..out], "")
          False -> #(out, "")
        }
    }
  })
  |> fn(st) { list.reverse(st.0) |> list.unique }
}

fn is_name_char(ch: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    ch,
  )
}

fn is_upper(s: String) -> Bool {
  case string.first(s) {
    Ok(c) -> string.uppercase(c) == c && string.lowercase(c) != c
    Error(_) -> False
  }
}

fn nth_line(text: String, n: Int) -> String {
  result_or(list.first(list.drop(string.split(text, "\n"), n - 1)), "")
}

/// The files a line of the working file draws on: for each type it names,
/// the file declaring it (in scope), or a file outside the scope that
/// declares a type of that name the working file cannot see.
fn peeks_for(m: Model, line: Int) -> List(Peek) {
  let text = nth_line(file_text(m, m.main), line)
  // a type the working file cannot see: some other file declares it
  let elsewhere = fn(t: String) {
    dict.to_list(m.files)
    |> list.find_map(fn(f) {
      let #(path, body) = f
      case string.ends_with(path, ".sheaf") && path != m.main {
        False -> Error(Nil)
        True ->
          string.split(body, "\n")
          |> list.index_fold(Error(Nil), fn(acc, l, i) {
            case
              acc,
              string.starts_with(l, t <> " ") && string.contains(l, "{")
            {
              Ok(_), _ -> acc
              _, True -> Ok(Peek(path, i + 1, True))
              _, False -> acc
            }
          })
      }
    })
  }
  let own = case m.program {
    Some(p) -> fn(t: String) { dict.get(p.decls, t) }
    None -> fn(_) { Error(Nil) }
  }
  type_tokens(text)
  |> list.filter_map(fn(t) {
    case own(t) {
      Ok(d) ->
        case d.file == program.prelude_name || "/" <> d.file == m.main {
          True -> Error(Nil)
          False -> Ok(Peek("/" <> d.file, d.line, False))
        }
      Error(_) ->
        case is_declared_here(m, t) {
          True -> Error(Nil)
          False -> elsewhere(t)
        }
    }
  })
  |> list.unique
}

/// Declared in the working file itself (even when it does not compile).
fn is_declared_here(m: Model, t: String) -> Bool {
  string.split(file_text(m, m.main), "\n")
  |> list.any(fn(l) {
    string.starts_with(l, t <> " ") && string.contains(l, "{")
  })
}

/// The type a line is about: the one it declares, or its field's type.
fn line_subject(m: Model, line: Int) -> Option(String) {
  let from_target = case line_target(m, line), m.program {
    Some(#(t, "")), _ -> Some(t)
    Some(#(t, row)), Some(p) ->
      case dict.get(p.decls, t) {
        Ok(d) ->
          case model.field(d, row) {
            Some(f) ->
              case f.mapping, f.items {
                Some(mp), _ ->
                  case mp.outputs {
                    [model.TypeItem(o), ..] -> Some(o)
                    _ -> None
                  }
                None, [model.TypeItem(b), ..] -> Some(b)
                _, _ -> None
              }
            None -> None
          }
        Error(_) -> None
      }
    _, _ -> None
  }
  case from_target {
    Some(t) -> Some(t)
    None ->
      case type_tokens(nth_line(file_text(m, m.main), line)) {
        [t, ..] -> Some(t)
        [] -> None
      }
  }
}

fn run_probe(m: Model, pr: Probe) -> Probe {
  case m.program {
    Some(p) ->
      case check.errors(m.report) {
        [] ->
          Probe(..pr, outcome: Some(program.check(p, pr.type_name, pr.text)))
        _ -> Probe(..pr, outcome: None)
      }
    None -> Probe(..pr, outcome: None)
  }
}

fn line_count(s: String) -> Int {
  list.length(string.split(s, "\n"))
}

fn place(m: Model) -> Model {
  case m.view {
    "code" -> place_code(m)
    _ -> place_types(m)
  }
}

const file_w = 820.0

/// The files the working file read, plus files outside its scope that a
/// hovered line named; each keeps one slot around the working file.
fn candidates(m: Model) -> List(String) {
  let read = case m.program {
    Some(p) ->
      dict.keys(p.loaded)
      |> list.filter(fn(x) { string.starts_with(x, "/") && x != m.main })
    None -> []
  }
  list.flatten([read, m.strangers, m.opened])
  |> list.filter(fn(x) {
    !list.contains(m.closed, x) || list.contains(m.pinned, x)
  })
  |> list.unique
  |> list.sort(string.compare)
}

/// "a:b:c" -> #("a:b", "c").
fn split_last(s: String) -> Result(#(String, String), Nil) {
  case list.reverse(string.split(s, ":")) {
    [last, first, ..rest] ->
      Ok(#(string.join(list.reverse([first, ..rest]), ":"), last))
    _ -> Error(Nil)
  }
}

/// "Type:id:line" where the id may hold a colon.
fn split_link(s: String) -> Result(#(String, String, String), Nil) {
  case string.split_once(s, ":") {
    Ok(#(t, rest)) ->
      case split_last(rest) {
        Ok(#(id, ln)) -> Ok(#(t, id, ln))
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

fn id_path(m: Model, id: String) -> String {
  case id {
    "code" -> m.main
    "f:" <> path -> path
    _ -> ""
  }
}

/// Follow a type link: bring up the line that declares it. In the working
/// file, scroll there; in another file, open it beside, scrolled and marked.
fn goto(m: Model, t: String, from: Loc) -> Model {
  case find_decl(m, t) {
    None -> m
    Some(#(path, line, outside)) -> jump(m, path, line, outside, t, from)
  }
}

/// Go to a line of a file, remembering where from. The working file
/// scrolls; language.sheaf and files outside the scope open beside; any
/// other file becomes the working file, the canvas gliding over to it.
fn jump(
  m: Model,
  path: String,
  line: Int,
  outside: Bool,
  label: String,
  from: Loc,
) -> Model {
  let dest = case path == m.main || outside || is_prelude(path) {
    True -> Loc(m.main, path, line, label)
    False -> Loc(path, path, line, label)
  }
  let m = case outside {
    True ->
      Model(..m, strangers: case list.contains(m.strangers, path) {
        True -> m.strangers
        False -> [path, ..m.strangers]
      })
    False -> m
  }
  let finish = fn(m: Model) {
    Model(
      ..show_loc(m, dest),
      back: [from, ..m.back],
      fwd: [],
      came: Some(#(from, dest)),
      hover_type: "",
    )
  }
  let pane =
    list.find(m.panels, fn(pn) { pn.path == dest.main && pn.id != "code" })
  case dest.main != m.main, pane {
    // the file's pane is beside the working file: bring it up where it
    // sits, glide the canvas over to it, and make it the working file
    // when the glide lands
    True, Ok(pn) ->
      Model(
        ..m,
        pinned: [pn.path, ..list.filter(m.pinned, fn(q) { q != pn.path })],
        marks: dict.insert(m.marks, pn.path, line),
        hover_type: "",
        pending: Some(finish),
      )
      |> glide_to(centre_on(m, pn))
    _, _ -> finish(m)
  }
}

/// Search every file: type names first (names that start with the query
/// before names that contain it), then fields (Type.field), then lines of
/// text. The working file and the files it reads come first.
fn search(m: Model, q: String) -> List(Hit) {
  let lq = string.lowercase(string.trim(q))
  case lq {
    "" -> []
    _ -> {
      let read = candidates(m)
      let rank = fn(path: String) {
        case path == m.main, list.contains(read, path), is_core(path) {
          True, _, _ -> 0
          _, True, _ -> 1
          _, _, False -> 2
          _, _, True -> 3
        }
      }
      let files =
        dict.keys(m.files)
        |> list.filter(fn(f) { string.ends_with(f, ".sheaf") })
        |> list.sort(fn(a, b) {
          case int.compare(rank(a), rank(b)) {
            order.Eq -> string.compare(a, b)
            o -> o
          }
        })
      let found =
        list.flat_map(files, fn(path) {
          let #(hits, _) =
            string.split(file_text(m, path), "\n")
            |> list.index_fold(#([], ""), fn(st, l, i) {
              let #(hits, decl) = st
              let n = i + 1
              let head = first_word(string.trim_start(l))
              case
                is_upper(head)
                && string.contains(l, "{")
                && !string.starts_with(l, " "),
                string.starts_with(l, "  ")
                && !string.starts_with(l, "   ")
                && head != ""
                && !is_upper(head)
                && !string.starts_with(string.trim_start(l), "#")
              {
                True, _ -> {
                  let hits = case string.contains(string.lowercase(head), lq) {
                    True -> [Hit("type", head, path, n, string.trim(l)), ..hits]
                    False -> text_hit(hits, l, lq, path, n)
                  }
                  #(hits, head)
                }
                _, True -> {
                  let hits = case
                    string.contains(string.lowercase(head), lq) && decl != ""
                  {
                    True -> [
                      Hit("field", decl <> "." <> head, path, n, string.trim(l)),
                      ..hits
                    ]
                    False -> text_hit(hits, l, lq, path, n)
                  }
                  #(hits, decl)
                }
                _, _ -> #(text_hit(hits, l, lq, path, n), decl)
              }
            })
          list.reverse(hits)
        })
      let types = list.filter(found, fn(h) { h.kind == "type" })
      let starts =
        list.filter(types, fn(h) {
          string.starts_with(string.lowercase(h.label), lq)
        })
      let rest =
        list.filter(types, fn(h) {
          !string.starts_with(string.lowercase(h.label), lq)
        })
      let fields = list.filter(found, fn(h) { h.kind == "field" })
      let texts = case string.length(lq) >= 2 {
        True -> list.filter(found, fn(h) { h.kind == "text" })
        False -> []
      }
      list.flatten([
        list.take(list.append(starts, rest), 12),
        list.take(fields, 10),
        list.take(texts, 20),
      ])
    }
  }
}

fn first_word(s: String) -> String {
  string.to_graphemes(s)
  |> list.take_while(is_name_char)
  |> string.concat
}

fn text_hit(hits: List(Hit), l: String, lq: String, path: String, n: Int) {
  case string.contains(string.lowercase(l), lq) {
    True -> [Hit("text", string.trim(l), path, n, ""), ..hits]
    False -> hits
  }
}

fn is_prelude(path: String) -> Bool {
  path == "/priv/language.sheaf"
}

/// Where a type is declared: (file, line, outside the working file's scope).
fn find_decl(m: Model, t: String) -> Option(#(String, Int, Bool)) {
  case list.contains(model.builtin_numeric, t) {
    True -> Some(#("/priv/language.sheaf", builtin_line(m), False))
    False -> find_declared(m, t)
  }
}

fn find_declared(m: Model, t: String) -> Option(#(String, Int, Bool)) {
  let known = case m.program {
    Some(p) ->
      case dict.get(p.decls, t) {
        Ok(d) ->
          case d.file == program.prelude_name {
            True -> Some(#("/priv/language.sheaf", d.line, False))
            False -> Some(#("/" <> d.file, d.line, False))
          }
        Error(_) -> None
      }
    None -> None
  }
  case known {
    Some(x) -> Some(x)
    None ->
      option.map(peeks_for_name(m, t), fn(pk) {
        #(pk.path, pk.line, pk.outside)
      })
  }
}

/// The text of a declaration: its line and the indented lines under it.
fn decl_text(m: Model, path: String, line: Int) -> String {
  let lines = string.split(file_text(m, path), "\n") |> list.drop(line - 1)
  case lines {
    [] -> ""
    // a comment (the built-in numbers): up to the first blank line
    ["#" <> _, ..] ->
      list.take_while(lines, fn(l) { string.trim(l) != "" })
      |> list.take(16)
      |> string.join("\n")
    [first, ..rest] -> {
      let body =
        list.take_while(rest, fn(l) { string.starts_with(l, " ") })
        |> list.take(16)
      string.join([first, ..body], "\n")
    }
  }
}

/// A type declared in some file other than the working one, found by text.
fn peeks_for_name(m: Model, t: String) -> Option(Peek) {
  dict.to_list(m.files)
  |> list.find_map(fn(f) {
    let #(path, body) = f
    case string.ends_with(path, ".sheaf") {
      False -> Error(Nil)
      True ->
        string.split(body, "\n")
        |> list.index_fold(Error(Nil), fn(acc, l, i) {
          case acc, string.starts_with(l, t <> " ") && string.contains(l, "{") {
            Ok(_), _ -> acc
            _, True -> Ok(Peek(path, i + 1, path != m.main))
            _, False -> acc
          }
        })
    }
  })
  |> option.from_result
}

/// Type names a file panel can link: everything the program declares.
fn link_names(m: Model) -> List(String) {
  case m.program {
    Some(p) -> list.append(dict.keys(p.decls), model.builtin_numeric)
    None -> model.builtin_numeric
  }
}

/// Integer and Decimal are built in: language.sheaf describes them in a
/// comment, which is where their links lead.
fn builtin_line(m: Model) -> Int {
  string.split(file_text(m, "/priv/language.sheaf"), "\n")
  |> list.index_fold(0, fn(acc, l, i) {
    case acc, string.starts_with(l, "# Built-in numbers") {
      0, True -> i + 1
      _, _ -> acc
    }
  })
}

/// A pane shows its file up to a height, and scrolls (only up and down).
fn code_height(m: Model, path: String, cap: Float) -> Float {
  float.min(cap, pane_height(file_text(m, path)))
}

fn pane_height(text: String) -> Float {
  56.0 +. int.to_float(line_count(text)) *. 17.0
}

/// The working file in the middle; the files it reads on an ellipse around
/// it, hidden until a line names one of their types; probes to the right.
fn place_code(m: Model) -> Model {
  let h = code_height(m, m.main, 640.0)
  let #(ox, oy) = m.origin
  let main = case dict.get(m.moved, "panel:code") {
    Ok(#(x, y)) -> Panel("code", m.main, x, y, code_w, h)
    Error(_) ->
      Panel("code", m.main, ox -. code_w /. 2.0, oy -. h /. 2.0, code_w, h)
  }
  let files = candidates(m)
  let n = list.length(files)
  // two columns beside the working file, alternating right and left, each
  // stacked and centred on it, so no file ever covers the working file
  let column = fn(side: Int) {
    list.index_map(files, fn(path, i) { #(path, i) })
    |> list.filter(fn(pi) { pi.1 % 2 == side })
    |> list.map(fn(pi) { pi.0 })
  }
  let stack = fn(paths: List(String), x: Float) {
    let hs = list.map(paths, fn(path) { code_height(m, path, 320.0) })
    let total =
      float.sum(hs) +. 40.0 *. int.to_float(int.max(list.length(hs) - 1, 0))
    let #(out, _) =
      list.fold(list.zip(paths, hs), #([], oy -. total /. 2.0), fn(acc, ph) {
        let #(out, y) = acc
        let #(path, fh) = ph
        let id = "f:" <> path
        let pn = case dict.get(m.moved, "panel:" <> id) {
          Ok(#(px, py)) -> Panel(id, path, px, py, file_w, fh)
          Error(_) -> Panel(id, path, x, y, file_w, fh)
        }
        #([pn, ..out], y +. fh +. 40.0)
      })
    list.reverse(out)
  }
  let others =
    list.append(
      stack(column(0), ox +. code_w /. 2.0 +. 90.0),
      stack(column(1), ox -. code_w /. 2.0 -. 90.0 -. file_w),
    )
  let rx = code_w /. 2.0 +. 90.0 +. file_w /. 2.0
  let px = case n {
    0 -> ox +. code_w /. 2.0 +. 140.0
    _ -> ox +. rx +. file_w /. 2.0 +. 140.0
  }
  let #(probes, _) =
    list.fold(live_probes(m), #([], oy -. h /. 2.0), fn(acc, pr) {
      let #(out, y) = acc
      let ph = probe_height(m, pr)
      let #(x, yy) = case dict.get(m.moved, "panel:" <> pr.id) {
        Ok(q) -> q
        Error(_) -> #(px, y)
      }
      #([Probe(..pr, x: x, y: yy), ..out], y +. ph +. 48.0)
    })
  let placed = list.reverse(probes)
  let probes =
    list.map(m.probes, fn(pr) {
      case list.find(placed, fn(q) { q.id == pr.id }) {
        Ok(q) -> q
        Error(_) -> pr
      }
    })
  Model(..m, panels: [main, ..others], probes: probes)
}

/// Lay the graph out to the right of the code, the probes to the right of the graph.
fn place_types(m: Model) -> Model {
  let extra =
    dict.fold(m.grids, dict.new(), fn(acc, k, _) {
      case string.split_once(k, ".") {
        Ok(#(t, _)) ->
          dict.insert(acc, t, result_or(dict.get(acc, t), 0.0) +. 200.0)
        Error(_) -> acc
      }
    })
  let code_text = result_or(dict.get(m.files, m.main), "")
  let code_h = float.min(900.0, pane_height(code_text))
  let focus = case m.focus {
    Some(f) ->
      case list.any(m.graph.nodes, fn(n) { n.id == f }) {
        True -> Some(f)
        False -> None
      }
    None -> None
  }
  let #(laid, rings, orbit) = case focus {
    Some(f) -> {
      let rings = rings_of(m.graph, f, m.levels)
      let #(laid, orbit) = radial(m, f, rings, code_h /. 2.0)
      #(laid, rings, orbit)
    }
    None -> #(graph.layout_with(m.graph, extra), dict.new(), #(0.0, 0.0, []))
  }
  let m = Model(..m, focus: focus, rings: rings, orbit: orbit)
  let target =
    dict.map_values(laid, fn(id, p) {
      case dict.get(m.moved, id) {
        Ok(q) -> q
        Error(_) -> #(p.0, p.1)
      }
    })
  // nodes ease from where they are; new ones start where they belong
  let pos = case m.reduced {
    True -> target
    False ->
      dict.map_values(target, fn(id, t) { result_or(dict.get(m.pos, id), t) })
  }
  let #(_, _, x1, _) = graph.bounds(shown_graph(m), target)
  let panels =
    list.map(m.panels, fn(pn) {
      case pn.id {
        "code" ->
          case dict.get(m.moved, "panel:code") {
            Ok(#(x, y)) -> Panel(..pn, x: x, y: y, h: code_h)
            Error(_) ->
              Panel(..pn, x: 0.0 -. code_w -. 100.0, y: 0.0, h: code_h)
          }
        _ -> pn
      }
    })
  let px = x1 +. 160.0
  let #(probes, _) =
    list.fold(m.probes, #([], 0.0), fn(acc, pr) {
      let #(out, y) = acc
      let h = probe_height(m, pr)
      let #(x, yy) = case dict.get(m.moved, "panel:" <> pr.id) {
        Ok(q) -> q
        Error(_) -> #(px, y)
      }
      #([Probe(..pr, x: x, y: yy), ..out], y +. h +. 48.0)
    })
  Model(
    ..m,
    pos: pos,
    target: target,
    panels: panels,
    probes: list.reverse(probes),
  )
}

// ---------------------------------------------------------------- focus and rings

fn shown(m: Model, id: String) -> Bool {
  dict.is_empty(m.rings) || dict.has_key(m.rings, id)
}

fn shown_graph(m: Model) -> Graph {
  graph.Graph(
    list.filter(m.graph.nodes, fn(n) { shown(m, n.id) }),
    m.graph.edges,
  )
}

/// Every type with the types it is related to, in either direction.
fn neighbours(g: Graph) -> Dict(String, List(String)) {
  let add = fn(acc, a, b) {
    dict.upsert(acc, a, fn(x) {
      case x {
        Some(xs) -> [b, ..xs]
        None -> [b]
      }
    })
  }
  list.fold(g.edges, dict.new(), fn(acc, e) {
    case e {
      TypeWire(a, b, _, _) -> add(add(acc, a, b), b, a)
      _ -> acc
    }
  })
  |> dict.map_values(fn(_, xs) { list.unique(xs) |> list.sort(string.compare) })
}

/// Ring k holds the types k relations away from the focus, up to 'levels'.
fn rings_of(g: Graph, focus: String, levels: Int) -> Dict(String, Int) {
  rings_loop(neighbours(g), [focus], 1, levels, dict.from_list([#(focus, 0)]))
}

fn rings_loop(nb, frontier: List(String), ring: Int, levels: Int, acc) {
  case frontier, ring > levels {
    [], _ | _, True -> acc
    _, False -> {
      let next =
        list.flat_map(frontier, fn(n) { result_or(dict.get(nb, n), []) })
        |> list.unique
        |> list.filter(fn(x) { !dict.has_key(acc, x) })
      let acc = list.fold(next, acc, fn(a, x) { dict.insert(a, x, ring) })
      rings_loop(nb, next, ring + 1, levels, acc)
    }
  }
}

const pi = 3.141592653589793

fn sqrt(x: Float) -> Float {
  result_or(float.square_root(x), 0.0)
}

/// The focus at the centre and each ring on a circle around it, wide enough
/// that its boxes do not touch. Each outer type sits near the types it is
/// related to on the ring inside it. Positions are top-left corners.
fn radial(
  m: Model,
  focus: String,
  rings: Dict(String, Int),
  cy: Float,
) -> #(Dict(String, #(Float, Float)), #(Float, Float, List(Float))) {
  let nb = neighbours(m.graph)
  // the centre's mapping tables hang below it, so they count as its size
  let tables =
    dict.keys(m.grids)
    |> list.filter(fn(k) { string.starts_with(k, focus <> ".") })
    |> list.length
  let size = fn(id) {
    let extra = case id == focus {
      True -> int.to_float(tables) *. 200.0
      False -> 0.0
    }
    case list.find(m.graph.nodes, fn(n) { n.id == id }) {
      Ok(n) -> #(graph.node_w, graph.node_h(n) +. extra)
      Error(_) -> #(graph.node_w, graph.head_h)
    }
  }
  let half = fn(id) {
    let #(w, h) = size(id)
    sqrt(w *. w /. 4.0 +. h *. h /. 4.0)
  }
  let deepest = dict.fold(rings, 0, fn(acc, _, r) { int.max(acc, r) })
  let #(angles, radii, _, _) =
    int.range(1, deepest + 1, [], fn(acc, k) { [k, ..acc] })
    |> list.reverse
    |> list.fold(
      #(dict.from_list([#(focus, 0.0)]), [], 0.0, half(focus)),
      fn(st, k) {
        let #(angles, radii, prev_r, prev_half) = st
        let ids =
          dict.to_list(rings)
          |> list.filter_map(fn(e) {
            case e.1 == k {
              True -> Ok(e.0)
              False -> Error(Nil)
            }
          })
          |> list.sort(string.compare)
        // where each sits: the mean direction of its neighbours inside
        let pull = fn(id) {
          let inner =
            result_or(dict.get(nb, id), [])
            |> list.filter_map(fn(x) {
              case dict.get(rings, x) {
                Ok(r) if r == k - 1 -> dict.get(angles, x)
                _ -> Error(Nil)
              }
            })
          case inner {
            [] -> 0.0
            _ -> {
              let sy = float.sum(list.map(inner, sin))
              let sx = float.sum(list.map(inner, cos))
              atan2(sy, sx)
            }
          }
        }
        let ids = case k {
          1 -> ids
          _ ->
            list.sort(ids, fn(a, b) {
              float.compare(norm(pull(a)), norm(pull(b)))
            })
        }
        let n = list.length(ids)
        let biggest =
          list.fold(ids, 0.0, fn(acc, id) { float.max(acc, half(id)) })
        let around =
          list.fold(ids, 0.0, fn(acc, id) {
            let #(w, h) = size(id)
            acc +. { w +. h } /. 2.0 +. 70.0
          })
        let r =
          float.max(
            prev_r +. prev_half +. biggest +. 70.0,
            around /. { 2.0 *. pi },
          )
        let start = case k, ids {
          1, _ -> 0.0 -. pi /. 2.0
          _, [first, ..] -> pull(first)
          _, [] -> 0.0
        }
        let angles =
          list.index_fold(ids, angles, fn(acc, id, i) {
            dict.insert(
              acc,
              id,
              start
                +. 2.0
                *. pi
                *. int.to_float(i)
                /. int.to_float(int.max(n, 1)),
            )
          })
        #(angles, list.append(radii, [r]), r, biggest)
      },
    )
  let outer = case list.last(radii) {
    Ok(r) -> r
    Error(_) -> 0.0
  }
  let reach =
    outer +. dict.fold(rings, 0.0, fn(acc, id, _) { float.max(acc, half(id)) })
  let cx = reach +. 20.0
  let radius_of = fn(id) {
    case dict.get(rings, id) {
      Ok(0) | Error(_) -> 0.0
      Ok(k) -> result_or(list.first(list.drop(radii, k - 1)), 0.0)
    }
  }
  let pos =
    dict.fold(rings, dict.new(), fn(acc, id, _) {
      let a = result_or(dict.get(angles, id), 0.0)
      let r = radius_of(id)
      let #(w, h) = size(id)
      dict.insert(acc, id, #(
        cx +. r *. cos(a) -. w /. 2.0,
        cy +. r *. sin(a) -. h /. 2.0,
      ))
    })
  #(pos, #(cx, cy, radii))
}

/// An angle in [-pi/2, 3pi/2), so sorting starts at the top and goes clockwise.
fn norm(a: Float) -> Float {
  case a <. 0.0 -. pi /. 2.0 {
    True -> norm(a +. 2.0 *. pi)
    False ->
      case a >=. 1.5 *. pi {
        True -> norm(a -. 2.0 *. pi)
        False -> a
      }
  }
}

/// Click a type: it moves to the middle, its related types around it.
fn focus_on(m: Model, id: String) -> Model {
  let moved = dict.filter(m.moved, fn(k, _) { string.starts_with(k, "panel:") })
  let m =
    Model(..m, focus: Some(id), selected: Some(id), moved: moved)
    |> place
  // frame symmetrically around the centre, so the focus sits in the middle
  let #(cx, cy, _) = m.orbit
  let #(x0, y0, x1, y1) = graph.bounds(shown_graph(m), m.target)
  let ex = float.max(cx -. x0, x1 -. cx)
  let ey = float.max(cy -. y0, y1 -. cy)
  frame_rect(m, #(cx -. ex, cy -. ey, cx +. ex, cy +. ey), True, 1.1)
}

fn unfocus(m: Model) -> Model {
  let moved = dict.filter(m.moved, fn(k, _) { string.starts_with(k, "panel:") })
  Model(..m, focus: None, rings: dict.new(), moved: moved)
  |> place
  |> fit(True)
}

fn set_level_count(m: Model, n: Int) -> Model {
  let m = Model(..m, levels: int.clamp(n, 1, 5))
  case m.focus {
    Some(f) -> focus_on(m, f)
    None -> m
  }
}

/// The hovered line: from the code panel when the pointer is there.
fn hov(m: Model) -> Option(#(String, String)) {
  case m.code_hover {
    Some(h) -> Some(h)
    None -> m.hover
  }
}

/// The type and row a line of the code declares: a field, a position, or the
/// declaration's own line (its header, as row "").
fn line_target(m: Model, line: Int) -> Option(#(String, String)) {
  case m.program {
    None -> None
    Some(p) -> {
      let file = program.display(p, m.main)
      let mine = list.filter(program.ordered(p), fn(d) { d.file == file })
      let exact =
        list.find_map(mine, fn(d) {
          case d.line == line {
            True -> Ok(#(d.name, ""))
            False ->
              case list.find(d.fields, fn(f) { f.line == line }) {
                Ok(f) -> Ok(#(d.name, f.name))
                Error(_) ->
                  case list.find(d.positions, fn(ps) { ps.line == line }) {
                    Ok(ps) -> Ok(#(d.name, int.to_string(ps.number)))
                    Error(_) -> Error(Nil)
                  }
              }
          }
        })
      case exact {
        Ok(t) ->
          case list.any(m.graph.nodes, fn(n) { n.id == t.0 }) {
            True -> Some(t)
            False -> None
          }
        Error(_) -> None
      }
    }
  }
}

fn probe_text_h(pr: Probe) -> Float {
  44.0 +. int.to_float(int.min(10, line_count(pr.text))) *. 17.0
}

fn probe_height(m: Model, pr: Probe) -> Float {
  probe_text_h(pr)
  +. 16.0
  +. int.to_float(list.length(probe_rows(m, pr)))
  *. 22.0
  +. 30.0
}

fn result_or(r: Result(a, b), d: a) -> a {
  case r {
    Ok(x) -> x
    Error(_) -> d
  }
}

// ---------------------------------------------------------------- camera

fn to_world(m: Model, sx: Float, sy: Float) -> #(Float, Float) {
  #(m.cam.x +. sx /. m.cam.z, m.cam.y +. sy /. m.cam.z)
}

fn zoom_at(m: Model, factor: Float, sx: Float, sy: Float) -> Model {
  let z = float.clamp(m.cam.z *. factor, 0.08, 4.0)
  let #(wx, wy) = to_world(m, sx, sy)
  Model(..m, cam: Cam(wx -. sx /. z, wy -. sy /. z, z), goal: None)
}

fn content_bounds(m: Model) -> #(Float, Float, Float, Float) {
  let grow = fn(b: #(Float, Float, Float, Float), x, y, w, h) {
    #(
      float.min(b.0, x),
      float.min(b.1, y),
      float.max(b.2, x +. w),
      float.max(b.3, y +. h),
    )
  }
  case m.view {
    // the working file and the files brought up beside it, so the code is
    // readable; files that fade in may land just outside (Ctrl+wheel)
    "code" -> {
      let shown =
        list.filter(m.panels, fn(pn) {
          pn.id == "code" || list.contains(m.pinned, pn.path)
        })
      case shown {
        [first, ..] ->
          list.fold(
            shown,
            #(first.x, first.y, first.x +. first.w, first.y +. first.h),
            fn(b, pn) { grow(b, pn.x, pn.y, pn.w, pn.h) },
          )
        [] -> #(0.0, 0.0, 0.0, 0.0)
      }
    }
    _ -> {
      let b = graph.bounds(shown_graph(m), m.target)
      let b =
        list.fold(m.panels, b, fn(b, pn) { grow(b, pn.x, pn.y, pn.w, pn.h) })
      list.fold(live_probes(m), b, fn(b, pr) {
        grow(b, pr.x, pr.y, probe_w, probe_height(m, pr))
      })
    }
  }
}

fn frame_rect(
  m: Model,
  b: #(Float, Float, Float, Float),
  animate: Bool,
  max_z: Float,
) -> Model {
  let #(x0, y0, x1, y1) = b
  let pad = 60.0
  let z =
    float.min(
      { m.w -. 2.0 *. pad } /. float.max(x1 -. x0, 1.0),
      { m.h -. 2.0 *. pad -. 50.0 } /. float.max(y1 -. y0, 1.0),
    )
    |> float.clamp(0.08, max_z)
  let cam =
    Cam(
      { x0 +. x1 } /. 2.0 -. m.w /. 2.0 /. z,
      { y0 +. y1 } /. 2.0 -. { m.h +. 50.0 } /. 2.0 /. z,
      z,
    )
  case animate && !m.reduced {
    True -> Model(..m, goal: Some(cam))
    False -> Model(..m, cam: cam, goal: None)
  }
}

fn fit(m: Model, animate: Bool) -> Model {
  frame_rect(m, content_bounds(m), animate, 1.2)
}

// ---------------------------------------------------------------- hit testing

fn node_at(m: Model, wx: Float, wy: Float) -> Option(#(GNode, Float, Float)) {
  list.reverse(m.graph.nodes)
  |> list.filter(fn(n) { m.view == "types" && shown(m, n.id) })
  |> list.find_map(fn(n) {
    let #(x, y) = result_or(dict.get(m.pos, n.id), #(0.0, 0.0))
    case
      wx >=. x
      && wx <=. x +. graph.node_w
      && wy >=. y
      && wy <=. y +. graph.node_h(n)
    {
      True -> Ok(#(n, x, y))
      False -> Error(Nil)
    }
  })
  |> option.from_result
}

fn row_at(n: GNode, y: Float, wy: Float) -> Option(String) {
  let i = float.truncate({ wy -. y -. graph.head_h } /. graph.row_h)
  case wy >. y +. graph.head_h, list.drop(n.rows, i) {
    True, [r, ..] -> Some(r.name)
    _, _ -> None
  }
}

// ---------------------------------------------------------------- events

fn frame(m: Model, t: Float) -> Model {
  let m = Model(..m, t: t)
  let pos =
    dict.map_values(m.target, fn(id, g) {
      case dict.get(m.pos, id) {
        Ok(#(x, y)) -> {
          let nx = x +. { g.0 -. x } *. 0.2
          let ny = y +. { g.1 -. y } *. 0.2
          case
            float.absolute_value(g.0 -. nx) +. float.absolute_value(g.1 -. ny)
            <. 0.6
          {
            True -> g
            False -> #(nx, ny)
          }
        }
        Error(_) -> g
      }
    })
  let m = Model(..m, pos: pos)
  case m.glide {
    Some(#(a, b, t0, ms)) -> {
      let k = float.clamp({ t -. t0 } /. ms, 0.0, 1.0)
      // ease in and out: slow start, quick middle, gentle landing
      let e = case k <. 0.5 {
        True -> 4.0 *. k *. k *. k
        False -> {
          let u = -2.0 *. k +. 2.0
          1.0 -. u *. u *. u /. 2.0
        }
      }
      let cam =
        Cam(
          a.x +. { b.x -. a.x } *. e,
          a.y +. { b.y -. a.y } *. e,
          a.z +. { b.z -. a.z } *. e,
        )
      case k >=. 1.0 {
        False -> Model(..m, cam: cam)
        True -> arrive(Model(..m, cam: b, glide: None))
      }
    }
    None -> frame_goal(m)
  }
}

const glide_ms = 700.0

/// The glide has landed: do what was waiting for it.
fn arrive(m: Model) -> Model {
  case m.pending {
    Some(f) -> f(Model(..m, pending: None))
    None -> m
  }
}

/// Start a glide to a camera. With reduced motion it is shorter, but it is
/// still a glide: a jump to another file loses track of where you went.
fn glide_to(m: Model, cam: Cam) -> Model {
  let ms = case m.reduced {
    True -> 320.0
    False -> glide_ms
  }
  Model(..m, goal: None, glide: Some(#(m.cam, cam, now(), ms)))
}

fn frame_goal(m: Model) -> Model {
  case m.goal {
    None -> m
    Some(g) -> {
      let k = 0.22
      let c = m.cam
      let nz = c.z +. { g.z -. c.z } *. k
      let nx = c.x +. { g.x -. c.x } *. k
      let ny = c.y +. { g.y -. c.y } *. k
      case
        float.absolute_value(g.z -. nz) <. 0.001
        && float.absolute_value(g.x -. nx) <. 0.5
      {
        True -> Model(..m, cam: g, goal: None)
        False -> Model(..m, cam: Cam(nx, ny, nz))
      }
    }
  }
}

fn down(
  m: Model,
  sx: Float,
  sy: Float,
  button: Int,
  target: String,
  _shift: Bool,
) -> Model {
  let #(wx, wy) = to_world(m, sx, sy)
  let m = case m.glide {
    Some(_) -> arrive(Model(..m, glide: None))
    None -> m
  }
  let m = Model(..m, mouse: #(sx, sy), goal: None)
  case target, button {
    "", 0 ->
      case node_at(m, wx, wy) {
        Some(#(n, x, y)) ->
          Model(
            ..m,
            selected: Some(n.id),
            drag: MoveNode(n.id, wx -. x, wy -. y, sx, sy, False),
          )
        None -> Model(..m, drag: Pan(sx, sy, m.cam.x, m.cam.y, False))
      }
    "", _ -> Model(..m, drag: Pan(sx, sy, m.cam.x, m.cam.y, False))
    id, _ -> {
      let #(x, y) = panel_xy(m, id)
      let pinned = case id {
        "f:" <> path -> [path, ..list.filter(m.pinned, fn(q) { q != path })]
        _ -> m.pinned
      }
      Model(..m, pinned: pinned, drag: MovePanel(id, wx -. x, wy -. y))
    }
  }
}

fn panel_xy(m: Model, id: String) -> #(Float, Float) {
  case list.find(m.panels, fn(p) { p.id == id }) {
    Ok(p) -> #(p.x, p.y)
    Error(_) ->
      case list.find(m.probes, fn(p) { p.id == id }) {
        Ok(p) -> #(p.x, p.y)
        Error(_) -> #(0.0, 0.0)
      }
  }
}

fn move(m: Model, sx: Float, sy: Float) -> Model {
  let #(wx, wy) = to_world(m, sx, sy)
  let m = Model(..m, mouse: #(sx, sy))
  case m.drag {
    NoDrag -> {
      let hover = case node_at(m, wx, wy) {
        Some(#(n, _, y)) ->
          case row_at(n, y, wy), m.cam.z <. 0.3 {
            Some(r), False -> Some(#(n.id, r))
            _, _ -> Some(#(n.id, ""))
          }
        None -> None
      }
      Model(..m, hover: hover)
    }
    Pan(x0, y0, cx, cy, _) ->
      Model(
        ..m,
        cam: Cam(
          cx -. { sx -. x0 } /. m.cam.z,
          cy -. { sy -. y0 } /. m.cam.z,
          m.cam.z,
        ),
        drag: Pan(
          x0,
          y0,
          cx,
          cy,
          float.absolute_value(sx -. x0) +. float.absolute_value(sy -. y0)
            >. 3.0,
        ),
      )
    MoveNode(id, dx, dy, x0, y0, moved) -> {
      let moved =
        moved
        || float.absolute_value(sx -. x0) +. float.absolute_value(sy -. y0)
        >. 4.0
      case moved {
        False -> m
        True -> {
          let p = #(wx -. dx, wy -. dy)
          Model(
            ..m,
            pos: dict.insert(m.pos, id, p),
            target: dict.insert(m.target, id, p),
            moved: dict.insert(m.moved, id, p),
            drag: MoveNode(id, dx, dy, x0, y0, True),
          )
        }
      }
    }
    MovePanel(id, dx, dy) -> {
      let p = #(wx -. dx, wy -. dy)
      Model(
        ..m,
        moved: dict.insert(m.moved, "panel:" <> id, p),
        panels: list.map(m.panels, fn(pn) {
          case pn.id == id {
            True -> Panel(..pn, x: p.0, y: p.1)
            False -> pn
          }
        }),
        probes: list.map(m.probes, fn(pr) {
          case pr.id == id {
            True -> Probe(..pr, x: p.0, y: p.1)
            False -> pr
          }
        }),
      )
    }
  }
}

fn up(m: Model, _sx: Float, _sy: Float) -> Model {
  case m.drag {
    Pan(_, _, _, _, False) -> Model(..m, drag: NoDrag, selected: None)
    MoveNode(id, _, _, _, _, False) -> focus_on(Model(..m, drag: NoDrag), id)
    _ -> Model(..m, drag: NoDrag)
  }
}

/// The canvas never scrolls: the wheel zooms it with Ctrl held, and
/// otherwise does nothing here (over a pane, the pane scrolls itself).
fn wheel(
  m: Model,
  _dx: Float,
  dy: Float,
  sx: Float,
  sy: Float,
  zoom: Bool,
) -> Model {
  case zoom {
    True ->
      zoom_at(m, exp(0.0 -. float.clamp(dy, -120.0, 120.0) *. 0.0025), sx, sy)
    False -> m
  }
}

fn key(m: Model, k: String) -> Model {
  case k {
    "f" | "F" -> fit(m, True)
    "+" | "=" -> zoom_at(m, 1.25, m.w /. 2.0, m.h /. 2.0)
    "-" | "_" -> zoom_at(m, 0.8, m.w /. 2.0, m.h /. 2.0)
    "0" -> zoom_at(m, 1.0 /. m.cam.z, m.w /. 2.0, m.h /. 2.0)
    "p" | "P" -> command(m, "probe")
    "Escape" ->
      case m.focus {
        Some(_) -> unfocus(Model(..m, selected: None))
        None -> Model(..m, selected: None)
      }
    "1" | "2" | "3" | "4" | "5" ->
      set_level_count(m, result_or(int.parse(k), m.levels))
    _ -> m
  }
}

fn edit(m: Model, id: String, body: String) -> Model {
  let m = Model(..m, dirty: list.filter(m.dirty, fn(d) { d != id_path(m, id) }))
  case id {
    "code" -> {
      let m =
        Model(..m, files: dict.insert(m.files, m.main, body))
        |> keep_if_new(m.main)
      case m.autocompile {
        True -> rebuild(m) |> place
        False -> place(m)
      }
    }
    "f:" <> path -> {
      let m =
        Model(..m, files: dict.insert(m.files, path, body))
        |> keep_if_new(path)
      case m.autocompile {
        True -> compile(m, path) |> compile(m.main) |> place
        False -> place(m)
      }
    }
    _ -> {
      let probes =
        list.map(m.probes, fn(pr) {
          case pr.id == id {
            True -> run_probe(m, Probe(..pr, text: body))
            False -> pr
          }
        })
      Model(..m, probes: probes)
    }
  }
}

fn command(m: Model, name: String) -> Model {
  case name {
    "fit" -> fit(m, True)
    "zoom_in" -> zoom_at(m, 1.25, m.w /. 2.0, m.h /. 2.0)
    "zoom_out" -> zoom_at(m, 0.8, m.w /. 2.0, m.h /. 2.0)
    "theme" -> Model(..m, dark: !m.dark)
    "svg" -> {
      download(
        string.replace(program.display_path(m.main), ".sheaf", "")
          <> "-dataflow.svg",
        graph.to_svg(shown_graph(m), m.pos, program.display_path(m.main)),
      )
      m
    }
    "probe" ->
      case
        case m.selected {
          Some(t) -> Some(t)
          None ->
            case dict.get(m.picked, m.main) {
              Ok(n) -> line_subject(m, n)
              Error(_) -> None
            }
        }
      {
        Some(t) -> {
          let pr =
            Probe("probe" <> int.to_string(m.next_id), t, "", 0.0, 0.0, None)
          let m =
            Model(
              ..m,
              probes: list.append(m.probes, [run_probe(m, pr)]),
              next_id: m.next_id + 1,
              probes_on: True,
            )
          place(m)
        }
        None -> m
      }
    "dbl:" <> rest ->
      case string.split(rest, ":") {
        [xs, ys] ->
          case float.parse(xs), float.parse(ys), int.parse(xs), int.parse(ys) {
            Ok(sx), Ok(sy), _, _ -> zoom_into(m, sx, sy)
            _, _, Ok(sx), Ok(sy) ->
              zoom_into(m, int.to_float(sx), int.to_float(sy))
            _, _, _, _ -> m
          }
        _ -> m
      }
    "open:" <> path -> switch_to(m, path)
    "new:" <> name -> new_file(m, name)
    "unfocus" -> unfocus(m)
    "focus:" <> id ->
      case list.any(m.graph.nodes, fn(n) { n.id == id }) {
        True -> focus_on(m, id)
        False -> m
      }
    "levels:+1" -> set_level_count(m, m.levels + 1)
    "levels:-1" -> set_level_count(m, m.levels - 1)
    "codeline:" <> rest -> {
      let #(line, y) = case string.split(rest, ":") {
        [a, b] -> #(
          result_or(int.parse(a), 0),
          result_or(float.parse(b), int.to_float(result_or(int.parse(b), 0))),
        )
        [a] -> #(result_or(int.parse(a), 0), 0.0)
        _ -> #(0, 0.0)
      }
      case line > 0 {
        False -> Model(..m, code_line: 0, code_hover: None, peek_t: now())
        True -> {
          let peeks = peeks_for(m, line)
          let fresh =
            list.filter_map(peeks, fn(pk) {
              case pk.outside && !list.contains(m.strangers, pk.path) {
                True -> Ok(pk.path)
                False -> Error(Nil)
              }
            })
          let m =
            Model(
              ..m,
              code_line: line,
              code_y: y,
              code_hover: line_target(m, line),
              peeks: case peeks {
                [] -> m.peeks
                _ -> peeks
              },
              peek_t: case peeks {
                [] -> m.peek_t
                _ -> now()
              },
              strangers: list.append(m.strangers, fresh),
            )
          case fresh {
            [] -> m
            _ -> place(m)
          }
        }
      }
    }
    "compile:" <> id -> {
      let path = case id {
        "code" -> m.main
        "f:" <> path -> path
        _ -> ""
      }
      case path {
        "" -> m
        _ -> {
          let m = compile(m, path) |> commit(path)
          let st = case path == m.main {
            True -> status_raw(m, path)
            False -> file_state(m, path)
          }
          case st {
            Compiled | Proved ->
              Model(..m, editing: list.filter(m.editing, fn(e) { e != id }))
            _ -> m
          }
        }
      }
    }
    "edit:" <> id ->
      case is_locked(m, id_path(m, id)) {
        True -> m
        False ->
          Model(..m, editing: [id, ..list.filter(m.editing, fn(e) { e != id })])
      }
    "explore:" <> id ->
      Model(..m, editing: list.filter(m.editing, fn(e) { e != id }))
    "goto:" <> rest ->
      case split_link(rest) {
        Ok(#(t, id, ln)) -> {
          let from_path = case id_path(m, id) {
            "" -> m.main
            q -> q
          }
          goto(m, t, {
            let line = result_or(int.parse(ln), 1)
            Loc(m.main, from_path, line, line_label(m, from_path, line))
          })
        }
        Error(_) -> goto(m, rest, here(m))
      }
    "back" -> go_back(m)
    "search:" <> q -> Model(..m, search_q: q, hits: search(m, q))
    "searchgo:" <> ix ->
      case list.drop(m.hits, result_or(int.parse(ix), 0)) {
        [h, ..] ->
          jump(
            Model(..m, search_q: "", hits: []),
            h.path,
            h.line,
            False,
            h.label,
            here(m),
          )
        [] -> m
      }
    "pick:" <> rest ->
      // the id may hold a colon (f:/path), so the line is after the last one
      case split_last(rest) {
        Ok(#(id, ln)) ->
          case id_path(m, id), int.parse(ln) {
            "", _ | _, Error(_) -> m
            path, Ok(n) -> {
              let m = Model(..m, picked: dict.insert(m.picked, path, n))
              case id {
                // a line picked in a file beside the working one centres
                // that file, as following a link would
                "f:" <> _ ->
                  jump(
                    m,
                    path,
                    n,
                    list.contains(m.strangers, path),
                    line_label(m, path, n),
                    here(m),
                  )
                _ -> m
              }
            }
          }
        Error(_) -> m
      }
    "lock:" <> path -> lock_toggle(m, path)
    "cardgo:" <> rest ->
      case split_link(rest) {
        Ok(#(t, id, ln)) -> {
          let from_path = case id_path(m, id) {
            "" -> m.main
            q -> q
          }
          goto(m, t, {
            let line = result_or(int.parse(ln), 1)
            Loc(m.main, from_path, line, line_label(m, from_path, line))
          })
        }
        Error(_) -> m
      }
    "forward" -> go_forward(m)
    "dirty:" <> id -> {
      let path = id_path(m, id)
      case path == "" || list.contains(m.dirty, path) {
        True -> m
        False -> Model(..m, dirty: [path, ..m.dirty])
      }
    }
    "hovertype:" <> rest ->
      case string.split(rest, ":") {
        [t, x, y] ->
          Model(..m, hover_type: t, hover_at: #(
            result_or(float.parse(x), int.to_float(result_or(int.parse(x), 0))),
            result_or(float.parse(y), int.to_float(result_or(int.parse(y), 0))),
          ))
        [t] -> Model(..m, hover_type: t)
        _ -> Model(..m, hover_type: "")
      }
    "unpin:" <> path -> close_pane(m, path)
    "rmprobe:" <> id ->
      Model(..m, probes: list.filter(m.probes, fn(pr) { pr.id != id }))
      |> place
    "probes" -> Model(..m, probes_on: !m.probes_on) |> place
    "over:" <> id -> Model(..m, over: id)
    "view:" <> v -> Model(..m, view: v, code_line: 0) |> place |> fit(True)
    "auto:on" -> {
      let m = Model(..m, autocompile: True)
      case status_raw(m, m.main) {
        Changed -> rebuild(m) |> place
        _ -> m
      }
    }
    "auto:off" -> Model(..m, autocompile: False)
    _ -> m
  }
}

/// Double-click: frame the node under the cursor, or zoom in on empty space.
fn zoom_into(m: Model, sx: Float, sy: Float) -> Model {
  let #(wx, wy) = to_world(m, sx, sy)
  case node_at(m, wx, wy) {
    Some(#(n, x, y)) -> {
      let extra = case has_grid(m, n.id) {
        True -> 220.0
        False -> 0.0
      }
      Model(
        ..frame_rect(
          m,
          #(
            x -. 60.0,
            y -. 30.0,
            x +. graph.node_w +. 60.0,
            y +. graph.node_h(n) +. 30.0 +. extra,
          ),
          True,
          2.6,
        ),
        selected: Some(n.id),
      )
    }
    None -> {
      let z = float.min(m.cam.z *. 1.6, 4.0)
      let cam = Cam(wx -. sx /. z, wy -. sy /. z, z)
      case m.reduced {
        True -> Model(..m, cam: cam)
        False -> Model(..m, goal: Some(cam))
      }
    }
  }
}

fn resize(m: Model, w: Float, h: Float) -> Model {
  Model(..m, w: w, h: h)
}

// ---------------------------------------------------------------- colours and type

type Pal {
  Pal(
    bg: String,
    grid: String,
    node: String,
    ext: String,
    head: String,
    ink: String,
    muted: String,
    line: String,
    accent: String,
    stored: String,
    computed: String,
    mapping: String,
    rule: String,
    bad: String,
    good: String,
    sel: String,
    stroke: String,
    faint: String,
    st_core: String,
    st_compiled: String,
    st_proved: String,
    st_changed: String,
    st_affected: String,
    st_errors: String,
    st_outside: String,
    cells: List(String),
  )
}

fn pal(dark: Bool) -> Pal {
  case dark {
    False ->
      Pal(
        bg: "#e6ebf0",
        grid: "#c3ccd6",
        node: "#fbfcfd",
        ext: "#eef2f5",
        head: "#f1f4f7",
        ink: "#18212c",
        muted: "#5d6b7a",
        line: "#8d9aa8",
        accent: "#2b59c3",
        stored: "#3f8f9b",
        computed: "#4a8a4f",
        mapping: "#7a5cc2",
        rule: "#b47a12",
        bad: "#c03a33",
        good: "#2f7d4f",
        sel: "#2b59c3",
        stroke: "#cfd7df",
        faint: "rgba(43, 89, 195, 0.42)",
        st_core: "#2b6cc4",
        st_compiled: "#2f8a4f",
        st_proved: "#7a4fc2",
        st_changed: "#b98a00",
        st_affected: "#d4691a",
        st_errors: "#c03a33",
        st_outside: "#8d9aa8",
        cells: [
          "#8fb3e6",
          "#f0b46a",
          "#9fd3a8",
          "#d8a4e0",
          "#f4dd7c",
          "#a6dbe0",
          "#e9a3a0",
          "#c7c0f2",
        ],
      )
    True ->
      Pal(
        bg: "#11161c",
        grid: "#26303b",
        node: "#19212a",
        ext: "#151c23",
        head: "#1e2731",
        ink: "#e3e9ef",
        muted: "#93a1b0",
        line: "#5c6a79",
        accent: "#7aa5f0",
        stored: "#62b6c2",
        computed: "#77bf7c",
        mapping: "#a990e6",
        rule: "#e0a53a",
        bad: "#f07a72",
        good: "#6fcf97",
        sel: "#7aa5f0",
        stroke: "#2c3743",
        faint: "rgba(122, 165, 240, 0.45)",
        st_core: "#6fa3f0",
        st_compiled: "#5cc98a",
        st_proved: "#b28cf0",
        st_changed: "#e6c440",
        st_affected: "#f0975a",
        st_errors: "#f07a72",
        st_outside: "#6c7a89",
        cells: [
          "#3f6fb5",
          "#b9772a",
          "#3f8f57",
          "#8a52a0",
          "#a8902c",
          "#2f8a94",
          "#a5504b",
          "#6458b0",
        ],
      )
  }
}

const sans = "\"IBM Plex Sans\", system-ui, sans-serif"

const mono = "\"IBM Plex Mono\", ui-monospace, Menlo, monospace"

fn role_color(p: Pal, role: String) -> String {
  case role {
    "stored" | "item" | "base" | "position" -> p.stored
    "computed" -> p.computed
    "mapping" -> p.mapping
    _ -> p.rule
  }
}

// ---------------------------------------------------------------- live values

/// Field values of the first probe of each type, shown on that type's rows.
fn live_values(m: Model) -> Dict(String, Dict(String, Val)) {
  list.fold(live_probes(m), dict.new(), fn(acc, pr) {
    case dict.has_key(acc, pr.type_name), pr.outcome, m.program {
      False, Some(o), Some(p) ->
        case o.value {
          Some(VRecord(r)) ->
            dict.insert(
              acc,
              pr.type_name,
              list.fold(r.decl.fields, dict.new(), fn(d, f) {
                dict.insert(d, f.name, evaluate.get(p.ev, r, f.name))
              }),
            )
          _ -> acc
        }
      _, _, _ -> acc
    }
  })
}

fn short(v: Val) -> String {
  case v {
    VSeqv(items, _, _) -> int.to_string(list.length(items)) <> " items"
    VRecord(r) -> r.decl.name
    VText(s) ->
      case string.length(s) > 18 {
        True -> evaluate.show(VText(string.slice(s, 0, 16))) <> "…"
        False -> evaluate.show(v)
      }
    _ -> evaluate.show(v)
  }
}

fn probe_rows(m: Model, pr: Probe) -> List(#(String, String, String)) {
  case pr.outcome, m.program {
    Some(o), Some(p) ->
      case o.value {
        Some(VRecord(r)) ->
          list.map(r.decl.fields, fn(f) {
            let v = evaluate.get(p.ev, r, f.name)
            #(f.name, short(v), model.role_text(f.role))
          })
          |> list.append(
            list.map(list.take(o.failures, 4), fn(fl) { #("failed", fl, "bad") }),
          )
        Some(v) -> [#("value", short(v), "stored")]
        None -> [#("error", o.error, "bad")]
      }
    _, _ -> []
  }
}

fn has_grid(m: Model, id: String) -> Bool {
  dict.keys(m.grids) |> list.any(fn(k) { string.starts_with(k, id <> ".") })
}

// ---------------------------------------------------------------- drawing

fn bezier(t: Float, a: Float, b: Float, c: Float, d: Float) -> Float {
  let u = 1.0 -. t
  u
  *. u
  *. u
  *. a
  +. 3.0
  *. u
  *. u
  *. t
  *. b
  +. 3.0
  *. u
  *. t
  *. t
  *. c
  +. t
  *. t
  *. t
  *. d
}

fn view(m: Model, c: Ctx) -> Nil {
  let p = pal(m.dark)
  set_theme(c, m.dark)
  clear(c, p.bg)
  world(c, m.cam.x, m.cam.y, m.cam.z)
  // the drafting surface
  let step = case m.cam.z <. 0.35 {
    True -> 128.0
    False -> 32.0
  }
  let #(wx0, wy0) = to_world(m, 0.0, 0.0)
  let #(wx1, wy1) = to_world(m, m.w, m.h)
  dots(c, wx0, wy0, wx1, wy1, step, 1.1 /. m.cam.z, p.grid)
  let compact = m.cam.z <. 0.3
  case m.view {
    "code" -> draw_code_view(c, m, p)
    _ -> draw_types_view(c, m, p, compact)
  }
  // diagnostics under the code
  case list.find(m.panels, fn(pn) { pn.id == "code" }) {
    Ok(pn) -> draw_diagnostics(c, m, p, pn)
    Error(_) -> Nil
  }
  // probe outputs
  list.each(live_probes(m), fn(pr) { draw_probe(c, m, p, pr) })
  draw_panels(c, m)
  screen(c)
  hud(c, m)
}

fn draw_types_view(c: Ctx, m: Model, p: Pal, compact: Bool) -> Nil {
  let at = fn(id) { result_or(dict.get(m.pos, id), #(0.0, 0.0)) }
  let node_by = fn(id) { list.find(m.graph.nodes, fn(n) { n.id == id }) }
  // rings around the focused type: faint guides, no wires
  case m.focus {
    Some(_) -> {
      let #(ox, oy, radii) = m.orbit
      list.each(radii, fn(r) { circle(c, ox, oy, r, "", p.stroke, 1.0) })
    }
    None -> Nil
  }
  // relations appear only for the hovered line
  let related = case hov(m) {
    Some(#(hid, hrow)) -> draw_relations(c, m, p, hid, hrow, compact)
    None -> []
  }
  // nodes
  let values = live_values(m)
  list.each(m.graph.nodes, fn(n) {
    case shown(m, n.id) {
      True ->
        draw_node(
          c,
          m,
          p,
          n,
          at(n.id),
          compact,
          values,
          list.contains(related, n.id),
        )
      False -> Nil
    }
  })
  // mapping tables beneath their records
  case compact {
    True -> Nil
    False ->
      dict.each(m.grids, fn(k, grid) {
        case string.split_once(k, ".") {
          Ok(#(t, field)) if m.focus == None || m.focus == Some(t) -> {
            let #(x, y) = at(t)
            let below =
              dict.keys(m.grids)
              |> list.filter(fn(k2) {
                string.starts_with(k2, t <> ".")
                && string.compare(k2, k) == order.Lt
              })
              |> list.length
            case node_by(t) {
              Ok(n) ->
                draw_grid(
                  c,
                  m,
                  p,
                  t,
                  field,
                  grid,
                  x,
                  y +. graph.node_h(n) +. 18.0 +. int.to_float(below) *. 200.0,
                  values,
                )
              Error(_) -> Nil
            }
          }
          _ -> Nil
        }
      })
  }
  // the chain a hovered type reduces to, above it
  case hov(m) {
    Some(#(id, "")) ->
      case node_by(id) {
        Ok(_) -> {
          let #(x, y) = at(id)
          draw_chain(c, p, x, y -. 34.0, chain(m, id))
        }
        Error(_) -> Nil
      }
    _ -> Nil
  }
}

/// Is a file panel showing: pinned, or named by the hovered line (and for a
/// moment after), or under the pointer.
fn file_visible(m: Model, path: String) -> Bool {
  list.contains(m.pinned, path)
  || {
    list.any(m.peeks, fn(pk) { pk.path == path })
    && {
      m.code_line > 0 || now() -. m.peek_t <. 1400.0 || m.over == "f:" <> path
    }
  }
}

fn file_status(m: Model, path: String) -> Status {
  case
    list.contains(m.strangers, path)
    || list.any(m.peeks, fn(pk) { pk.path == path && pk.outside })
  {
    True -> Outside
    False -> file_state(m, path)
  }
}

/// The hovered line's wires to the lines that declare its types, and the
/// chain its type reduces to.
fn draw_code_view(c: Ctx, m: Model, p: Pal) -> Nil {
  case m.code_line > 0, list.find(m.panels, fn(pn) { pn.id == "code" }) {
    True, Ok(main) -> {
      let sy = main.y +. m.code_y
      list.each(m.peeks, fn(pk) {
        case
          list.find(m.panels, fn(pn) { pn.path == pk.path && pn.id != "code" })
        {
          Ok(pn) -> {
            let row = 0
            let ey = pn.y +. 35.0 +. 10.0 +. int.to_float(row) *. 17.0 +. 9.0
            let stacked = pn.x <. main.x +. main.w && pn.x +. pn.w >. main.x
            let right = pn.x +. pn.w /. 2.0 >. main.x +. main.w /. 2.0
            let #(sx, c1, c2, ex) = case stacked, right {
              True, _ -> {
                let side = float.max(main.x +. main.w, pn.x +. pn.w)
                let d = 50.0 +. float.absolute_value(ey -. sy) /. 8.0
                #(main.x +. main.w, side +. d, side +. d, pn.x +. pn.w +. 5.0)
              }
              False, True -> {
                let sx = main.x +. main.w
                let ex = pn.x -. 5.0
                let d = float.max(60.0, { ex -. sx } /. 2.0)
                #(sx, sx +. d, ex -. d, ex)
              }
              False, False -> {
                let sx = main.x
                let ex = pn.x +. pn.w +. 5.0
                let d = float.max(60.0, { sx -. ex } /. 2.0)
                #(sx, sx -. d, ex +. d, ex)
              }
            }
            let st = file_status(m, pk.path)
            let color = status_color(p, st)
            curve(
              c,
              sx,
              sy,
              c1,
              sy,
              c2,
              ey,
              ex,
              ey,
              color,
              1.4,
              case st {
                Outside -> 6.0
                _ -> 0.0
              },
              0.0,
            )
            arrow(c, ex, ey, atan2(0.0, ex -. c2), 7.0, color)
          }
          Error(_) -> Nil
        }
      })
      let subject = case m.hover_type {
        "" -> line_subject(m, m.code_line)
        t -> Some(t)
      }
      case subject {
        Some(t) -> {
          let steps = chain(m, t)
          draw_chain(
            c,
            p,
            main.x +. main.w -. chain_w(steps),
            main.y -. 32.0,
            steps,
          )
        }
        None -> Nil
      }
    }
    _, _ -> Nil
  }
}

fn chain_w(steps: List(#(String, Status))) -> Float {
  let chars =
    list.fold(steps, 0, fn(acc, s) { acc + string.length(s.0) })
    + 3
    * { list.length(steps) - 1 }
  int.to_float(chars) *. 7.3 +. 20.0
}

/// A chain as a chip: each step in its file's colour, joined by arrows.
fn draw_chain(
  c: Ctx,
  p: Pal,
  x: Float,
  y: Float,
  steps: List(#(String, Status)),
) -> Nil {
  case steps {
    [] | [_] -> Nil
    _ -> {
      let cw = 7.3
      let labels = list.map(steps, fn(s) { s.0 })
      let chars =
        list.fold(labels, 0, fn(acc, l) { acc + string.length(l) })
        + 3
        * { list.length(labels) - 1 }
      let w = int.to_float(chars) *. cw +. 20.0
      rect(c, x, y, w, 24.0, 6.0, p.node, p.stroke, 1.0, 0.0)
      list.index_fold(steps, x +. 10.0, fn(cx, s, i) {
        let cx = case i {
          0 -> cx
          _ -> {
            text(c, cx, y +. 16.5, " → ", "12px " <> mono, p.muted, "left", 0.0)
            cx +. 3.0 *. cw
          }
        }
        let color = case s.0 {
          "record" -> p.muted
          _ -> status_color(p, s.1)
        }
        text(c, cx, y +. 16.5, s.0, "600 12px " <> mono, color, "left", 0.0)
        cx +. int.to_float(string.length(s.0)) *. cw
      })
      Nil
    }
  }
}

/// Every DOM panel: files with their colour and Compile button, then probes.
fn draw_panels(c: Ctx, m: Model) -> Nil {
  list.each(m.panels, fn(pn) {
    case pn.id {
      "code" -> {
        let st = file_state(m, m.main)
        let locked = is_locked(m, m.main)
        let label = case st, m.error {
          _, e if e != "" -> "does not parse"
          Compiled, _ | Proved, _ ->
            status_text(st)
            <> " · "
            <> int.to_string(float.round(m.check_ms))
            <> " ms"
          _, _ -> status_text(st)
        }
        let st = case m.error {
          "" -> st
          _ -> Errors(1)
        }
        panel(
          c,
          pn.id,
          "code",
          pn.x,
          pn.y,
          pn.w,
          pn.h,
          program.display_path(pn.path),
          file_text(m, pn.path),
          label,
          status_class(st),
          1.0,
          list.flatten([
            case m.back {
              [] -> []
              _ -> [#("←", "back")]
            },
            case m.fwd {
              [] -> []
              _ -> [#("→", "forward")]
            },
            lock_button(m, m.main),
            [#("Compile", "compile:code"), #("×", "unpin:" <> m.main)],
          ]),
          result_or(dict.get(m.marks, m.main), 0),
          locked,
          list.contains(m.editing, "code") && !locked,
          link_names(m),
          notes_for(m, m.main),
        )
      }
      _ -> {
        let st = file_status(m, pn.path)
        let shown = file_visible(m, pn.path)
        let pinned = list.contains(m.pinned, pn.path)
        let locked = is_locked(m, pn.path)
        let buttons = case st, is_prelude(pn.path) {
          Outside, _ | _, True -> []
          _, False ->
            list.append(lock_button(m, pn.path), [
              #("Compile", "compile:" <> pn.id),
            ])
        }
        let buttons = list.append(buttons, [#("×", "unpin:" <> pn.path)])
        let scroll = case pinned {
          True -> result_or(dict.get(m.marks, pn.path), 0)
          False ->
            case list.find(m.peeks, fn(pk) { pk.path == pn.path }) {
              Ok(pk) -> pk.line
              Error(_) -> 0
            }
        }
        panel(
          c,
          pn.id,
          "file",
          pn.x,
          pn.y,
          pn.w,
          pn.h,
          program.display_path(pn.path),
          file_text(m, pn.path),
          status_text(st),
          status_class(st),
          case shown {
            True -> 1.0
            False -> 0.0
          },
          buttons,
          scroll,
          locked || st == Outside,
          list.contains(m.editing, pn.id) && !locked && st != Outside,
          link_names(m),
          notes_for(m, pn.path),
        )
      }
    }
  })
  list.each(live_probes(m), fn(pr) {
    let #(st, cls) = case pr.outcome {
      Some(o) ->
        case o.ok {
          True -> #("inhabits " <> pr.type_name, "compiled")
          False -> #("does not inhabit " <> pr.type_name, "errors")
        }
      None -> #("waiting for a clean compile", "changed")
    }
    panel(
      c,
      pr.id,
      "probe",
      pr.x,
      pr.y,
      probe_w,
      probe_text_h(pr),
      "Text for " <> pr.type_name,
      pr.text,
      st,
      cls,
      1.0,
      [#("×", "rmprobe:" <> pr.id)],
      0,
      False,
      True,
      [],
      [],
    )
  })
}

/// A lock toggle for a file; language.sheaf has none, it is always locked.
fn lock_button(m: Model, path: String) -> List(#(String, String)) {
  case is_prelude(path), is_locked(m, path) {
    True, _ -> []
    _, True -> [#("Unlock", "lock:" <> path)]
    _, False -> [#("Lock", "lock:" <> path)]
  }
}

/// Probes whose type the working file can see; the others wait, hidden.
fn live_probes(m: Model) -> List(Probe) {
  case m.probes_on {
    False -> []
    True -> live_probes_all(m)
  }
}

fn live_probes_all(m: Model) -> List(Probe) {
  case m.program {
    Some(p) ->
      list.filter(m.probes, fn(pr) {
        dict.has_key(p.decls, pr.type_name)
        || list.contains(model.builtin_numeric, pr.type_name)
      })
    None -> m.probes
  }
}

/// Markers for a file panel: the line a jump left, and the line it landed
/// on with a chip that goes back.
fn notes_for(m: Model, path: String) -> List(#(Int, String, String)) {
  let picked = case dict.get(m.picked, path) {
    Ok(n) -> [#(n, "sel", "")]
    Error(_) -> []
  }
  case m.came {
    None -> picked
    Some(#(from, dest)) -> {
      let left = case from.main == m.main && from.path == path {
        True -> [#(from.line, "from", "")]
        False -> []
      }
      let landed = case dest.main == m.main && dest.path == path {
        True -> {
          let label = case from.path == dest.path {
            True -> "↩ " <> from.label
            False -> "↩ " <> from.label <> " · " <> base_name(from.path)
          }
          [#(dest.line, "dest", label)]
        }
        False -> []
      }
      list.flatten([picked, left, landed])
    }
  }
}

/// The file and its folder, enough to tell two orders.sheaf files apart.
fn short_path(path: String) -> String {
  string.split(path, "/")
  |> list.reverse
  |> list.take(2)
  |> list.reverse
  |> string.join("/")
}

fn base_name(path: String) -> String {
  result_or(list.last(string.split(path, "/")), path)
}

/// The preview card for the hovered type: its declaration, in its file's colour.
fn draw_card(c: Ctx, m: Model) -> Nil {
  case m.hover_type, m.view {
    "", _ | _, "types" -> card(c, "", "", "", 0.0, 0.0, [])
    t, _ ->
      case find_decl(m, t) {
        None -> card(c, "", "", "", 0.0, 0.0, [])
        Some(#(path, line, outside)) -> {
          let st = case outside {
            True -> Outside
            False ->
              case path == m.main {
                True -> status_raw(m, path)
                False -> file_state(m, path)
              }
          }
          let chain_text =
            chain(m, t)
            |> list.map(fn(s) { s.0 })
            |> string.join(" → ")
          card(
            c,
            t
              <> "  ·  "
              <> program.display_path(path)
              <> ":"
              <> int.to_string(line)
              <> case string.contains(chain_text, "→") {
              True -> "  ·  " <> chain_text
              False -> ""
            },
            decl_text(m, path, line),
            status_class(st),
            m.hover_at.0,
            m.hover_at.1,
            link_names(m),
          )
        }
      }
  }
}

fn hud(c: Ctx, m: Model) -> Nil {
  draw_card(c, m)
  set_results(
    c,
    m.search_q,
    list.index_map(m.hits, fn(h, i) {
      #(
        h.kind,
        h.label,
        short_path(h.path) <> ":" <> int.to_string(h.line),
        status_class(file_state(m, h.path)),
        int.to_string(i),
      )
    }),
  )
  // a file reached by following links joins the list while it is the centre
  let items =
    list.append(
      list.map(presets(), fn(pr) { #(pr.0, pr.1) }),
      list.map(m.created, fn(p) { #(p, program.display_path(p) <> " (new)") }),
    )
  let items = case list.any(items, fn(it) { it.0 == m.main }) {
    True -> items
    False ->
      list.append(items, [
        #(m.main, program.display_path(m.main) <> " (followed)"),
      ])
  }
  set_files(c, items, m.main)
  set_mode(
    c,
    m.view,
    m.autocompile,
    m.levels,
    option.is_some(m.focus),
    m.probes_on,
  )
  let boot = case m.base {
    Ok(_) ->
      "language.sheaf parsed itself in "
      <> int.to_string(float.round(m.boot_ms))
      <> " ms"
    Error(e) -> "bootstrap failed: " <> e
  }
  status(
    c,
    boot
      <> "   ·   zoom "
      <> int.to_string(float.round(m.cam.z *. 100.0))
      <> "%",
  )
  let cur = case m.drag, hov(m) {
    Pan(..), _ -> "grabbing"
    MoveNode(..), _ | MovePanel(..), _ -> "grabbing"
    NoDrag, Some(_) -> "pointer"
    NoDrag, None -> "grab"
  }
  cursor(c, cur)
  draw_info(c, m)
}

/// Faint wires for one line: a row's relations to the types it names, its
/// data wires inside the record, or, for a type's header (row ""), every
/// relation into or out of the type and the texts checked against it.
/// Returns the types at the other ends, which are outlined.
fn draw_relations(
  c: Ctx,
  m: Model,
  p: Pal,
  hid: String,
  hrow: String,
  compact: Bool,
) -> List(String) {
  let at = fn(id) { result_or(dict.get(m.pos, id), #(0.0, 0.0)) }
  let node_by = fn(id) { list.find(m.graph.nodes, fn(n) { n.id == id }) }
  let link = fn(n: GNode, row: String, t: GNode, label: String) {
    let #(nx, ny) = at(n.id)
    let #(tx, ty) = at(t.id)
    let sy = case row == "" || compact {
      True -> ny +. graph.head_h /. 2.0
      False -> ny +. graph.row_y(n, row)
    }
    let ey = ty +. graph.head_h /. 2.0
    // a target straight above or below: a bracket down the right side;
    // otherwise leave from the side facing the target
    let stacked = float.absolute_value(tx -. nx) <. graph.node_w *. 0.8
    let #(sx, c1, c2, ex, mid_x) = case stacked, tx >=. nx {
      True, _ -> {
        let side = float.max(nx, tx) +. graph.node_w
        let d = 46.0 +. float.absolute_value(ey -. sy) /. 7.0
        #(
          nx +. graph.node_w,
          side +. d,
          side +. d,
          tx +. graph.node_w +. 5.0,
          side +. d *. 0.75,
        )
      }
      False, True -> {
        let sx = nx +. graph.node_w
        let ex = tx -. 5.0
        let d = float.max(50.0, { ex -. sx } /. 2.0)
        #(sx, sx +. d, ex -. d, ex, { sx +. ex } /. 2.0)
      }
      False, False -> {
        let sx = nx
        let ex = tx +. graph.node_w +. 5.0
        let d = float.max(50.0, { sx -. ex } /. 2.0)
        #(sx, sx -. d, ex +. d, ex, { sx +. ex } /. 2.0)
      }
    }
    curve(c, sx, sy, c1, sy, c2, ey, ex, ey, p.faint, 1.4, 0.0, 0.0)
    arrow(c, ex, ey, atan2(0.0, ex -. c2), 7.0, p.faint)
    case label {
      "" -> Nil
      _ ->
        text(
          c,
          mid_x,
          bezier(0.5, sy, sy, ey, ey) -. 5.0,
          label,
          "11px " <> sans,
          p.muted,
          case stacked {
            True -> "left"
            False -> "center"
          },
          120.0,
        )
    }
  }
  let ends =
    list.filter_map(m.graph.edges, fn(e) {
      case e {
        TypeWire(t, n, row, kind) ->
          case shown(m, t) && shown(m, n), node_by(n), node_by(t) {
            True, Ok(nn), Ok(tn) ->
              case
                n == hid && { hrow == "" || row == hrow },
                t == hid && hrow == ""
              {
                True, _ -> {
                  link(nn, row, tn, kind)
                  Ok(t)
                }
                _, True -> {
                  link(nn, row, tn, kind)
                  Ok(n)
                }
                _, _ -> Error(Nil)
              }
            _, _, _ -> Error(Nil)
          }
        DataWire(node, a, b) ->
          case
            node == hid && { hrow == "" || a == hrow || b == hrow },
            compact,
            node_by(node)
          {
            True, False, Ok(n) -> {
              let #(x, y) = at(node)
              let ya = y +. graph.row_y(n, a)
              let yb = y +. graph.row_y(n, b)
              let bulge = 24.0 +. float.absolute_value(yb -. ya) /. 5.0
              curve(
                c,
                x,
                ya,
                x -. bulge,
                ya,
                x -. bulge,
                yb,
                x -. 5.0,
                yb,
                p.faint,
                1.4,
                0.0,
                0.0,
              )
              arrow(c, x -. 5.0, yb, 0.0, 7.0, p.faint)
              Error(Nil)
            }
            _, _, _ -> Error(Nil)
          }
      }
    })
  // a type's header also shows the texts checked against it
  case hrow {
    "" ->
      list.each(live_probes(m), fn(pr) {
        case pr.type_name == hid {
          True -> {
            let #(ax, ay) = at(hid)
            let sx = ax +. graph.node_w
            let sy = ay +. graph.head_h /. 2.0
            let ey = pr.y +. 18.0
            let d = float.max(80.0, { pr.x -. sx } /. 2.0)
            curve(
              c,
              sx,
              sy,
              sx +. d,
              sy,
              pr.x -. d,
              ey,
              pr.x -. 5.0,
              ey,
              p.faint,
              1.4,
              0.0,
              0.0,
            )
            arrow(c, pr.x -. 5.0, ey, 0.0, 7.0, p.faint)
          }
          False -> Nil
        }
      })
    _ -> Nil
  }
  list.unique(ends)
}

fn plural(n: Int) -> String {
  case n {
    1 -> ""
    _ -> "s"
  }
}

fn draw_node(
  c: Ctx,
  m: Model,
  p: Pal,
  n: GNode,
  xy: #(Float, Float),
  compact: Bool,
  values: Dict(String, Dict(String, Val)),
  related: Bool,
) -> Nil {
  let #(x, y) = xy
  let selected = m.selected == Some(n.id)
  let h = case compact {
    True -> graph.head_h
    False -> graph.node_h(n)
  }
  let errored =
    list.any(check.errors(m.report), fn(d) {
      string.starts_with(d.where, n.id <> ".") || d.where == n.id
    })
  let lit = hov(m) == Some(#(n.id, ""))
  let outline = case selected, errored, related || lit {
    True, _, _ -> p.sel
    _, True, _ -> p.bad
    _, _, True -> p.faint
    _, _, _ -> p.stroke
  }
  let lw = case selected || errored, related || lit {
    True, _ -> 2.2
    _, True -> 1.8
    _, _ -> 1.0
  }
  let fill = case n.external {
    True -> p.ext
    False -> p.node
  }
  rect(c, x, y, graph.node_w, h, 10.0, fill, outline, lw, case n.external {
    True -> 5.0
    False -> 0.0
  })
  case compact {
    True ->
      text(
        c,
        x +. 14.0,
        y +. 24.0,
        n.id,
        "600 15px " <> sans,
        p.ink,
        "left",
        graph.node_w -. 28.0,
      )
    False -> {
      text(
        c,
        x +. 14.0,
        y +. 23.0,
        n.id,
        "600 14px " <> sans,
        p.ink,
        "left",
        graph.node_w -. 90.0,
      )
      text(
        c,
        x +. graph.node_w -. 16.0,
        y +. 22.0,
        case n.external {
          True -> "in scope"
          False -> n.kind
        },
        "12px " <> sans,
        p.muted,
        "right",
        80.0,
      )
      let vals = result_or(dict.get(values, n.id), dict.new())
      list.index_map(n.rows, fn(r, i) {
        let ry = y +. graph.head_h +. int.to_float(i) *. graph.row_h
        let hovered = hov(m) == Some(#(n.id, r.name))
        case hovered {
          True ->
            rect(
              c,
              x +. 2.0,
              ry,
              graph.node_w -. 4.0,
              graph.row_h,
              4.0,
              p.head,
              "",
              0.0,
              0.0,
            )
          False -> Nil
        }
        rect(
          c,
          x +. 8.0,
          ry +. 5.0,
          4.0,
          14.0,
          2.0,
          role_color(p, r.role),
          "",
          0.0,
          0.0,
        )
        let v = dict.get(vals, r.name)
        let label_w = case v {
          Ok(_) -> graph.node_w -. 120.0
          Error(_) -> graph.node_w -. 34.0
        }
        text(
          c,
          x +. 20.0,
          ry +. 16.5,
          r.label,
          "12px " <> mono,
          p.ink,
          "left",
          label_w,
        )
        case v {
          Ok(val) -> {
            let color = case val {
              VInvalid -> p.bad
              _ -> p.accent
            }
            text(
              c,
              x +. graph.node_w -. 12.0,
              ry +. 16.5,
              short(val),
              "600 12px " <> mono,
              color,
              "right",
              96.0,
            )
          }
          Error(_) -> Nil
        }
        circle(c, x, ry +. graph.row_h /. 2.0 +. 2.0, 3.4, p.node, p.line, 1.3)
      })
      Nil
    }
  }
  circle(c, x +. graph.node_w, y +. graph.head_h /. 2.0, 4.6, p.accent, "", 0.0)
}

fn val_label(v: Val) -> String {
  case v {
    VNumber(d) -> decimal.to_short(d)
    VText(s) ->
      case s {
        "TRUE" | "FALSE" -> s
        _ -> model.quote(s)
      }
    _ -> evaluate.show(v)
  }
}

fn draw_grid(
  c: Ctx,
  m: Model,
  p: Pal,
  t: String,
  field: String,
  grid: Grid,
  x: Float,
  y: Float,
  values: Dict(String, Dict(String, Val)),
) -> Nil {
  let w = graph.node_w
  let outputs = list.unique(grid.outputs)
  let color_of = fn(case_idx: Int) {
    let out = result_or(list.first(list.drop(grid.outputs, case_idx)), "")
    let k =
      result_or(
        list.index_map(outputs, fn(o, i) { #(o, i) }) |> list.key_find(out),
        0,
      )
    result_or(list.first(list.drop(p.cells, k % list.length(p.cells))), p.line)
  }
  // the probe's current inputs, if a probe of this type is running
  let current = dict.get(values, t)
  let current_cases = case current, m.program {
    Ok(vals), Some(prog) ->
      case dict.get(prog.decls, t) {
        Ok(d) ->
          case model.field(d, field) {
            Some(f) ->
              case f.mapping {
                Some(mp) -> {
                  let env =
                    list.filter_map(mp.inputs, fn(i) {
                      result_map(dict.get(vals, i), fn(v) { #(i, v) })
                    })
                  case list.length(env) == list.length(mp.inputs) {
                    True -> check.cases_for(prog.decls, prog.index, d, f, env)
                    False -> []
                  }
                }
                None -> []
              }
            None -> []
          }
        Error(_) -> []
      }
    _, _ -> []
  }
  rect(c, x, y, w, 182.0, 10.0, p.node, p.stroke, 1.0, 0.0)
  text(
    c,
    x +. 12.0,
    y +. 20.0,
    field <> ": " <> string.join(grid.inputs, " × ") <> " → case",
    "600 12px " <> sans,
    p.ink,
    "left",
    w -. 24.0,
  )
  let gx = x +. 12.0
  let gy = y +. 30.0
  let gw = w -. 24.0
  let gh = 104.0
  case grid.axes {
    [xs] -> {
      let n = int.max(list.length(xs), 1)
      let cw = gw /. int.to_float(n)
      list.index_map(grid.cells, fn(cell, i) {
        let #(_, hs) = cell
        let cx = gx +. int.to_float(i) *. cw
        let color = case hs {
          [one] -> color_of(one)
          [] -> p.bg
          _ -> p.bad
        }
        rect(c, cx +. 1.0, gy, cw -. 2.0, gh, 3.0, color, "", 0.0, 0.0)
        let lit = case hs {
          [one] -> list.contains(current_cases, one)
          _ -> False
        }
        case lit {
          True ->
            rect(c, cx +. 1.0, gy, cw -. 2.0, gh, 3.0, "", p.ink, 2.0, 0.0)
          False -> Nil
        }
        case cell.0 {
          [v] ->
            text(
              c,
              cx +. cw /. 2.0,
              gy +. gh +. 13.0,
              val_label(v),
              "10px " <> mono,
              p.muted,
              "center",
              cw,
            )
          _ -> Nil
        }
      })
      Nil
    }
    [xs, ys] -> {
      let nx = int.max(list.length(xs), 1)
      let ny = int.max(list.length(ys), 1)
      let cw = gw /. int.to_float(nx)
      let ch = gh /. int.to_float(ny)
      list.index_map(grid.cells, fn(cell, i) {
        let #(_, hs) = cell
        let col = i / ny
        let row = i % ny
        let cx = gx +. int.to_float(col) *. cw
        let cy = gy +. int.to_float(row) *. ch
        let color = case hs {
          [one] -> color_of(one)
          [] -> p.bg
          _ -> p.bad
        }
        rect(
          c,
          cx +. 0.5,
          cy +. 0.5,
          cw -. 1.0,
          ch -. 1.0,
          2.0,
          color,
          "",
          0.0,
          0.0,
        )
        case hs {
          [one] ->
            case list.contains(current_cases, one) {
              True ->
                rect(
                  c,
                  cx +. 0.5,
                  cy +. 0.5,
                  cw -. 1.0,
                  ch -. 1.0,
                  2.0,
                  "",
                  p.ink,
                  1.6,
                  0.0,
                )
              False -> Nil
            }
          _ -> Nil
        }
      })
      Nil
    }
    _ -> Nil
  }
  // legend: one swatch per output value
  list.index_map(outputs, fn(o, i) {
    let lx = x +. 12.0 +. int.to_float(i) *. 92.0
    let ly = y +. 166.0
    rect(
      c,
      lx,
      ly -. 9.0,
      10.0,
      10.0,
      2.0,
      result_or(
        list.first(list.drop(p.cells, i % list.length(p.cells))),
        p.line,
      ),
      "",
      0.0,
      0.0,
    )
    text(c, lx +. 15.0, ly, o, "11px " <> mono, p.muted, "left", 74.0)
  })
  Nil
}

fn result_map(r: Result(a, Nil), f: fn(a) -> b) -> Result(b, Nil) {
  case r {
    Ok(x) -> Ok(f(x))
    Error(_) -> Error(Nil)
  }
}

fn draw_diagnostics(c: Ctx, m: Model, p: Pal, pn: Panel) -> Nil {
  let lines = case m.error {
    "" -> list.map(m.report.diags, check.render)
    e -> [e]
  }
  let y0 = pn.y +. pn.h +. 26.0
  list.index_map(list.take(lines, 14), fn(l, i) {
    text(
      c,
      pn.x +. 4.0,
      y0 +. int.to_float(i) *. 19.0,
      l,
      "12px " <> mono,
      p.bad,
      "left",
      pn.w +. 400.0,
    )
  })
  Nil
}

fn draw_probe(c: Ctx, m: Model, p: Pal, pr: Probe) -> Nil {
  let rows = probe_rows(m, pr)
  let y0 = pr.y +. probe_text_h(pr) +. 10.0
  let h = int.to_float(list.length(rows)) *. 22.0 +. 16.0
  case rows {
    [] -> Nil
    _ -> {
      rect(c, pr.x, y0, probe_w, h, 10.0, p.node, p.stroke, 1.0, 0.0)
      list.index_map(rows, fn(r, i) {
        let #(name, v, role) = r
        let ry = y0 +. 22.0 +. int.to_float(i) *. 22.0
        let color = case role, v {
          "bad", _ -> p.bad
          _, "INVALID" -> p.bad
          _, _ -> p.ink
        }
        rect(
          c,
          pr.x +. 10.0,
          ry -. 12.0,
          4.0,
          14.0,
          2.0,
          case role {
            "bad" -> p.bad
            _ -> role_color(p, role)
          },
          "",
          0.0,
          0.0,
        )
        case role {
          "bad" ->
            text(
              c,
              pr.x +. 22.0,
              ry,
              v,
              "12px " <> mono,
              color,
              "left",
              probe_w -. 34.0,
            )
          _ -> {
            text(
              c,
              pr.x +. 22.0,
              ry,
              name,
              "12px " <> mono,
              p.muted,
              "left",
              130.0,
            )
            text(
              c,
              pr.x +. probe_w -. 12.0,
              ry,
              v,
              "600 12px " <> mono,
              color,
              "right",
              probe_w -. 170.0,
            )
          }
        }
      })
      Nil
    }
  }
}

fn draw_info(c: Ctx, m: Model) -> Nil {
  case m.selected {
    None -> info(c, "", [])
    Some(id) ->
      case list.find(m.graph.nodes, fn(n) { n.id == id }) {
        Ok(n) -> {
          let errs =
            list.filter_map(check.errors(m.report), fn(d) {
              case string.starts_with(d.where, n.id <> ".") || d.where == n.id {
                True -> Ok(#("error", d.msg))
                False -> Error(Nil)
              }
            })
          let hovered = case hov(m) {
            Some(#(hid, row)) if hid == id ->
              case list.find(n.rows, fn(r) { r.name == row }) {
                Ok(r) ->
                  case r.detail {
                    "" -> [#(r.name, r.label)]
                    d -> [#(r.name, r.label <> "\n" <> d)]
                  }
                Error(_) -> []
              }
            _ -> []
          }
          let doc = case n.doc {
            "" -> []
            d -> [#("about", d)]
          }
          info(
            c,
            n.id,
            list.flatten([
              doc,
              n.info,
              errs,
              hovered,
              [
                #(
                  "tip",
                  "click a type to centre it · 1–5 sets the rings · Esc shows all · P adds a probe",
                ),
              ],
            ]),
          )
        }
        Error(_) -> info(c, "", [])
      }
  }
}
