//// Parse trees. A node knows the type that produced it (if any), its span in
//// the text, and its children: the alternative taken, sequence items, record
//// fields or layout positions.

import gleam/list
import gleam/option.{type Option}

pub type Node {
  Node(t: Option(String), s: Int, e: Int, kind: NodeKind)
}

pub type NodeKind {
  NLit
  NChar
  NAlt(child: Node)
  /// Sequence items, stored last first so a parser can extend in O(1); read
  /// them with 'items'.
  NSeq(rev: List(Node))
  NRec(kids: List(#(String, Node)))
  NLay(kids: List(#(String, Node)))
}

/// Follow alternatives down to the node that holds the content.
pub fn inner(n: Node) -> Node {
  case n.kind {
    NAlt(c) -> inner(c)
    _ -> n
  }
}

pub fn kid(n: Node, label: String) -> Result(Node, Nil) {
  case n.kind {
    NRec(kids) | NLay(kids) -> list.key_find(kids, label)
    _ -> Error(Nil)
  }
}

/// The items of a sequence node, first to last.
pub fn items(n: Node) -> List(Node) {
  case n.kind {
    NSeq(rev) -> list.reverse(rev)
    _ -> []
  }
}
