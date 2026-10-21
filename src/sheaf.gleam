//// Command line (runs on Node):
////
////   sheaf bootstrap                          language.sheaf parses itself, exactly one way
////   sheaf check FILE.sheaf | FOLDER | BUNDLE    parse, find the files it needs, run every check
////   sheaf run FILE.sheaf TYPE DATA [--trace]   does the text in DATA inhabit TYPE?
////   sheaf run FILE.sheaf TYPE --text "..."     the same, with the text inline (\n for newlines)
////   sheaf graph FILE.sheaf -o OUT.svg          the data-flow graph of a file, as SVG
////   sheaf fmt FILE.sheaf [--write | --check]   the file in canonical spacing (Step 9)
////   sheaf print FILE.sheaf TYPE VALUE.json     the canonical text of a value (Step 9)
////   sheaf bundle FOLDER [-o OUT]             a project as one text (Step 10)

import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import sheaf/check
import sheaf/evaluate.{type Val, VRecord, VSeqv}
import sheaf/graph
import sheaf/model
import sheaf/printer
import sheaf/program.{type Program}
import sheaf/sequents

@external(javascript, "./sheaf/ffi.mjs", "read_file")
fn read_file(p: String) -> Result(String, Nil)

@external(javascript, "./sheaf/ffi.mjs", "write_file")
fn write_file(p: String, text: String) -> Result(Nil, String)

@external(javascript, "./sheaf/ffi.mjs", "cwd")
fn cwd() -> String

