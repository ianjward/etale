// The command line of Etale, and the loading of a file with the files that it sees.
//
//   node engine/etale.mjs self                 language.etale gives back the stored rules
//   node engine/etale.mjs seed                 store the rules that language.etale gives
//   node engine/etale.mjs check FILE           FILE's errors; the refusals
//   node engine/etale.mjs read FILE TYPE DATA  is the text of DATA a TYPE of FILE?
//   node engine/etale.mjs rules FILE           FILE's rules, in plain words
//   node engine/etale.mjs fmt FILE [--write]   FILE in its canonical form
//   node engine/etale.mjs print FILE TYPE DATA [FIELD]  DATA in its canonical text, or one record field of it
//   node engine/etale.mjs run FILE TYPE DATA   read DATA as a TYPE of FILE and show its values
//
// The seed (seed.json) is the stored rules of language.etale. The engine reads every file as
// File with the seed. No other reader is needed to start.
import fs from 'node:fs';
import path from 'node:path';
import { reader } from './read.mjs';
import { declarations_of } from './declarations.mjs';
import { rules_of, in_words, members_of } from './rules.mjs';
import { refusals } from './checks.mjs';
import { file_errors } from './file_checks.mjs';
import { printer } from './print.mjs';
import { INVALID, Exact, Sequence, decimal_text } from './evaluate.mjs';

const home = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const library = path.join(home, 'language');
const language = path.join(library, 'language.etale');
const seed_file = path.join(home, 'engine', 'seed.json');
const with_newline = (text) => (text.endsWith('\n') ? text : text + '\n');
const shown = (file) => path.relative(home, file);

const seed = JSON.parse(fs.readFileSync(seed_file, 'utf8'));
const file_reader = reader(seed);

// Read one text as File with the seed: in how many ways, and its declarations.
function read_file(file, text = fs.readFileSync(file, 'utf8'), rules_reader = file_reader) {
  const whole = with_newline(text);
  const { count, node } = rules_reader.read('File', whole);
  if (count !== 1) return { file, count, declarations: [] };
  const declarations = declarations_of(whole, node).map((declaration) => ({ ...declaration, file: shown(file) }));
  return { file, count, declarations };
}

// Rules as stored: one rule a line.
const stored_form = (rules) => '[\n' + rules.map((rule) => JSON.stringify(rule)).join(',\n') + '\n]\n';

// Read language.etale with the given rules and make its rules again.
function language_again(rules = seed) {
  const { count, declarations } = read_file(language, undefined, reader(rules));
  if (count !== 1) return { count, rules: [] };
  return { count, declarations, ...rules_of(declarations) };
}

// The files that a file sees (language.etale, Step 9): the standard library, and each group
// from the root down to its own folder, with the files of that group and the front file of each
// folder directly below it.
function scope_of(file, root) {
  const seen = new Set();
  const add_folder = (folder) => {
    for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
      const full = path.join(folder, entry.name);
      if (entry.isFile() && entry.name.endsWith('.etale')) seen.add(full);
      const front = path.join(full, entry.name + '.etale');
      if (entry.isDirectory() && fs.existsSync(front)) seen.add(front);
    }
  };
  add_folder(library);
  const chain = [];
  for (let folder = path.dirname(file); ; folder = path.dirname(folder)) {
    chain.push(folder);
    if (folder === root || folder === path.dirname(folder)) break;
  }
  for (const folder of chain) add_folder(folder);
  seen.delete(file);
  seen.delete(language);
  return [...seen];
}

// The types and constants that a declaration names: in its items, its fixed values, and the
// paths of its fields that start with a type.
function names_used(declaration) {
  const names = [...(declaration.types ?? [])];
  const walk = (value) => {
    if (Array.isArray(value)) return value.forEach(walk);
    if (!value || typeof value !== 'object') return;
    if (typeof value.type === 'string') names.push(value.type);
    for (const name of [value.name, value.path?.[0]]) if (/^[A-Z]/.test(name ?? '')) names.push(name);
    Object.values(value).forEach(walk);
  };
  walk({ ...declaration, name: undefined });
  return names;
}

