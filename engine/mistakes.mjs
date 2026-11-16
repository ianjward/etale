// Mistakes made from a file, one change at a time, for the file judge (judge_files.mjs).

// One file's mistakes: each a name and a text.
export function mistakes_of(text) {
  const lines = text.split('\n');
  const out = [];
  const with_lines = (name, changed) => out.push([name, changed.join('\n')]);
  const replace = (index, line) => lines.map((each, at) => (at === index ? line : each));
  const declaration_starts = lines.map((line, at) => (/^[A-Z]/.test(line) ? at : -1)).filter((at) => at >= 0);
  const is_field = (line) => /^  [a-z_][a-z0-9_]* \{/.test(line);
  lines.forEach((line, at) => {
    const code = line.replace(/#.*$/, '');
    const type = code.match(/\{([A-Z][A-Za-z0-9_]*)(\.\.\.)?\}/);
    if (type && !['Text', 'Needs', 'Claims'].includes(type[1])) {
      with_lines('type ' + type[1] + ' renamed', replace(at, line.replace('{' + type[1], '{Nowhere_Type')));
    }
    if (is_field(line)) {
      with_lines('field renamed value', replace(at, line.replace(/^  [a-z_][a-z0-9_]*/, '  value')));
      with_lines('field twice', [...lines.slice(0, at + 1), line, ...lines.slice(at + 1)]);
    }
    const step = code.match(/\(([^()]*\b)([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)/);
    if (step && is_field(line)) {
      with_lines('step renamed', replace(at, line.replace(step[2] + '.' + step[3], step[2] + '.nowhere')));
    }
    const first = code.match(/\(([a-z_][a-z0-9_]*)\b/);
    if (first && is_field(line)) {
      with_lines('field named renamed', replace(at, line.replace('(' + first[1], '(nowhere')));
    }
    if (/^    \{.*\} \(/.test(line)) {
      with_lines('case dropped', lines.filter((_, other) => other !== at));
      with_lines('case twice', [...lines.slice(0, at + 1), line, ...lines.slice(at + 1)]);
      with_lines('case output changed', replace(at, line.replace(/\{[^}]*\}/, '{"nowhere"}')));
      with_lines('case names another field', replace(at, line.replace('(', '(nowhere = 1 & ')));
    }
    if (/\b[a-z_]+\.[a-z_]+ in [a-z_]+\.[a-z_]+/.test(code)) {
      with_lines('relation with <', replace(at, line.replace(' in ', ' < ')));
      with_lines('relation as a claim', replace(at, line.replace('{Needs}', '{Claims}')));
      with_lines('relation with another condition', replace(at, line.replace(/\)\s*$/, ' & 1 = 1)')));
    }
    if (/= True\b/.test(code)) with_lines('a type of many values', replace(at, line.replace('= True', '= Digit')));
    const places = code.match(/places: ([1-9]\d*)/);
    if (places && is_field(line)) {
      with_lines('places lowered', replace(at, line.replace(places[0], 'places: ' + (Number(places[1]) - 1))));
    }
    // not through a field with a dot, such as rest.total: main counts no places there, and its
    // bounds of a rounded field that reads itself so never end
    const calculation = code.match(/\(([^()]*)\)\s*$/);
    if (calculation && is_field(line) && !/\.\.\.\}/.test(code) && /[-+*/.]/.test(calculation[1])
      && !/[<>=|&,]|\.\.|\.(?!(count|sum|min|max)\b)[a-z]/.test(calculation[1])) {
      with_lines('rounded to 1', replace(at, line.replace(calculation[0].trimEnd(), calculation[0].trimEnd() + ' round: 1')));
    }
    if (is_field(line) && / = "/.test(code)) with_lines('a text compared with <', replace(at, line.replace(' = "', ' < "')));
    const range = code.match(/\((-?\d+)\.\.(\d+)\)/);
    if (range) {
      const [all, low, high] = range;
      with_lines('range narrowed', replace(at, line.replace(all, '(' + low + '..' + (Number(high) - 1) + ')')));
      with_lines('range widened', replace(at, line.replace(all, '(' + low + '..' + (Number(high) + 1) + ')')));
    }
  });
  with_lines('a name of the language declared', [...lines, 'Digit {"x"}', '']);
  with_lines('a built-in name declared', [...lines, 'Integer {"x"}', '']);
  if (declaration_starts.length > 1) {
    const last = declaration_starts[declaration_starts.length - 1];
    with_lines('last declaration first', [...lines.slice(last), ...lines.slice(0, last)]);
  }
  for (let at = 0; at < lines.length; at++) {
    if (!/^[A-Z][A-Za-z0-9_]* \{\}/.test(lines[at])) continue;
    let end = at + 1;
    while (end < lines.length && is_field(lines[end])) {
      end++;
      while (end < lines.length && /^    /.test(lines[end])) end++;
    }
    const fields = [];
    for (let each = at + 1; each < end; each++) if (is_field(lines[each])) fields.push(each);
    if (fields.length < 2) continue;
    const last = fields[fields.length - 1];
    let last_end = last + 1;
    while (last_end < end && /^    /.test(lines[last_end])) last_end++;
    with_lines('last field first', [...lines.slice(0, at + 1), ...lines.slice(last, last_end),
      ...lines.slice(at + 1, last), ...lines.slice(last_end)]);
  }
  return out;
}
