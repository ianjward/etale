//// A program: the language.sheaf prelude plus user files, compiled and checked.
////
//// Bootstrapping: language.sheaf is read by the line reader, its declarations are
//// compiled into a grammar, and language.sheaf itself must then match File in
//// exactly one way under that grammar. Every user file goes through the same
//// gate, then through the static checker. There are no imports: a file sees
//// its own folder, the folders above it, the front file of each folder below
//// those, and the standard library (language.sheaf, Step 10). The files a file
//// needs are found from the names it uses and loaded first.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sheaf/check.{type Report}
import sheaf/evaluate.{type Ev, type Rec, type Val}
import sheaf/grammar.{type Grammar, type Parser}
import sheaf/model.{type Decl, type Entry, type MapError, DeclEntry, MapError}
import sheaf/node.{type Node}
import sheaf/reader

/// Where files come from: the disk on Node, an in-memory folder in the browser.
/// Where texts come from: the disk on Node, an in-memory folder in the browser,
/// or a bundled project. list(folder) gives its entries as (name, is folder).
pub type Fs {
  Fs(
    read: fn(String) -> Result(String, Nil),
    list: fn(String) -> List(#(String, Bool)),
    cwd: String,
    root: String,
    std: String,
  )
}

pub type Program {
  Program(
    decls: Dict(String, Decl),
    order: List(Decl),
    index: Dict(String, Int),
    files: List(String),
    loaded: Dict(String, String),
    main_file: Option(String),
    grammar: Grammar,
    ev: Ev,
    prelude_report: Report,
    report: Report,
    fs: Fs,
  )
}

pub type Outcome {
  Outcome(
    ok: Bool,
    type_name: String,
    value: Option(Val),
    failures: List(String),
    error: String,
    ambiguous: Bool,
    records: List(Rec),
  )
}

pub const prelude_name = "language.sheaf"

// ---------------------------------------------------------------- paths

pub fn dirname(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] ->
      case list.reverse(rest) |> string.join("/") {
        "" -> "/"
        d -> d
      }
    [] -> "."
  }
}

pub fn join(base: String, rel: String) -> String {
  case string.starts_with(rel, "/") {
    True -> normalize(rel)
    False -> normalize(base <> "/" <> rel)
  }
}

pub fn normalize(path: String) -> String {
  let absolute = string.starts_with(path, "/")
  let parts =
    string.split(path, "/")
    |> list.fold([], fn(acc, part) {
      case part, acc {
        "", _ | ".", _ -> acc
        "..", [prev, ..rest] if prev != ".." -> rest
        "..", _ ->
          case absolute {
            True -> acc
            False -> [part, ..acc]
          }
        _, _ -> [part, ..acc]
      }
    })
    |> list.reverse
    |> string.join("/")
  case absolute {
    True -> "/" <> parts
    False -> parts
  }
}

/// A path for people: without the leading slash of the in-memory folder.
pub fn display_path(path: String) -> String {
  case path {
    "/" <> rest -> rest
    _ -> path
  }
}

pub fn display(p: Program, abspath: String) -> String {
  let prefix = case p.fs.cwd {
    "/" -> "/"
    c -> c <> "/"
  }
  case string.starts_with(abspath, prefix) {
    True -> string.drop_start(abspath, string.length(prefix))
    False -> abspath
  }
}

// ---------------------------------------------------------------- building

pub fn new(
  prelude_text: String,
  fs: Fs,
  verify: Bool,
) -> Result(Program, MapError) {
  use entries <- result.try(reader.read(prelude_text, prelude_name))
  let p =
    Program(
      dict.new(),
      [],
      dict.new(),
      [],
      dict.new(),
      None,
      grammar.compile(dict.new()),
      evaluate.new(dict.new()),
      check.empty_report(),
      check.empty_report(),
      fs,
    )
  use p <- result.try(
    list.try_fold(reader.decls(entries), p, fn(p, d) {
      declare(p, d, prelude_name)
    }),
  )
  let p = recompile(Program(..p, files: [prelude_name]))
  use _ <- result.try(case verify {
    True ->
      verify_file(p, prelude_text, prelude_name, entries)
      |> result.map(fn(_) { Nil })
    False -> Ok(Nil)
  })
  Ok(
    Program(
      ..p,
      prelude_report: check.run(p.decls, p.index, reader.decls(entries)),
    ),
  )
}