// A file and what it needs from the files that it sees, as rules. A name in a declaration
// from another file is looked up from that file: in it, then in the files that it sees. The
// root is where groups start: the repository, as in main's tests.
let language_declarations;
function load(file, text, root = home) {
  const own = read_file(file, text);
  if (own.count !== 1) return { ...own, file: shown(file), rules: [], left_out: [], problems: [] };
  const problems = [];
  const files = new Map([[file, own.declarations]]);
  const declared_in = (each) => {
    if (!files.has(each)) files.set(each, read_file(each).declarations);
    return files.get(each);
  };
  const scopes = new Map();
  const seen_from = (each) => {
    if (scopes.has(each)) return scopes.get(each);
    const visible = new Map(declared_in(each).map((declaration) => [declaration.name, [declaration]]));
    for (const other of scope_of(each, root)) {
      for (const declaration of declared_in(other)) {
        if (!declared_in(each).some((mine) => mine.name === declaration.name)) {
          visible.set(declaration.name, [...(visible.get(declaration.name) ?? []), declaration]);
        }
      }
    }
    scopes.set(each, visible);
    return visible;
  };
  language_declarations ??= language_again().declarations;
  const in_language = new Set(language_declarations.map((declaration) => declaration.name));
  const included = new Map(own.declarations.map((declaration) => [declaration.name, declaration]));
  for (const declaration of own.declarations) {
    if (in_language.has(declaration.name)) problems.push(declaration.name + ' is declared in language.etale');
  }
  const waiting = own.declarations.map((declaration) => [declaration, file]);
  const uses = new Map();                              // the files that each file takes types from
  while (waiting.length > 0) {
    const [declaration, from] = waiting.pop();
    const from_file = shown(from);
    const use = (other) => {
      if (other === from_file) return;
      if (!uses.has(from_file)) uses.set(from_file, []);
      if (!uses.get(from_file).includes(other)) uses.get(from_file).push(other);
    };
    for (const name of names_used(declaration)) {
      if (in_language.has(name) || name === 'Integer' || name === 'Decimal') continue;
      if (included.has(name)) {
        if (!(from === file || seen_from(from).has(name))) continue;
        use(from === file ? included.get(name).file : seen_from(from).get(name)[0].file);
        continue;
      }
      const found = seen_from(from).get(name) ?? [];
      if (found.length > 1) problems.push(name + ' is declared in ' + found.map((each) => each.file).join(' and '));
      if (found.length === 0) continue;
      use(found[0].file);
      included.set(name, found[0]);
      waiting.push([found[0], path.join(home, found[0].file)]);
    }
  }
  const declarations = [...included.values()];
  named_lists([...language_declarations, ...declarations]);
  calls_of([...language_declarations, ...declarations]);
  const heads = new Set(seed.map((rule) => rule.head));
  const made = rules_of(declarations, [...language_declarations, ...declarations], heads);
  const declared = new Map([...language_declarations, ...declarations].map((each) => [each.name, each]));
  const rules = [...seed, ...made.rules];
  return { ...own, file: shown(file), rules, left_out: made.left_out, declared, language: language_declarations, uses, problems: [...problems, ...refusals(rules, declared)] };
}

