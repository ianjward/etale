// The judge: main's checker, compiled by Gleam, against the new engine. CI runs it after
// tools/build_ide.sh has built dist/workspace.html:   node engine/judge.mjs
//
// It compares the verdicts accepted, refused and two readings on:
//   A. every type of language.etale against a pool of texts;
//   B. every file of the library and the examples: its own types against the pool, and
//      against the data texts of its folder with near misses.
// A type is fully carried when nothing that it reaches has a line that the rules leave out.
// A difference on a fully carried type fails the run. Other differences are counted, with main's
// reason: they come from lines that the engine does not carry yet.
import fs from 'node:fs';
import path from 'node:path';
import { Worker, isMainThread } from 'node:worker_threads';
import { home, seed, load, language_again } from './etale.mjs';
import { reader } from './read.mjs';

if (isMainThread) {                                   // main's checker needs a deep stack
  const worker = new Worker(new URL(import.meta.url), { resourceLimits: { stackSizeMb: 512 } });
  worker.on('exit', (code) => { process.exitCode = code; });
  worker.on('error', (error) => { console.error(error); process.exitCode = 1; });
} else {
  process.exit(judge());
}

// Main's checker, from the page that tools/build_ide.sh builds.
function main_checker() {
  const page = fs.readFileSync(path.join(home, 'dist', 'workspace.html'), 'utf8');
  const scripts = [...page.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((match) => match[1]);
  globalThis.window = globalThis;
  (0, eval)(scripts.find((script) => script.includes('window.ETALE_FILES')));
  const bundle = scripts.find((script) => script.includes('__defs'));
  (0, eval)(bundle.replace(/window\.__etale = __load\([^)]*\);/, 'globalThis.__load = __load;'));
  const program = globalThis.__load('etale/program.mjs');
  const dictionary = globalThis.__load('../gleam_stdlib/gleam/dict.mjs');
  const to_list = globalThis.__load('gleam.mjs').toList;
  const files = globalThis.ETALE_FILES;
  const nothing = program.memory_fs(dictionary.new$(), '/', '/', '');
  const start = program.new$(files['/priv/language.etale'], nothing, true)[0];
  const all = program.memory_fs(dictionary.from_list(to_list(Object.entries(files))), '/', '/', '/priv/stdlib');
  const base = new program.Program(start.decls, start.order, start.index, start.files, start.loaded,
    start.main_file, start.grammar, start.ev, start.prelude_report, start.report, all);
  return {
    files,
    load(file) {
      const result = program.load(base, '/' + file);
      return result.isOk() ? result[0][0] : null;
    },
    base,
    verdict(program_of_file, type, text) {
      const outcome = program.check(program_of_file, type, text);
      const verdict = outcome.ambiguous ? 'two readings' : outcome.ok ? 'accepted' : 'refused';
      return { verdict, reason: [outcome.error, ...new Set(outcome.failures.toArray())].filter(Boolean).join('; ') };
    },
  };
}