fn declare(p: Program, d: Decl, fname: String) -> Result(Program, MapError) {
  case dict.get(p.decls, d.name), list.contains(model.builtin_numeric, d.name) {
    Ok(prev), _ ->
      Error(MapError(
        "type '"
          <> d.name
          <> "' is already declared (first declared at "
          <> prev.file
          <> ":"
          <> int.to_string(prev.line)
          <> "); two files may not declare the same name",
        fname,
        d.line,
        1,
      ))
    _, True ->
      Error(MapError(
        "type '" <> d.name <> "' is a built-in type",
        fname,
        d.line,
        1,
      ))
    Error(_), False -> {
      let d = model.Decl(..d, file: fname)
      Ok(
        Program(
          ..p,
          decls: dict.insert(p.decls, d.name, d),
          order: [d, ..p.order],
          index: dict.insert(p.index, d.name, dict.size(p.index)),
        ),
      )
    }
  }
}

fn recompile(p: Program) -> Program {
  Program(..p, grammar: grammar.compile(p.decls), ev: evaluate.new(p.decls))
}

/// Declarations in file order.
pub fn ordered(p: Program) -> List(Decl) {
  list.reverse(p.order)
}

// ---------------------------------------------------------------- parsing

pub fn parse(
  p: Program,
  type_name: String,
  text: String,
  enforce: Bool,
) -> #(List(Node), Parser) {
  let ps =
    grammar.parser(p.grammar, text, enforce, evaluate.checker(p.ev, text))
  #(grammar.parse(ps, type_name), ps)
}

fn block_kind(k: model.Kind) -> String {
  case k {
    model.Record -> "Record_Block"
    model.Layout -> "Layout_Block"
    model.Refine -> "Refinement_Line"
    model.Union -> "Union_Line"
    model.Intersection -> "Intersection_Line"
  }
}

@external(javascript, "./ffi.mjs", "slice")
fn js_slice(s: String, a: Int, b: Int) -> String

fn slice(text: String, n: Node) -> String {
  js_slice(text, n.s, n.e)
}

fn kid_text(text: String, n: Node, label: String) -> String {
  case node.kid(n, label) {
    Ok(k) -> slice(text, k)
    Error(_) -> ""
  }
}

