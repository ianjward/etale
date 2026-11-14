// The new engine's command line, and the loading that its tests and its judge share.
//
//   node engine/etale.mjs self                 language.etale gives back the stored rules
//   node engine/etale.mjs seed                 store the rules that language.etale gives
//   node engine/etale.mjs check FILE           read FILE and what it sees; the two refusals
//   node engine/etale.mjs read TYPE FILE DATA  is the text of DATA a TYPE of FILE?
//   node engine/etale.mjs rules FILE           FILE's rules, in plain words
//
// The seed (seed.json) is the stored rules of language.etale. The engine reads every file as
// File with the seed. No other reader is needed to start.
import fs from 'node:fs';
import path from 'node:path';
import { reader } from './read.mjs';
import { declarations_of } from './declarations.mjs';
import { rules_of, in_words } from './rules.mjs';
import { refusals } from './checks.mjs';

export const home = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
export const language = path.join(home, 'priv', 'language.etale');
const library = path.join(home, 'priv', 'stdlib');
const seed_file = path.join(home, 'engine', 'seed.json');
const with_newline = (text) => (text.endsWith('\n') ? text : text + '\n');
const shown = (file) => path.relative(home, file);

export const seed = JSON.parse(fs.readFileSync(seed_file, 'utf8'));
const file_reader = reader(seed);

// Read one text as File with the seed: in how many ways, and its declarations.
export function read_file(file, text = fs.readFileSync(file, 'utf8'), rules_reader = file_reader) {
  const whole = with_newline(text);
  const { count, node } = rules_reader.read('File', whole);
  if (count !== 1) return { file, count, declarations: [] };
  const declarations = declarations_of(whole, node).map((declaration) => ({ ...declaration, file: shown(file) }));
  return { file, count, declarations };
}

// Rules as stored: one rule a line.
export const stored_form = (rules) => '[\n' + rules.map((rule) => JSON.stringify(rule)).join(',\n') + '\n]\n';

// Read language.etale with the given rules and make its rules again.
export function language_again(rules = seed) {
  const { count, declarations } = read_file(language, undefined, reader(rules));
  if (count !== 1) return { count, rules: [] };
  return { count, declarations, ...rules_of(declarations) };
}

// The files that a file sees (language.etale, Step 10): the standard library, and each group
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

// The types and constants that a declaration names.
function names_used(declaration) {
  const names = [];
  const expression = (value) => {
    if (!value) return;
    if (value.name !== undefined) names.push(value.name);
    for (const term of value.terms ?? []) expression(term);
  };
  const line = (each) => {
    for (const item of each.items ?? []) if (item.type) names.push(item.type);
    for (const { low, high } of each.allowed ?? []) { expression(low); expression(high); }
    if (each.count) { expression(each.count.least); expression(each.count.most); }
    if (each.need?.value) expression(each.need.value);
  };
  line(declaration);
  expression(declaration.constant);
  for (const type of declaration.types ?? []) names.push(type);
  for (const each of [...(declaration.positions ?? []), ...(declaration.fields ?? []), ...(declaration.shape ?? [])]) {
    line(each);
  }
  return names;
}

// A file and what it needs from the files that it sees, as rules. The root is where groups
// start: the repository, as in main's tests.
let language_declarations;
export function load(file, text, root = home) {
  const own = read_file(file, text);
  if (own.count !== 1) return { ...own, rules: [], left_out: [], problems: [] };
  const problems = [];
  const visible = new Map();
  for (const other of scope_of(file, root)) {
    for (const declaration of read_file(other).declarations) {
      visible.set(declaration.name, [...(visible.get(declaration.name) ?? []), declaration]);
    }
  }
  language_declarations ??= language_again().declarations;
  const in_language = new Set(language_declarations.map((declaration) => declaration.name));
  const included = new Map(own.declarations.map((declaration) => [declaration.name, declaration]));
  for (const declaration of own.declarations) {
    if (in_language.has(declaration.name)) problems.push(declaration.name + ' is declared in language.etale');
  }
  const waiting = [...own.declarations];
  while (waiting.length > 0) {
    for (const name of names_used(waiting.pop())) {
      if (included.has(name) || in_language.has(name) || name === 'Integer' || name === 'Decimal') continue;
      const found = visible.get(name) ?? [];
      if (found.length > 1) problems.push(name + ' is declared in ' + found.map((each) => each.file).join(' and '));
      if (found.length === 0) continue;
      included.set(name, found[0]);
      waiting.push(found[0]);
    }
  }
  const declarations = [...included.values()];
  const heads = new Set(seed.map((rule) => rule.head));
  const made = rules_of(declarations, [...language_declarations, ...declarations], heads);
  const declared = new Map([...language_declarations, ...declarations].map((each) => [each.name, each]));
  const rules = [...seed, ...made.rules];
  return { ...own, rules, left_out: made.left_out, declared, problems: [...problems, ...refusals(rules, declared)] };
}

const commands = {
  self() {
    const again = language_again();
    const same = again.count === 1 && stored_form(again.rules) === stored_form(seed);
    console.log(again.count === 1
      ? 'language.etale reads as File in one way, and its reading gives '
        + (same ? 'the stored rules back (' + seed.length + ' rules)' : 'other rules: run "seed"')
      : 'language.etale does not read as File in one way (' + again.count + ')');
    return same ? 0 : 1;
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
      return problems.length > 0 || commands.self();
    }
    const loaded = load(path.resolve(file));
    if (loaded.count !== 1) {
      console.log(file + ': does not read as File in one way (' + loaded.count + ')');
      return 1;
    }
    for (const problem of loaded.problems) console.log(problem);
    console.log(file + ': ' + loaded.declarations.length + ' declarations, ' + loaded.problems.length + ' problems');
    return loaded.problems.length > 0 ? 1 : 0;
  },
  read(type, file, data) {
    const loaded = load(path.resolve(file));
    const ways = reader(loaded.rules).ways(type, fs.readFileSync(data, 'utf8'));
    console.log(['refused', 'accepted', 'two readings'][ways]);
    return ways === 1 ? 0 : 1;
  },
  rules(file) {
    const loaded = load(path.resolve(file));
    const own = new Set(loaded.declarations.map((declaration) => declaration.name));
    for (const rule of loaded.rules) if (own.has(rule.head.split('.')[0])) console.log(in_words(rule));
    for (const what of loaded.left_out) console.log('not carried: ' + what);
    return 0;
  },
};

if (process.argv[1] && path.resolve(process.argv[1]) === new URL(import.meta.url).pathname) {
  const [name, ...rest] = process.argv.slice(2);
  if (!commands[name]) {
    console.log('commands: ' + Object.keys(commands).join(', '));
    process.exit(2);
  }
  process.exit(commands[name](...rest));
}