// The pool: whole files, blocks, lines, words, boxes and parentheses of every file, some texts
// written by hand, and near misses made by dropping or doubling one character.
function pool_of(texts) {
  const pool = new Set(['', ' ', '  ', '\n', ' \n', '5..1', '1..5', '5..5', '0..23', '1.5..1.50', '-3..-5',
    '-5..-3', '..5', '5..', '007', '-0', '1.50', '-12.5', 'TRUE', 'FALSE', '"a\\"b"', '"a"b"', 'a.b.c', 'a.b',
    'A.b', 'x in 1 | 2', 'a & b | c', 'a > 0 & b > 0', 'a = 1 | b = 1', 'a + b + c', 'a + b * c', 'a / b',
    '{A & B}', '{A | B}', '{}', '{"x"}', '{5}', '{Stop...}', ' (0..23)', ' (5..1)', ' count: 1..', ' count: 3..1',
    '"A".."Z"', '09:20', '9:20', '24:00', '2024-02-29', '2023-02-29', '19.99', '19.9']);
  const lines = [...new Set(texts.flatMap((text) => text.split('\n')))];
  lines.forEach((line, index) => {
    if (index % 3 === 0) pool.add(line + '\n');
    if (index % 7 === 1) pool.add(line);
    for (const match of line.matchAll(/\(([^()]*)\)|\{[^{}]*\}/g)) pool.add(match[1] ?? match[0]);
  });
  const words = [...new Set(lines.flatMap((line) => line.trim().split(/ +/)))].filter(Boolean);
  words.forEach((word, index) => { if (index % 4 === 0) pool.add(word); });
  for (const text of texts) {
    pool.add(text);
    text.split(/\n\n+/).forEach((block, index) => { if (index % 4 === 0 && block.length < 2000) pool.add(block + '\n'); });
  }
  [...pool].forEach((text, index) => {
    if (index % 5 !== 0 || text.length < 2) return;
    const at = (index * 7) % text.length;
    pool.add(text.slice(0, at) + text.slice(at + 1));
    pool.add(text.slice(0, at) + text[at] + text.slice(at));
  });
  return [...pool];
}

// The heads that a head reaches through the parts of its rules.
function reaches(rules) {
  const parts_of = new Map();
  for (const rule of rules) {
    parts_of.set(rule.head, [...(parts_of.get(rule.head) ?? []), ...rule.parts.flatMap((part) => part.types ?? [])]);
  }
  const memo = new Map();
  return (head) => {
    if (memo.has(head)) return memo.get(head);
    const seen = new Set([head]);
    const waiting = [head];
    while (waiting.length > 0) {
      for (const next of parts_of.get(waiting.pop()) ?? []) if (!seen.has(next)) { seen.add(next); waiting.push(next); }
    }
    memo.set(head, seen);
    return seen;
  };
}