/// The file must match File in exactly one way, and agree with the line reader.
pub fn verify_file(
  p: Program,
  text: String,
  fname: String,
  entries: List(Entry),
) -> Result(Node, MapError) {
  let text = reader.as_file_text(text)
  let #(trees, ps) = parse(p, "File", text, True)
  case trees {
    [] -> {
      let far = grammar.read(ps.far)
      let #(line, col) = grammar.line_col(text, far)
      let exp = grammar.expected(ps) |> list.take(8) |> string.join(", ")
      Error(MapError(
        "the file does not match File (expected " <> exp <> ")",
        fname,
        line,
        col,
      ))
    }
    [_, _, ..] ->
      Error(MapError(
        "the file matches File in more than one way (ambiguous)",
        fname,
        1,
        1,
      ))
    [tree] -> {
      let blocks = node.items(node.inner(tree))
      let got =
        list.filter_map(blocks, fn(b) {
          let r = node.inner(b)
          case r.t {
            Some("Record_Block") | Some("Layout_Block") -> {
              let assert Ok(head) = node.kid(r, "head")
              let head = node.inner(head)
              Ok(#(option.unwrap(r.t, ""), kid_text(text, head, "name"), r))
            }
            Some("Refinement_Line")
            | Some("Union_Line")
            | Some("Intersection_Line") ->
              Ok(#(option.unwrap(r.t, ""), kid_text(text, r, "name"), r))
            _ -> Error(Nil)
          }
        })
      let want =
        list.map(entries, fn(e) {
          case e {
            DeclEntry(d) -> #(block_kind(d.kind), d.name)
          }
        })
      case list.map(got, fn(g) { #(g.0, g.1) }) == want {
        False ->
          Error(MapError(
            "internal: the grammar and the line reader disagree about the blocks of this file",
            fname,
            1,
            1,
          ))
        True -> {
          let fields_ok =
            list.zip(got, entries)
            |> list.all(fn(pair) {
              case pair {
                #(#("Record_Block", _, r), DeclEntry(d)) -> {
                  let assert Ok(body) = node.kid(r, "body")
                  let items = node.items(body)
                  let names =
                    list.filter_map(items, fn(bi) {
                      let assert Ok(line) = node.kid(node.inner(bi), "line")
                      let line = node.inner(line)
                      let line = case line.t {
                        Some("Mapped_Field") -> {
                          let assert Ok(h) = node.kid(line, "head")
                          node.inner(h)
                        }
                        _ -> line
                      }
                      case line.t {
                        Some("Body_Comment_Line") -> Error(Nil)
                        _ -> Ok(kid_text(text, line, "name"))
                      }
                    })
                  names == list.map(d.fields, fn(f) { f.name })
                }
                _ -> True
              }
            })
          case fields_ok {
            True -> Ok(tree)
            False ->
              Error(MapError(
                "internal: the grammar and the line reader disagree about record fields",
                fname,
                1,
                1,
              ))
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------- projects and scope

fn under(path: String, dir: String) -> Bool {
  path == dir || string.starts_with(path, dir <> "/") || dir == "/"
}

/// The groups a text sees, nearest first: its own folder and every folder
/// above it, up to the project root.
fn groups(fs: Fs, dir: String) -> List(String) {
  case under(dir, fs.root) {
    False -> [dir]
    True -> group_chain(fs.root, dir, [])
  }
}

fn group_chain(root: String, dir: String, acc: List(String)) -> List(String) {
  let acc = [dir, ..acc]
  case dir == root || dir == "/" || dir == "." {
    True -> list.reverse(acc)
    False -> group_chain(root, dirname(dir), acc)
  }
}

fn is_text(name: String) -> Bool {
  string.ends_with(name, ".sheaf") && name != prelude_name
}

/// The texts of a group: its own files, plus the front file of each folder
/// directly below it (the file named after that folder).
fn group_texts(fs: Fs, g: String) -> List(String) {
  list.flat_map(fs.list(g), fn(e) {
    let #(name, folder) = e
    case folder {
      False ->
        case is_text(name) {
          True -> [join(g, name)]
          False -> []
        }
      True -> {
        let front = join(g, name <> "/" <> name <> ".sheaf")
        case fs.read(front) {
          Ok(_) -> [front]
          Error(_) -> []
        }
      }
    }
  })
}

fn std_texts(fs: Fs) -> List(String) {
  list.filter_map(fs.list(fs.std), fn(e) {
    case e.1, is_text(e.0) {
      False, True -> Ok(join(fs.std, e.0))
      _, _ -> Error(Nil)
    }
  })
}

/// Every text that a text sees, besides language.sheaf (Step 10).
pub fn scope(p: Program, abspath: String) -> List(String) {
  let mine = case under(abspath, p.fs.std) && p.fs.std != "" {
    True -> []
    False -> list.flat_map(groups(p.fs, dirname(abspath)), group_texts(p.fs, _))
  }
  list.append(mine, std_texts(p.fs))
  |> list.unique
  |> list.filter(fn(x) { x != abspath })
}

type Known =
  Dict(String, List(String))

/// The type names each text in scope declares, read without checking.
fn names_of(p: Program, path: String, text: String) -> List(String) {
  case reader.read(text, display(p, path)) {
    Ok(entries) -> list.map(reader.decls(entries), fn(d) { d.name })
    Error(_) -> []
  }
}

fn read_text(p: Program, path: String) -> Result(String, MapError) {
  case p.fs.read(path) {
    Ok(t) -> Ok(t)
    Error(_) -> Error(MapError("cannot read " <> display(p, path), "", 0, 0))
  }
}

/// The texts this text needs: for each name it uses but does not declare,
/// the one text in its scope that declares it.
fn needs(
  p: Program,
  path: String,
  text: String,
) -> Result(List(String), MapError) {
  let fname = display(p, path)
  use entries <- result.try(reader.read(text, fname))
  let decls = reader.decls(entries)
  let own = list.map(decls, fn(d) { d.name })
  let wanted =
    list.flat_map(decls, model.references)
    |> list.unique
    |> list.filter(fn(n) {
      !list.contains(own, n)
      && !dict.has_key(p.decls, n)
      && !list.contains(model.builtin_numeric, n)
    })
  case wanted {
    [] -> Ok([])
    _ -> {
      let known: Known =
        list.fold(scope(p, path), dict.new(), fn(acc, sp) {
          case p.fs.read(sp) {
            Ok(t) ->
              list.fold(names_of(p, sp, t), acc, fn(acc, n) {
                dict.insert(acc, n, [sp, ..result_or(dict.get(acc, n), [])])
              })
            Error(_) -> acc
          }
        })
      list.try_fold(wanted, [], fn(acc, n) {
        case dict.get(known, n) {
          Ok([one]) -> Ok([one, ..acc])
          Ok([a, b, ..]) ->
            Error(MapError(
              "'"
                <> n
                <> "' is declared in both "
                <> display(p, b)
                <> " and "
                <> display(p, a)
                <> "; rename one, or move one out of this file's scope",
              fname,
              1,
              1,
            ))
          _ -> Ok(acc)
        }
      })
      |> result.map(fn(xs) { list.unique(list.reverse(xs)) })
    }
  }
}

fn result_or(r: Result(a, Nil), default: a) -> a {
  case r {
    Ok(x) -> x
    Error(_) -> default
  }
}

/// Dependencies first, then the text itself; a cycle is an error.
fn plan(
  p: Program,
  path: String,
  text: String,
  stack: List(String),
  done: List(String),
) -> Result(List(String), MapError) {
  case list.contains(done, path) || dict.has_key(p.loaded, path) {
    True -> Ok(done)
    False ->
      case list.contains(stack, path) {
        True ->
          Error(MapError(
            "files use each other in a cycle: "
              <> {
              list.reverse([path, ..stack])
              |> list.drop_while(fn(x) { x != path })
              |> list.map(display(p, _))
              |> string.join(" -> ")
            }
              <> "; move the shared types into one file",
            display(p, path),
            1,
            1,
          ))
        False -> {
          use deps <- result.try(needs(p, path, text))
          use done <- result.try(
            list.try_fold(deps, done, fn(done, dp) {
              use t <- result.try(read_text(p, dp))
              plan(p, dp, t, [path, ..stack], done)
            }),
          )
          Ok(list.append(done, [path]))
        }
      }
  }
}

/// Load a file by absolute path, with the files it needs loaded first.
pub fn load(
  p: Program,
  abspath: String,
) -> Result(#(Program, Report), MapError) {
  let abspath = normalize(abspath)
  case dict.get(p.loaded, abspath) {
    Ok(_) -> Ok(#(p, check.empty_report()))
    Error(_) -> {
      use text <- result.try(read_text(p, abspath))
      let p = case p.main_file {
        None -> Program(..p, main_file: Some(display(p, abspath)))
        Some(_) -> p
      }
      load_text(p, text, abspath)
    }
  }
}

/// Load a text as if it were the file at abspath.
pub fn load_text(
  p: Program,
  text: String,
  abspath: String,
) -> Result(#(Program, Report), MapError) {
  use order <- result.try(plan(p, abspath, text, [], []))
  list.try_fold(order, #(p, check.empty_report()), fn(acc, path) {
    let #(p, rep) = acc
    use t <- result.try(case path == abspath {
      True -> Ok(text)
      False -> read_text(p, path)
    })
    use #(p, r) <- result.try(load_one(p, t, path))
    Ok(#(p, check.merge(rep, r)))
  })
}

fn load_one(
  p: Program,
  text: String,
  abspath: String,
) -> Result(#(Program, Report), MapError) {
  let fname = display(p, abspath)
  use entries <- result.try(reader.read(text, fname))
  use _ <- result.try(verify_file(p, text, fname, entries))
  use #(p, mine) <- result.try(
    list.try_fold(reader.decls(entries), #(p, []), fn(acc, d) {
      let #(p, mine) = acc
      use p <- result.try(declare(p, d, fname))
      Ok(#(p, [model.Decl(..d, file: fname), ..mine]))
    }),
  )
  let p = recompile(p)
  let r = check.run(p.decls, p.index, list.reverse(mine))
  let p =
    Program(
      ..p,
      files: list.append(p.files, [fname]),
      loaded: dict.insert(p.loaded, abspath, fname),
      report: check.merge(p.report, r),
    )
  Ok(#(p, r))
}

// ---------------------------------------------------------------- bundles

/// A project as one text: '=== name' lines, each followed by its file.
pub fn bundle_entries(text: String) -> List(#(String, String)) {
  string.split(text, "\n")
  |> list.fold([], fn(acc, line) {
    case line, acc {
      "=== " <> name, _ -> [#(string.trim_end(name), []), ..acc]
      _, [#(n, ls), ..rest] -> [#(n, [line, ..ls]), ..rest]
      _, [] -> acc
    }
  })
  |> list.reverse
  |> list.index_map(fn(e, i) { #(e, i) })
  |> fn(es) {
    let last = list.length(es) - 1
    list.map(es, fn(ei) {
      let #(e, i) = ei
      let body = string.join(list.reverse(e.1), "\n")
      // the newline before the next '===' line ends this file
      case i == last {
        True -> #(e.0, body)
        False -> #(e.0, body <> "\n")
      }
    })
  }
}

pub fn is_bundle(text: String) -> Bool {
  string.starts_with(text, "=== ")
}

/// Print a project as one text, entries in the given order.
pub fn bundle_text(entries: List(#(String, String))) -> String {
  list.map(entries, fn(e) {
    let body = case string.ends_with(e.1, "\n") || e.1 == "" {
      True -> e.1
      False -> e.1 <> "\n"
    }
    "=== " <> e.0 <> "\n" <> body
  })
  |> string.concat
}

/// An in-memory folder: absolute paths to texts.
pub fn memory_fs(
  files: Dict(String, String),
  cwd: String,
  root: String,
  std: String,
) -> Fs {
  Fs(
    fn(path) { dict.get(files, normalize(path)) },
    fn(dir) { memory_list(files, normalize(dir)) },
    cwd,
    root,
    std,
  )
}

fn memory_list(
  files: Dict(String, String),
  dir: String,
) -> List(#(String, Bool)) {
  let prefix = case dir {
    "/" -> "/"
    _ -> dir <> "/"
  }
  dict.keys(files)
  |> list.filter_map(fn(k) {
    case string.starts_with(k, prefix) {
      False -> Error(Nil)
      True ->
        case
          string.split_once(string.drop_start(k, string.length(prefix)), "/")
        {
          Ok(#(sub, _)) -> Ok(#(sub, True))
          Error(_) -> Ok(#(string.drop_start(k, string.length(prefix)), False))
        }
    }
  })
  |> list.unique
}

// ---------------------------------------------------------------- checking data

fn record_failures(recs: List(Rec)) -> List(String) {
  list.flat_map(recs, fn(r) {
    list.map(evaluate.failures(r), fn(x) {
      case string.starts_with(x, "there is no ") {
        True -> x
        False -> r.decl.name <> "." <> x
      }
    })
  })
}

pub fn check(p: Program, type_name: String, text: String) -> Outcome {
  let known =
    dict.has_key(p.decls, type_name)
    || list.contains(model.builtin_numeric, type_name)
  case known {
    False ->
      Outcome(
        False,
        type_name,
        None,
        [],
        "unknown type '" <> type_name <> "'",
        False,
        [],
      )
    True -> {
      let #(trees, ps) = parse(p, type_name, text, True)
      case trees {
        [tree] -> {
          let v = evaluate.value(p.ev, tree, text, None, None)
          evaluate.settle(p.ev, v)
          let recs = evaluate.all_records(p.ev, v)
          list.each(recs, fn(r) { evaluate.evaluate_all(p.ev, r) })
          // fields that reach a record around their own are decided only now
          case record_failures(recs) {
            [] -> Outcome(True, type_name, Some(v), [], "", False, recs)
            fails ->
              Outcome(
                False,
                type_name,
                Some(v),
                fails,
                "the text has the right shape but breaks rules",
                False,
                recs,
              )
          }
        }
        [_, _, ..] ->
          Outcome(
            False,
            type_name,
            None,
            [],
            "the text matches the type in more than one way (ambiguous)",
            True,
            [],
          )
        [] -> {
          let #(loose, ps2) = parse(p, type_name, text, False)
          case loose {
            [tree, ..] -> {
              let v = evaluate.value(p.ev, tree, text, None, None)
              evaluate.settle(p.ev, v)
              let recs = evaluate.all_records(p.ev, v)
              list.each(recs, fn(r) { evaluate.evaluate_all(p.ev, r) })
              let fails =
                record_failures(recs)
                |> list.append(evaluate.unique_violations(p.ev, v))
              let fails =
                list.append(
                  list.filter(fails, fn(x) { !string.contains(x, "INVALID") }),
                  list.filter(fails, fn(x) { string.contains(x, "INVALID") }),
                )
              let fails = case fails {
                [] -> grammar.rejected(ps) |> list.unique |> list.take(5)
                _ -> fails
              }
              Outcome(
                False,
                type_name,
                Some(v),
                fails,
                "the text has the right shape but breaks rules",
                False,
                recs,
              )
            }
            [] -> {
              let #(line, col) = grammar.line_col(text, grammar.read(ps2.far))
              Outcome(
                False,
                type_name,
                None,
                [],
                "line "
                  <> int.to_string(line)
                  <> ", column "
                  <> int.to_string(col)
                  <> ": expected "
                  <> {
                  grammar.expected(ps2) |> list.take(8) |> string.join(", ")
                },
                False,
                [],
              )
            }
          }
        }
      }
    }
  }
}
