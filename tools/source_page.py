"""Builds one HTML page showing language.sheaf, the stdlib and the examples exactly as sheaf reads them."""
import html, re, sys, os
root = sys.argv[1]; out = sys.argv[2]
groups = [
 ("Specification", ["priv/language.sheaf"]),
 ("Standard library", ["priv/stdlib/logic.sheaf","priv/stdlib/bits.sheaf","priv/stdlib/dates.sheaf","priv/stdlib/text.sheaf"]),
 ("Examples", ["examples/orders/orders.sheaf","examples/proofs/proofs.sheaf","examples/mistakes/mistakes.sheaf","examples/book/book.sheaf","examples/meeting/meeting.sheaf","examples/temperature/temperature.sheaf","examples/shop/money.sheaf","examples/shop/catalog/catalog.sheaf","examples/shop/catalog/codes.sheaf","examples/shop/orders/orders.sheaf","examples/shop/orders/peek.sheaf","examples/cycle/a.sheaf","examples/cycle/b.sheaf"]),
]
blurb = {
 "priv/language.sheaf": "The grammar. sheaf compiles it and requires it to parse as File in exactly one way.",
 "priv/stdlib/logic.sheaf": "Gates and truth tables as checked mappings.",
 "priv/stdlib/bits.sheaf": "Binary digits, bytes and XOR.",
 "priv/stdlib/dates.sheaf": "Calendar dates with leap years as a mapping chain.",
 "priv/stdlib/text.sheaf": "Common text shapes.",
 "examples/orders/orders.sheaf": "Stored and computed fields, folds, a mapping, a filtered list.",
 "examples/proofs/proofs.sheaf": "Claims proved by expand, cancel and bound, with induction.",
 "examples/mistakes/mistakes.sheaf": "Eleven kinds of deliberate error, each explained by the checker.",
 "examples/book/book.sheaf": "Orders belong to customers: a path that starts with a type reaches the record around.",
 "examples/meeting/meeting.sheaf": "Date and Identifier from the standard library, with no import.",
 "examples/temperature/temperature.sheaf": "A number layout whose \"-\" position is a sign.",
 "examples/shop/money.sheaf": "In shop/: seen by every file in the project.",
 "examples/shop/catalog/catalog.sheaf": "The front file of catalog/: Item is seen outside the folder.",
 "examples/shop/catalog/codes.sheaf": "Private to catalog/.",
 "examples/shop/orders/orders.sheaf": "Uses Money, Item and Date, with no imports.",
 "examples/shop/orders/peek.sheaf": "Tries to use the private Code: an error.",
 "examples/cycle/a.sheaf": "Half of a cycle between files (reported as an error).",
 "examples/cycle/b.sheaf": "The other half of the cycle.",
}
# lines changed from the uploaded v3: (file, predicate on line text)
def amended(path, lines):
    """Lines added or changed since the uploaded v3 (tools/language.map.v3)."""
    if path != "priv/language.sheaf": return set()
    import difflib
    base = open(os.path.join(root, "tools/language.map.v3"), encoding="utf-8").read().split("\n")
    marks = set()
    sm = difflib.SequenceMatcher(None, base, lines, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("replace", "insert"):
            marks.update(range(j1, j2))
    return marks
TOK = re.compile(r'(?P<str>"(?:\\.|[^"\\])*")|(?P<type>\b[A-Z][A-Za-z0-9_]*\b)|(?P<num>\b\d+(?:\.\d+)?\b)|(?P<op>->|<=|>=|\.\.|[{}|&=<>*+\-])|(?P<kw>\b(?:qty|places|mod|cost|unique|val|sum|count|size|import)\b)')
def hl(code):
    out=[]; pos=0
    for m in TOK.finditer(code):
        out.append(html.escape(code[pos:m.start()]))
        k=m.lastgroup; out.append(f'<span class="{k}">{html.escape(m.group())}</span>'); pos=m.end()
    out.append(html.escape(code[pos:])); return "".join(out)
def line_html(l):
    # a comment starts at column-one '#', at '  #', or a trailing ' #' outside strings
    s = l.lstrip(" ")
    if s.startswith("#"): return html.escape(l[:len(l)-len(s)]) + f'<span class="com">{html.escape(s)}</span>'
    inq=False; esc=False
    for i,ch in enumerate(l):
        if esc: esc=False; continue
        if ch=="\\" and inq: esc=True; continue
        if ch=='"': inq=not inq; continue
        if ch=="#" and not inq and i>0 and l[i-1]==" ":
            return hl(l[:i]) + f'<span class="com">{html.escape(l[i:])}</span>'
    return hl(l)
nav=[]; body=[]
for g, files in groups:
    nav.append(f'<p class="group">{g}</p>')
    for f in files:
        text = open(os.path.join(root,f), encoding="utf-8").read()
        lines = text.split("\n")
        if lines and lines[-1]=="" : lines=lines[:-1]
        fid = re.sub(r'[^a-z0-9]+','-',f.lower()).strip('-')
        nav.append(f'<a href="#{fid}">{html.escape(f.split("/")[-1])}<span>{len(lines)}</span></a>')
        marks = amended(f, lines)
        rows = "".join(f'<tr class="{"am" if i in marks else ""}" id="{fid}-L{i+1}"><td class="n">{i+1}</td><td class="c">{line_html(l) or " "}</td></tr>' for i,l in enumerate(lines))
        note = f'<p class="legend"><span class="sw"></span>{len(marks)} lines added or changed since the uploaded v3: imports, the last-line rule, intersection, 100-character lines, looser spacing, printing, lists as counts in braces, filters and properties.</p>' if marks else ""
        body.append(f'<section id="{fid}"><header><h2>{html.escape(f)}</h2><p>{html.escape(blurb.get(f,""))} {len(lines)} lines.</p>{note}</header><div class="code"><table>{rows}</table></div></section>')
page = open(os.path.join(root,"tools/source_page.html")).read().replace("/*NAV*/","".join(nav)).replace("/*BODY*/","".join(body))
open(out,"w",encoding="utf-8").write(page)
print("wrote", out, len(page))
