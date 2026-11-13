//// A digest of a file: its declarations with every comment line, blank line
//// and trailing comment taken out. It is made from the file's own parse as
//// File, never by matching text, so a "#" inside a literal stays. The AI pane
//// sends it in place of language.etale when the full text is too long.

import etale/node.{type Node, NAlt, NLay, NRec, NSeq}
import etale/program.{type Program}
import etale/reader
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string

@external(javascript, "./ffi.mjs", "slice")
fn slice(s: String, a: Int, b: Int) -> String

@external(javascript, "./ffi.mjs", "length")
fn length(s: String) -> Int

/// The types whose text the digest leaves out.
const dropped = [
  "Comment_Line", "Body_Comment_Line", "Blank_Line", "Trailing_Comment",
]

/// The digest of `text`, read as File by `p`'s grammar.
pub fn digest(p: Program, text: String) -> Result(String, String) {
  let text = reader.as_file_text(text)
  case program.parse(p, "File", text, True) {
    #([tree], _) -> Ok(cut(text, merge(list.sort(spans(tree, []), compare))))
    #([], _) -> Error("the file does not match File")
    #(_, _) -> Error("the file matches File in more than one way")
  }
}

/// The digest must read as File in exactly one way and declare the same
/// names, in the same order, as the file it came from. Gives the number of
/// declarations.
pub fn check(p: Program, text: String, digest: String) -> Result(Int, String) {
  case program.parse(p, "File", reader.as_file_text(digest), True) {
    #([], _) -> Error("the digest does not match File")
    #([_, _, ..], _) -> Error("the digest matches File in more than one way")
    #([_], _) ->
      case names(text, "file"), names(digest, "digest") {
        Ok(a), Ok(b) if a == b -> Ok(list.length(a))
        Ok(a), Ok(b) ->
          Error(
            "the digest declares "
            <> int.to_string(list.length(b))
            <> " names and the file "
            <> int.to_string(list.length(a))
            <> ", or in another order",
          )
        Error(e), _ | _, Error(e) -> Error(e)
      }
  }
}

fn names(text: String, what: String) -> Result(List(String), String) {
  case reader.read(text, what) {
    Ok(entries) -> Ok(list.map(reader.decls(entries), fn(d) { d.name }))
    Error(_) -> Error("the line reader cannot read the " <> what)
  }
}

fn spans(n: Node, acc: List(#(Int, Int))) -> List(#(Int, Int)) {
  case n.t {
    Some(t) ->
      case list.contains(dropped, t) {
        True -> [#(n.s, n.e), ..acc]
        False -> kids(n, acc)
      }
    _ -> kids(n, acc)
  }
}

fn kids(n: Node, acc: List(#(Int, Int))) -> List(#(Int, Int)) {
  case n.kind {
    NAlt(c) -> spans(c, acc)
    NSeq(rev) -> list.fold(rev, acc, fn(a, k) { spans(k, a) })
    NRec(ks) | NLay(ks) -> list.fold(ks, acc, fn(a, k) { spans(k.1, a) })
    _ -> acc
  }
}

fn compare(a: #(Int, Int), b: #(Int, Int)) {
  int.compare(a.0, b.0)
}

/// Sorted spans, with overlapping ones joined.
fn merge(xs: List(#(Int, Int))) -> List(#(Int, Int)) {
  list.fold(xs, [], fn(acc: List(#(Int, Int)), x: #(Int, Int)) {
    case acc {
      [last, ..rest] if x.0 <= last.1 -> [
        #(last.0, int.max(last.1, x.1)),
        ..rest
      ]
      _ -> [x, ..acc]
    }
  })
  |> list.reverse
}

fn cut(text: String, xs: List(#(Int, Int))) -> String {
  let #(parts, at) =
    list.fold(xs, #([], 0), fn(st: #(List(String), Int), x: #(Int, Int)) {
      #([slice(text, st.1, x.0), ..st.0], x.1)
    })
  [slice(text, at, length(text)), ..parts]
  |> list.reverse
  |> string.concat
}