@external(javascript, "./sheaf/ffi.mjs", "list_dir")
fn list_dir(dir: String) -> List(#(String, Bool))

@external(javascript, "./sheaf/ffi.mjs", "is_dir")
fn is_dir(path: String) -> Bool

@external(javascript, "./sheaf/ffi.mjs", "home_dir")
fn home_dir() -> String

@external(javascript, "./sheaf/ffi.mjs", "argv")
fn argv() -> List(String)

@external(javascript, "./sheaf/ffi.mjs", "exit")
fn exit(code: Int) -> Nil

@external(javascript, "./sheaf/ffi.mjs", "now_ms")
fn now() -> Float

pub fn main() {
  let code = case argv() {
    ["bootstrap", ..] -> cmd_bootstrap()
    ["check", file, ..] -> cmd_check(file)
    ["run", file, type_name, ..rest] -> cmd_run(file, type_name, rest)
    ["graph", file, "-o", out, ..] -> cmd_graph(file, out)
    ["graph", file, ..] -> cmd_graph(file, "graph.svg")
    ["fmt", file, ..rest] -> cmd_fmt(file, rest)
    ["sequents", file, ..] -> cmd_sequents(file)
    ["bundle", dir, "-o", out, ..] -> cmd_bundle(dir, Some(out))
    ["bundle", dir, ..] -> cmd_bundle(dir, None)
    ["print", file, type_name, "--json", json, ..] ->
      cmd_print(file, type_name, Some(Ok(json)))
    ["print", file, type_name, "--text", text, ..] ->
      cmd_print(file, type_name, Some(Ok(string.replace(text, "\\n", "\n"))))
    ["print", file, type_name, value_file, ..] ->
      cmd_print(file, type_name, Some(read_file(abs(value_file))))
    ["print", file, type_name] -> cmd_print(file, type_name, None)
    ["print", file] -> cmd_fmt(file, [])
    _ -> {
      io.println(usage)
      2
    }
  }
  exit(code)
}

const usage =
  "sheaf: checker and evaluator for language.sheaf

  sheaf bootstrap                          language.sheaf parses itself, exactly one way
  sheaf check FILE.sheaf | FOLDER | BUNDLE    parse, find the files it needs, run every check
  sheaf run FILE.sheaf TYPE DATA [--trace]   does the text in DATA inhabit TYPE?
  sheaf run FILE.sheaf TYPE --text \"...\"     the same, with the text inline (\\n for newlines)
  sheaf graph FILE.sheaf -o OUT.svg          the data-flow graph of a file, as SVG
  sheaf fmt FILE.sheaf [--write | --check]   the file in canonical spacing
  sheaf sequents FILE.sheaf                  the file's theory as geometric sequents
  sheaf print FILE.sheaf                     the file's code, in canonical form
  sheaf print FILE.sheaf TYPE                a type's code
  sheaf print FILE.sheaf TYPE DATA           data's values, in canonical form (DATA: a text or JSON)
  sheaf print FILE.sheaf TYPE --text \"...\"   the same, inline (--json '{...}' for JSON)
  sheaf bundle FOLDER [-o OUT]             a project as one text; check works on it too"

pub fn prelude_path() -> String {
  home_dir() <> "/priv/language.sheaf"
}

pub fn std_dir() -> String {
  home_dir() <> "/priv/stdlib"
}

/// The disk, with the project rooted at `root`.
pub fn fs_at(root: String) -> program.Fs {
  program.Fs(read_file, list_dir, cwd(), root, std_dir())
}

pub fn fs() -> program.Fs {
  fs_at(cwd())
}

/// A file's project root: the current folder when the file is inside it,
/// otherwise the file's own folder.
fn root_for(path: String) -> String {
  let a = abs(path)
  case string.starts_with(a, cwd() <> "/") {
    True -> cwd()
    False -> program.dirname(a)
  }
}

/// A bundled project in memory, with the standard library read from disk.
fn bundle_fs(text: String) -> program.Fs {
  let files =
    program.bundle_entries(text)
    |> list.map(fn(e) { #(program.normalize("/" <> e.0), e.1) })
    |> dict.from_list
  let mem = program.memory_fs(files, "/", "/", std_dir())
  program.Fs(
    ..mem,
    read: fn(path) {
      case mem.read(path) {
        Ok(t) -> Ok(t)
        Error(_) -> read_file(path)
      }
    },
    list: fn(dir) {
      case dir == std_dir() {
        True -> list_dir(dir)
        False -> mem.list(dir)
      }
    },
  )
}

fn ms(t0: Float) -> String {
  int.to_string(float.round(now() -. t0)) <> " ms"
}

fn abs(path: String) -> String {
  program.join(cwd(), path)
}

/// A program with the prelude loaded, or the reason it could not be built.
pub fn start(verify: Bool) -> Result(Program, String) {
  case read_file(prelude_path()) {
    Error(_) -> Error("cannot read " <> prelude_path())
    Ok(text) ->
      case program.new(text, fs(), verify) {
        Ok(p) -> Ok(p)
        Error(e) -> Error(model.error_text(e))
      }
  }
}

fn load_file(path: String) -> Result(#(Program, check.Report), String) {
  case start(False) {
    Error(e) -> Error(e)
    Ok(p) ->
      case
        program.load(program.Program(..p, fs: fs_at(root_for(path))), abs(path))
      {
        Ok(r) -> Ok(r)
        Error(e) -> Error(model.error_text(e))
      }
  }
}

fn cmd_bootstrap() -> Int {
  let t0 = now()
  case start(True) {
    Error(e) -> {
      io.println("bootstrap failed: " <> e)
      1
    }
    Ok(p) -> {
      let assert Ok(text) = read_file(prelude_path())
      io.println(
        "language.sheaf: "
        <> int.to_string(list.length(string.split(text, "\n")))
        <> " lines, "
        <> int.to_string(list.length(p.order))
        <> " declarations",
      )
      io.println(
        "matched File in exactly one way; line reader and grammar agree on every block ("
        <> ms(t0)
        <> ")",
      )
      list.each(p.prelude_report.mappings, fn(m) {
        io.println("  mapping " <> m.0 <> ": " <> m.1)
      })
      list.each(p.prelude_report.diags, fn(d) {
        io.println("  " <> check.render(d))
      })
      let errs = list.length(check.errors(p.prelude_report))
      io.println(int.to_string(errs) <> " error(s)")
      case errs {
        0 -> 0
        _ -> 1
      }
    }
  }
}

fn cmd_check(file: String) -> Int {
  let t0 = now()
  case is_dir(abs(file)), read_file(abs(file)), read_file(prelude_path()) {
    True, _, _ -> check_many(fs_at(abs(file)), texts_under(abs(file)))
    _, Ok(t), _ ->
      case program.is_bundle(t) {
        True -> {
          let bfs = bundle_fs(t)
          check_many(
            bfs,
            list.map(program.bundle_entries(t), fn(e) {
              program.normalize("/" <> e.0)
            }),
          )
        }
        False -> check_file(file, t0)
      }
    _, _, _ -> check_file(file, t0)
  }
}

/// Every .sheaf text in a folder and the folders below it.
fn texts_under(dir: String) -> List(String) {
  list.flat_map(list_dir(dir), fn(e) {
    let path = dir <> "/" <> e.0
    case e.1 {
      True -> texts_under(path)
      False ->
        case string.ends_with(e.0, ".sheaf") && e.0 != program.prelude_name {
          True -> [path]
          False -> []
        }
    }
  })
  |> list.sort(string.compare)
}

/// Check each text of a project on its own, then sum up.
fn check_many(f: program.Fs, paths: List(String)) -> Int {
  case start(False) {
    Error(e) -> {
      io.println("error: " <> e)
      1
    }
    Ok(base) -> {
      let base = program.Program(..base, fs: f)
      let errs =
        list.fold(paths, 0, fn(total, path) {
          case program.load(base, path) {
            Error(e) -> {
              io.println("error: " <> model.error_text(e))
              total + 1
            }
            Ok(#(p, rep)) -> {
              let n = list.length(check.errors(rep))
              io.println(
                option.unwrap(p.main_file, path)
                <> ": "
                <> case n {
                  0 -> "ok"
                  _ -> int.to_string(n) <> " error(s)"
                },
              )
              list.each(check.errors(rep), fn(d) {
                io.println("  " <> check.render(d))
              })
              total + n
            }
          }
        })
      io.println(
        "\n"
        <> int.to_string(list.length(paths))
        <> " file(s), "
        <> int.to_string(errs)
        <> " error(s)",
      )
      case errs {
        0 -> 0
        _ -> 1
      }
    }
  }
}

fn check_file(file: String, t0: Float) -> Int {
  case read_file(abs(file)), read_file(prelude_path()) {
    Ok(a), Ok(b) if a == b -> cmd_bootstrap()
    _, _ ->
      case load_file(file) {
        Error(e) -> {
          io.println("error: " <> e)
          1
        }
        Ok(#(p, rep)) -> {
          let main = option.unwrap(p.main_file, file)
          let mine = list.filter(program.ordered(p), fn(d) { d.file == main })
          let imported =
            list.filter(p.files, fn(f) {
              f != program.prelude_name && f != main
            })
          io.println(
            file
            <> ": "
            <> int.to_string(list.length(mine))
            <> " declarations; parsed exactly one way and checked in "
            <> ms(t0),
          )
          case imported {
            [] -> Nil
            _ -> io.println("uses: " <> string.join(imported, ", "))
          }
          section(
            "mappings (coverage, disjointness, every output produced):",
            rep.mappings,
          )
          section("claims:", rep.claims)
          let names = list.map(mine, fn(d) { d.name })
          section(
            "cost (worst case, up to a constant):",
            list.filter(rep.costs, fn(c) { list.contains(names, c.0) }),
          )
          case rep.diags {
            [] -> Nil
            ds -> {
              io.println("")
              list.each(ds, fn(d) { io.println(check.render(d)) })
            }
          }
          let errs = list.length(check.errors(rep))
          io.println("\n" <> int.to_string(errs) <> " error(s)")
          case errs {
            0 -> 0
            _ -> 1
          }
        }
      }
  }
}

fn section(title: String, rows: List(#(String, String))) -> Nil {
  case rows {
    [] -> Nil
    _ -> {
      io.println("\n" <> title)
      list.each(rows, fn(r) { io.println("  " <> r.0 <> ": " <> r.1) })
    }
  }
}

fn unescape(s: String) -> String {
  s |> string.replace("\\n", "\n") |> string.replace("\\t", "\t")
}

fn cmd_run(file: String, type_name: String, rest: List(String)) -> Int {
  let trace = list.contains(rest, "--trace")
  let data = case rest {
    ["--text", t, ..] -> Ok(unescape(t))
    [path, ..] if path != "--trace" ->
      case read_file(abs(path)) {
        Ok(t) -> Ok(t)
        Error(_) -> Error("cannot read " <> path)
      }
    _ -> Error("give a data file or --text")
  }
  case load_file(file), data {
    Error(e), _ | _, Error(e) -> {
      io.println("error: " <> e)
      1
    }
    Ok(#(p, rep)), Ok(text) ->
      case check.errors(rep) {
        [_, ..] as errs -> {
          list.each(errs, fn(d) { io.println(check.render(d)) })
          io.println("fix the errors above first")
          1
        }
        [] -> {
          let t0 = now()
          let out = program.check(p, type_name, text)
          case out.ok {
            True ->
              io.println(
                "the text inhabits " <> type_name <> "  (" <> ms(t0) <> ")",
              )
            False -> {
              io.println(
                "the text does not inhabit "
                <> type_name
                <> ": "
                <> out.error
                <> "  ("
                <> ms(t0)
                <> ")",
              )
              list.each(out.failures, fn(f) { io.println("  failed: " <> f) })
            }
          }
          case out.value {
            Some(v) -> {
              io.println("")
              print_value(p, v, "  ", 0)
            }
            None -> Nil
          }
          case trace, out.value {
            True, Some(VRecord(r)) -> {
              io.println("\nevaluation:")
              list.each(evaluate.trace(r), fn(t) {
                io.println(
                  "  "
                  <> t.field
                  <> " ["
                  <> t.role
                  <> "] = "
                  <> t.value
                  <> case t.detail {
                    "" -> ""
                    d -> "   " <> d
                  },
                )
              })
            }
            _, _ -> Nil
          }
          case out.ok {
            True -> 0
            False -> 1
          }
        }
      }
  }
}

fn print_value(p: Program, v: Val, indent: String, depth: Int) -> Nil {
  case v {
    VRecord(r) ->
      list.each(r.decl.fields, fn(f) {
        let x = evaluate.get(p.ev, r, f.name)
        let tag = case f.role {
          model.Stored -> ""
          role -> "  (" <> model.role_text(role) <> ")"
        }
        case x {
          VSeqv(items, _, _) -> {
            io.println(
              indent
              <> f.name
              <> ": "
              <> int.to_string(list.length(items))
              <> " item(s)"
              <> tag,
            )
            case depth < 4 {
              True ->
                list.index_map(list.take(items, 5), fn(it, i) {
                  case it {
                    VRecord(ir) -> {
                      io.println(
                        indent
                        <> "  ["
                        <> int.to_string(i + 1)
                        <> "] "
                        <> ir.decl.name,
                      )
                      print_value(p, it, indent <> "      ", depth + 1)
                    }
                    _ ->
                      io.println(
                        indent
                        <> "  ["
                        <> int.to_string(i + 1)
                        <> "] "
                        <> evaluate.show(it),
                      )
                  }
                })
                |> fn(_) { Nil }
              False -> Nil
            }
            case list.length(items) > 5 {
              True ->
                io.println(
                  indent
                  <> "  … "
                  <> int.to_string(list.length(items) - 5)
                  <> " more",
                )
              False -> Nil
            }
          }
          VRecord(ir) -> {
            io.println(indent <> f.name <> ": " <> ir.decl.name <> tag)
            print_value(p, x, indent <> "    ", depth + 1)
          }
          _ -> io.println(indent <> f.name <> " = " <> evaluate.show(x) <> tag)
        }
      })
    _ -> io.println(indent <> evaluate.show(v))
  }
}

fn cmd_graph(file: String, out: String) -> Int {
  case load_file(file) {
    Error(e) -> {
      io.println("error: " <> e)
      1
    }
    Ok(#(p, _)) -> {
      let g = graph.build(p, option.unwrap(p.main_file, file))
      let svg = graph.to_svg(g, graph.layout(g), file)
      case write_file(out, svg) {
        Ok(_) -> {
          io.println(
            "wrote "
            <> out
            <> " ("
            <> int.to_string(list.length(g.nodes))
            <> " nodes, "
            <> int.to_string(list.length(g.edges))
            <> " wires)",
          )
          0
        }
        Error(e) -> {
          io.println("error: " <> e)
          1
        }
      }
    }
  }
}

/// Print a file's theory as geometric sequents (docs/geometric.md).
fn cmd_sequents(file: String) -> Int {
  // language.sheaf is already loaded as the prelude: print its own theory
  let loaded = case abs(file) == prelude_path() {
    True ->
      case start(False) {
        Ok(p) ->
          Ok(#(
            program.Program(..p, main_file: Some(program.prelude_name)),
            p.report,
          ))
        Error(e) -> Error(e)
      }
    False -> load_file(file)
  }
  case loaded {
    Error(e) -> {
      io.println("error: " <> e)
      1
    }
    Ok(#(p, _)) -> {
      io.println(sequents.file(p, option.unwrap(p.main_file, file)))
      0
    }
  }
}

/// Print a file in canonical spacing: to standard output, back to the file
/// (--write), or only report whether it is already formatted (--check).
fn cmd_fmt(file: String, opts: List(String)) -> Int {
  case start(False), read_file(abs(file)) {
    Error(e), _ -> {
      io.println("error: " <> e)
      1
    }
    _, Error(_) -> {
      io.println("error: cannot read " <> file)
      1
    }
    Ok(p), Ok(text) ->
      case printer.format(p, text, file) {
        Error(e) -> {
          io.println("error: " <> e)
          1
        }
        Ok(out) ->
          case list.contains(opts, "--check"), list.contains(opts, "--write") {
            True, _ ->
              case out == text {
                True -> {
                  io.println(file <> ": formatted")
                  0
                }
                False -> {
                  io.println(file <> ": not formatted (run sheaf fmt --write)")
                  1
                }
              }
            False, True ->
              case out == text {
                True -> {
                  io.println(file <> ": already formatted")
                  0
                }
                False ->
                  case write_file(abs(file), out) {
                    Ok(_) -> {
                      io.println(file <> ": formatted")
                      0
                    }
                    Error(e) -> {
                      io.println("error: " <> e)
                      1
                    }
                  }
              }
            False, False -> {
              io.print(out)
              0
            }
          }
      }
  }
}

/// Print the canonical text of a JSON value as TYPE, checked by reading it back.
/// One rule: data prints its values, a type prints its code.
fn cmd_print(
  file: String,
  type_name: String,
  data: option.Option(Result(String, Nil)),
) -> Int {
  case load_file(file) {
    Error(e) -> {
      io.println("error: " <> e)
      1
    }
    Ok(#(p, rep)) ->
      case check.errors(rep), data {
        [_, ..] as errs, _ -> {
          list.each(errs, fn(d) { io.println(check.render(d)) })
          io.println("fix the errors above first")
          1
        }
        [], None -> done(printer.print_code(p, type_name, source))
        [], Some(Error(_)) -> {
          io.println("error: cannot read the data")
          1
        }
        [], Some(Ok(d)) ->
          case string.starts_with(string.trim_start(d), "{") {
            True ->
              case printer.parse_json(d) {
                Ok(v) -> done(printer.print(p, type_name, v))
                Error(e) -> done(Error("the data is not JSON: " <> e))
              }
            False -> done(printer.print_text(p, type_name, d))
          }
      }
  }
}

/// A file named as the program shows it: relative to here, or language.sheaf.
fn source(fname: String) -> Result(String, Nil) {
  case fname == program.prelude_name {
    True -> read_file(prelude_path())
    False -> read_file(program.join(cwd(), fname))
  }
}

fn done(r: Result(String, String)) -> Int {
  case r {
    Ok(text) -> {
      io.print(text)
      0
    }
    Error(e) -> {
      io.println("error: " <> e)
      1
    }
  }
}

/// Every .sheaf text under a folder, as one text: '=== name' lines, each
/// followed by its file. 'sheaf check' reads it back the same way.
fn cmd_bundle(dir: String, out: option.Option(String)) -> Int {
  let root = abs(dir)
  let entries =
    texts_under(root)
    |> list.filter_map(fn(path) {
      case read_file(path) {
        Ok(t) -> Ok(#(string.drop_start(path, string.length(root) + 1), t))
        Error(_) -> Error(Nil)
      }
    })
  let text = program.bundle_text(entries)
  case out {
    None -> {
      io.print(text)
      0
    }
    Some(o) ->
      case write_file(abs(o), text) {
        Ok(_) -> {
          io.println(
            "wrote "
            <> o
            <> " ("
            <> int.to_string(list.length(entries))
            <> " files)",
          )
          0
        }
        Error(e) -> {
          io.println("error: " <> e)
          1
        }
      }
  }
}