// The names that the engine's code gives in quotes and that a file of the library other than
// language.etale declares. The engine may know only the language's own types; a rule about any
// other type is written in Etale.
function engine_names() {
  const declared = new Map();
  for (const entry of fs.readdirSync(library)) {
    const file = path.join(library, entry);
    if (!entry.endsWith('.etale') || file === language) continue;
    for (const declaration of read_file(file).declarations) declared.set(declaration.name, shown(file));
  }
  const found = [];
  const engine = path.join(home, 'engine');
  for (const entry of fs.readdirSync(engine).filter((each) => each.endsWith('.mjs'))) {
    for (const [, name] of fs.readFileSync(path.join(engine, entry), 'utf8').matchAll(/['"]([A-Z][A-Za-z0-9_]*)['"]/g)) {
      if (declared.has(name) && !found.some(([seen]) => seen === name)) found.push([name, declared.get(name)]);
    }
  }
  return found;
}

// A field whose type is a record, and whose parentheses hold one path, is a call with one
// value: 'arguments {Word_Arguments} (word)'. Calls with two or more values are read as calls
// already. A path to a record of the field's own type holds that record: it is not a call. A
// list of values that are not records, made from items, is a list: 'digits {Bit...} (bit, rest...)'.
// A list type by name, such as 'Binary_String {Binary_Digit...} count: 0..': a field of that
// type is that list, and takes its count when it has none of its own.
function named_lists(declarations) {
  const by_name = new Map(declarations.map((each) => [each.name, each]));
  const list_of = (type) => {
    const found = by_name.get(type);
    if (found?.kind !== 'refinement' || !found.list || found.allowed || found.call || found.constant) return undefined;
    return found;
  };
  for (const declaration of declarations) {
    for (const field of declaration.fields ?? []) {
      if (field.list || field.items?.length !== 1) continue;
      const named = list_of(field.items[0].type);
      if (!named) continue;
      field.named_list = field.items[0].type;
      field.items = named.items;
      field.list = true;
      if (!field.count && named.count) field.count = named.count;
    }
  }
}

function calls_of(declarations) {
  const by_name = new Map(declarations.map((each) => [each.name, each]));
  // the type a made record gives: its result's type, when it has a result
  const given = (type, seen = new Set()) => {
    const found = by_name.get(type);
    const result = found?.kind === 'record' && found.fields.find((field) => field.name === 'result');
    if (!result || seen.has(type)) return type;
    return given(result.items?.[0]?.type, seen.add(type));
  };
  const type_of = (declaration, [head, step]) => {
    const field = declaration.fields.find((each) => each.name === head);
    const type = field?.items?.[0]?.type;
    if (step === undefined || ['first', 'last'].includes(step)) return type;
    const inner = by_name.get(given(type)) ?? undefined;
    const record = inner?.kind === 'record' ? inner : members_of(by_name, inner?.name)?.[0];
    return record ? record.fields.find((each) => each.name === step)?.items?.[0]?.type : undefined;
  };
  // a record, or a union of records: a call to the union makes the member that takes its values
  const record_like = (found) => found?.kind === 'record' || Boolean(members_of(by_name, found?.name));
  for (const declaration of declarations) {
    // a constant of a record type with one value is a constant record made with that value
    const base = declaration.kind === 'refinement' && by_name.get(declaration.items?.[0]?.type);
    if (base?.kind === 'record' && declaration.constant !== undefined && !declaration.call) {
      const { number, name } = declaration.constant;
      declaration.call = [number !== undefined ? { number } : name !== undefined ? { path: [name] } : { number: '?' }];
      delete declaration.constant;
    }
    for (const field of declaration.fields ?? []) {
      const made = by_name.get(field.items?.[0]?.type);
      // a list made from items: every value is an item of the list's type, or a list of them
      const items_given = field.positions?.every((slot) => slot.value?.path?.length === 1
        && type_of(declaration, slot.value.path) === field.items[0].type);
      if (field.role === 'made' && field.call && field.list && (!record_like(made) || items_given)) {
        field.role = 'listed';
        field.values = field.positions.map((slot) => slot.value);
        continue;
      }
      if (field.role !== 'worked' || !record_like(made) || !field.value?.path || field.round || field.wrap) continue;
      if (type_of(declaration, field.value.path) === field.items[0].type) continue;
      field.role = 'made';
      field.call = true;
      field.positions = [{ line: field.line, path: field.value.path, value: field.value }];
    }
    // a made field of a type with a result holds that result: its type, and whether it is a list
    for (const field of declaration.fields ?? []) {
      if (field.role !== 'made' || !field.call || field.makes) continue;
      const result = by_name.get(field.items?.[0]?.type)?.fields?.find((each) => each.name === 'result');
      if (!result) continue;
      field.each = Boolean(field.list);                // one record for each item of a list
      field.makes = field.items[0].type;
      field.items = result.items;
      if (result.list) field.list = true;
    }
  }
}

const commands = {
  self() {
    const again = language_again();
    const same = again.count === 1 && stored_form(again.rules) === stored_form(seed);
    console.log(again.count === 1
      ? 'language.etale reads as File in one way, and its reading gives '
        + (same ? 'the stored rules back (' + seed.length + ' rules)' : 'other rules: run "seed"')
      : 'language.etale does not read as File in one way (' + again.count + ')');
    const named = engine_names();
    for (const [name, file] of named) console.log('the engine names ' + name + ', which ' + file + ' declares: state it in language.etale');
    return same && named.length === 0 ? 0 : 1;
  },
  seed() {
    const again = language_again();
    if (again.count !== 1) return commands.self();
    const changed = stored_form(again.rules) !== fs.readFileSync(seed_file, 'utf8');
    if (changed) fs.writeFileSync(seed_file, stored_form(again.rules));
    console.log(changed ? 'stored ' + again.rules.length + ' rules' : 'the stored rules are already these');
    return 0;
  },
  check(file) {
    if (path.resolve(file) === language) {
      const problems = refusals(seed, new Map(language_again().declarations.map((each) => [each.name, each])));
      for (const problem of problems) console.log(problem);
      return problems.length > 0 ? 1 : commands.self();
    }
    const loaded = load(path.resolve(file));
    if (loaded.count !== 1) {
      console.log(file + ': does not read as File in one way (' + loaded.count + ')');
      return 1;
    }
    const problems = [...file_errors(loaded), ...loaded.problems];
    for (const problem of problems) console.log(problem);
    console.log(file + ': ' + loaded.declarations.length + ' declarations, ' + problems.length + ' problems');
    return problems.length > 0 ? 1 : 0;
  },
  read(file, type, data) {
    const loaded = load(path.resolve(file));
    const { count, failures = [] } = reader(loaded.rules).read(type, fs.readFileSync(data, 'utf8'));
    console.log(['refused', 'accepted', 'two readings'][count] + failures.map((failure) => '\n  ' + failure).join(''));
    return count === 1 ? 0 : 1;
  },
  fmt(file, write) {
    const text = with_newline(fs.readFileSync(file, 'utf8'));
    const { count, node } = file_reader.read('File', text);
    if (count !== 1) return console.log(file + ': does not read as File in one way (' + count + ')'), 1;
    const { printed, same } = printer(seed).print(file_reader, 'File', text, node);
    if (!same) return console.log(file + ': its canonical form does not read back the same'), 1;
    if (write === '--write') fs.writeFileSync(file, printed);
    else process.stdout.write(printed);
    return 0;
  },
  print(file, type, data, field) {
    const loaded = load(path.resolve(file));
    const data_reader = reader(loaded.rules);
    const text = fs.readFileSync(data, 'utf8');
    const { count, node, failures = [] } = data_reader.read(type, text);
    if (count !== 1) return console.log(['refused', '', 'two readings'][count] + failures.map((each) => '\n  ' + each).join('')), 1;
    if (field !== undefined) return print_field(loaded, type, node, field);
    const { printed, same } = printer(loaded.rules).print(data_reader, type, text, node);
    if (!same) return console.log('its canonical form does not read back the same'), 1;
    process.stdout.write(printed);
    return 0;
  },
  run(file, type, data) {
    const loaded = load(path.resolve(file));
    const { count, node, failures = [] } = reader(loaded.rules).read(type, fs.readFileSync(data, 'utf8'));
    if (count !== 1) return commands.read(file, type, data);
    console.log(type + shown_value(node, '  '));
    return 0;
  },
  rules(file) {
    const loaded = load(path.resolve(file));
    const own = new Set(loaded.declarations.map((declaration) => declaration.name));
    for (const rule of loaded.rules) if (own.has(rule.head.split('.')[0])) console.log(in_words(rule));
    for (const what of loaded.left_out) console.log('not carried: ' + what);
    return 0;
  },
};

// One record field of a reading, printed by its own type's shape: a stored record, or one
// made from values. Its text must read back as that type to the same values. A record whose
// shape is 'text {Binary_Digit}' is bits, written eight to a byte.
function print_field(loaded, type, node, name) {
  const value = node.memo?.get(name);
  if (!value?.rule?.record) return console.log(type + '.' + name + ' is not a record: ' + shown_value(value ?? INVALID, '  ').trim()), 1;
  const shapes = new Map([...loaded.declared].filter(([, each]) => each.shape).map(([head, each]) => [head, each.shape]));
  const printed = printer(loaded.rules).made(value, shapes);
  if (printed === null) return console.log(type + '.' + name + ' has a value with no text'), 1;
  const again = reader(loaded.rules).read(value.head, printed);
  if (again.count !== 1 || stored_key(again.node) !== stored_key(value)) {
    return console.log(type + '.' + name + ': its text does not read back as ' + value.head + ' to the same values'), 1;
  }
  if (loaded.declared.get(value.head)?.medium !== 'Binary_Digit') return process.stdout.write(printed), 0;
  if (printed.length % 8 !== 0) return console.log(type + '.' + name + ' has ' + printed.length + ' bits, not whole bytes'), 1;
  const bytes = Buffer.alloc(printed.length / 8);
  for (let at = 0; at < bytes.length; at++) bytes[at] = parseInt(printed.slice(at * 8, at * 8 + 8), 2);
  process.stdout.write(bytes);
  return 0;
}

// The stored values of a record, all the way down, as one text: two records with the same
// stored values have the same key.
function stored_key(value) {
  if (value instanceof Exact) return decimal_text(value);
  if (typeof value === 'string') return JSON.stringify(value);
  if (value instanceof Sequence) return '[' + value.items.map(stored_key).join(',') + ']';
  if (!value?.rule?.record) return String(value?.description ?? value);
  const names = value.rule.parts.filter((part) => part.name !== undefined).map((part) => part.name);
  return value.head + '(' + names.map((each) => each + ' ' + stored_key(value.memo?.get(each))).join(', ') + ')';
}

// A value, as run shows it: a record's fields one a line, below it.
function shown_value(value, indent) {
  if (value === INVALID) return ' INVALID';
  if (value instanceof Exact) return ' ' + decimal_text(value);
  if (value === 'TRUE' || value === 'FALSE') return ' ' + value;
  if (typeof value === 'string') return ' ' + JSON.stringify(value);
  if (value instanceof Sequence) return value.items.map((item) => '\n' + indent + '-' + shown_value(item, indent + '  ')).join('') || ' (none)';
  const names = [...value.rule.parts.filter((part) => part.name !== undefined).map((part) => part.name),
    ...(value.rule.fields ?? []).map((field) => field.name)];
  return names.map((name) => '\n' + indent + name + ':' + shown_value(value.memo?.get(name) ?? INVALID, indent + '  ')).join('');
}

export function main([name, ...rest]) {
  if (!commands[name]) {
    console.log('commands: ' + Object.keys(commands).join(', '));
    return 2;
  }
  return commands[name](...rest);
}

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) {
  process.exit(main(process.argv.slice(2)));
}