function judge() {
  const began = performance.now();
  const checker = main_checker();
  const texts_of = (folder, ending) => Object.entries(checker.files)
    .filter(([name]) => name.startsWith(folder) && name.endsWith(ending)).map(([, text]) => text);
  const pool = pool_of(texts_of('/', '.etale').concat(texts_of('/', '.txt')));
  const groups = [];
  let failures = 0;

  function compare(title, host, engine_rules, types, texts, left_out) {
    const ways = reader(engine_rules);
    const reach = reaches(engine_rules);
    const owners_left_out = new Set(left_out.map((line) => line.split(/[ .]/)[0]));
    const carried = (type) => ![...reach(type)].some((head) => owners_left_out.has(head.split('.')[0]));
    const group = { title, types: types.length, texts: texts.length, pairs: 0, same: 0, differ: new Map(),
      failing: 0, by_rules: 0 };
    for (const text of texts) {
      for (const type of types) {
        const from_host = checker.verdict(host, type, text);
        const from_engine = ['refused', 'accepted', 'two readings'][ways.ways(type, text)];
        group.pairs++;
        if (from_host.verdict === from_engine) { group.same++; continue; }
        // Expected until rules are carried: main refuses by a rule, or picks one of the
        // engine's readings by one. Anything else, or any difference on a fully carried type,
        // fails the run.
        const by_rules = from_host.reason.startsWith('the text has the right shape but breaks rules')
          || (from_host.verdict === 'accepted' && from_engine === 'two readings');
        const failing = carried(type) || !by_rules;
        if (failing) group.failing++;
        else group.by_rules++;
        const key = (failing ? 'FAILING ' : '') + type + ': main ' + from_host.verdict
          + (from_host.verdict === 'refused' ? ' (' + from_host.reason + ')' : '') + ', engine ' + from_engine;
        const entry = group.differ.get(key) ?? { count: 0, example: text };
        entry.count++;
        group.differ.set(key, entry);
      }
    }
    failures += group.failing;
    groups.push(group);
  }

  // A. language.etale.
  const language_types = [...new Set(seed.map((rule) => rule.head))].filter((head) => !/[."]/.test(head));
  const language_left_out = language_again().left_out;
  compare('language.etale', checker.base, seed, language_types, pool, language_left_out);

  // B. The library and the examples.
  const theory_files = Object.keys(checker.files).filter((name) => name.endsWith('.etale') && name !== '/priv/language.etale')
    .map((name) => name.slice(1)).sort();
  for (const file of theory_files) {
    const host = checker.load(file);
    const engine = load(path.join(home, file));
    if (!host || engine.count !== 1) {
      groups.push({ title: file, note: (host ? '' : 'main does not load it; ') + (engine.count === 1 ? '' : 'the engine does not read it') });
      continue;
    }
    const folder = '/' + path.dirname(file) + '/';
    const data = Object.entries(checker.files).filter(([name]) => name.startsWith(folder) && name.endsWith('.txt'))
      .map(([, text]) => text);
    const near = data.flatMap((text) => Array.from({ length: Math.min(12, text.length) }, (_, index) => {
      const at = 3 + Math.floor((index * (text.length - 3)) / 12);
      return [text.slice(0, at) + text.slice(at + 1), text.slice(0, at) + text[at] + text.slice(at)];
    }).flat());
    const types = engine.declarations.map((declaration) => declaration.name);
    compare(file, host, engine.rules, types, [...new Set([...pool, ...data, ...near])], engine.left_out);
  }

  // The report: the log, the step summary, and notes on the run.
  const summary = [];
  const details = [];
  const total = { pairs: 0, same: 0, by_rules: 0 };
  for (const group of groups) {
    if (group.note !== undefined) { summary.push(group.title + ': skipped, ' + group.note); continue; }
    total.pairs += group.pairs;
    total.same += group.same;
    total.by_rules += group.by_rules;
    summary.push(group.title + ': ' + group.types + ' types x ' + group.texts + ' texts, ' + group.same + ' of '
      + group.pairs + ' the same' + (group.by_rules ? ', ' + group.by_rules + ' by rules not carried' : '')
      + (group.failing ? ', ' + group.failing + ' FAILING' : ''));
    const differ = [...group.differ].sort((a, b) => Number(b[0].startsWith('FAILING')) - Number(a[0].startsWith('FAILING'))
      || b[1].count - a[1].count);
    if (differ.length) details.push(group.title + ':');
    for (const [key, { count, example }] of differ.slice(0, 6)) {
      details.push('    ' + count + ' x ' + key.slice(0, 240) + ', e.g. ' + JSON.stringify(example.slice(0, 60)));
    }
  }
  const seconds = Math.round((performance.now() - began) / 1000);
  summary.push('all: ' + total.same + ' of ' + total.pairs + ' the same, ' + total.by_rules + ' by rules not carried');
  const verdict_line = (failures === 0
    ? 'The judge: every difference comes from a rule that the engine does not carry yet'
    : 'The judge: ' + failures + ' FAILING differences') + ' (' + seconds + ' s).';
  const lines = [...summary, '', ...details];
  console.log(lines.join('\n') + '\n' + verdict_line);
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, '## The new engine against main\n\n```\n' + lines.join('\n')
      + '\n```\n\n' + verdict_line + '\n');
  }
  if (process.env.GITHUB_ACTIONS) {
    const escape = (text) => text.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
    const chunks = [summary.join('\n')];
    for (let index = 0; index < details.length; index += 14) chunks.push(details.slice(index, index + 14).join('\n'));
    chunks.slice(0, 8).forEach((chunk, index) => console.log('::notice title=Judge ' + (index + 1) + '::' + escape(chunk)));
    console.log((failures ? '::error' : '::notice') + ' title=Judge verdict::' + verdict_line);
  }
  return failures === 0 ? 0 : 1;
}
