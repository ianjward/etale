// The judge: main's checker, compiled by Gleam, against the new engine. CI runs it after
// tools/build_ide.sh has built dist/workspace.html:   node engine/judge.mjs
//
// It compares the verdicts accepted, refused and two readings on:
//   A. every type of language.etale against a pool of texts;
//   B. every file of the library and the examples: its own types against the pool, against
//      the data texts of its folder with near misses, and against texts made for its
//      worked-out fields (made_texts).
// A type is fully carried when nothing that it reaches has a line that the rules leave out.
// A difference on a fully carried type fails the run. Other differences are counted, with main's
// reason: they come from lines that the engine does not carry yet.
//
// On every text that both accept, every field of every record must have the same value as in
// main, or the run fails.
import fs from 'node:fs';
import path from 'node:path';
import { Worker, isMainThread } from 'node:worker_threads';
import { home, seed, load, language_again } from './etale.mjs';
import { reader } from './read.mjs';
import { Exact, Sequence, INVALID, LATER, exact } from './evaluate.mjs';
import { main_checker } from './main.mjs';

if (isMainThread) {                                   // main's checker needs a deep stack
  const worker = new Worker(new URL(import.meta.url), { resourceLimits: { stackSizeMb: 512 } });
  worker.on('exit', (code) => { process.exitCode = code; });
  worker.on('error', (error) => { console.error(error); process.exitCode = 1; });
} else {
  process.exit(judge());
}

// The values of every field of every record, main's against the engine's: a list of
// differences, and how many values were compared.
function value_differences(checker, records, node) {
  const main_value = (value) => {
    const kind = value.constructor.name;
    if (kind === 'VNumber') return 'number ' + fraction(exact(checker.show(value)));
    if (kind === 'VText') return 'text ' + JSON.stringify(value[0]);
    if (kind === 'VRecord') return value[0].decl.name + ' at ' + value[0].node.s + '..' + value[0].node.e;
    if (kind === 'VSeqv') return '[' + value.items.toArray().map(main_value).join(', ') + ']';
    return kind === 'VInvalid' ? 'INVALID' : kind;
  };
  const engine_value = (value) => {
    if (value instanceof Exact) return 'number ' + fraction(value);
    if (typeof value === 'string') return 'text ' + JSON.stringify(value);
    if (value instanceof Sequence) return '[' + value.items.map(engine_value).join(', ') + ']';
    if (value === INVALID || value === LATER) return value.description;
    return value.head + ' at ' + value.start + '..' + value.end;
  };
  const engine_records = new Map();
  const visit = (value) => {
    if (value instanceof Sequence) return value.items.forEach(visit);
    const key = value?.head + ' at ' + value?.start + '..' + value?.end;
    if (!value?.rule?.record || engine_records.has(key)) return;
    engine_records.set(key, value);
    for (const each of value.memo?.values() ?? []) visit(each);
  };
  for (let at = node; at; at = at.rule?.parts.length === 1 && !at.rule.record ? at.values[0] : null) visit(at);
  const differences = [];
  let compared = 0;
  for (const record of records) {
    const key = record.decl.name + ' at ' + record.node.s + '..' + record.node.e;
    const found = engine_records.get(key);
    if (!found) { differences.push(key + ': no such record in the engine'); continue; }
    for (const [name, value] of record.cache) {
      if (!found.memo?.has(name)) continue;          // main's own names, such as '2.' or 'stops.count'
      compared++;
      const [mine, theirs] = [engine_value(found.memo.get(name)), main_value(value)];
      if (mine !== theirs) differences.push(key + ' ' + name + ': main ' + theirs + ', engine ' + mine);
    }
  }
  return { differences, compared };
}
function fraction(number) {
  return number.top + (number.bottom === 1n ? '' : '/' + number.bottom);
}

// Texts made for the worked-out fields of the library and the examples: dates around leap
// years, every byte and every xor text, scores, windows, chains, and trains whose delays
// round in every way.
function made_texts(file) {
  const two = (number) => String(number).padStart(2, '0');
  const texts = [];
  const stations = ['Asker', 'Lier', 'Drammen', 'Oslo S', 'Sande', 'Holm', 'Skoger', 'Hokksund', 'Vestfossen', 'Kongsberg'];
  const train = (line, max, delays, kind) => line + (kind ? ' ' + kind : '') + ' ' + max + '\n'
    + delays.map((delay, index) => stations[index] + ' ' + two(index * 2) + ':' + two(index * 5) + ' +' + delay + '\n').join('');
  const delays = [[1, 0, 0, 0], [3, 0, 0, 0], [1, 1, 2], [2, 2, 1], [0, 0, 0, 0, 0, 0, 0, 0, 0, 5], [9, 10, 0],
    [60, 0, 0, 0, 0, 0, 0], [0], [12], [2, 30], [61, 0], [120]];
  if (file.endsWith('dates.etale')) {
    for (const year of ['0000', '1600', '1900', '2000', '2023', '2024', '2100', '9999']) {
      for (let month = 1; month <= 12; month++) for (let day = 1; day <= 31; day++) texts.push(year + '-' + two(month) + '-' + two(day));
    }
  }
  if (file.endsWith('bits.etale')) for (let number = 0; number < 256; number++) texts.push(number.toString(2).padStart(8, '0'));
  if (file.endsWith('xor.etale')) for (let number = 0; number < 2048; number++) texts.push(number.toString(2).padStart(11, '0'));
  if (file.endsWith('logic.etale')) texts.push('TRUETRUE', 'TRUEFALSE', 'FALSETRUE', 'FALSEFALSE');
  if (file.endsWith('mistakes.etale')) for (let number = 0; number <= 100; number++) texts.push(String(number), two(number % 10) + number);
  if (file.endsWith('proofs.etale')) {
    for (let start = 0; start <= 10; start += 3) for (let finish = 20; finish <= 30; finish += 4) texts.push(start + '..' + finish);
    texts.push('+1', '+1+2', '+9+9+9+9', '+0+0');
  }
  if (file.endsWith('temperature.etale')) for (let degrees = -90; degrees <= 60; degrees += 7) texts.push('oslo ' + degrees);
  if (file.includes('/timetable/') || file.includes('/train/')) {
    const kind = file.includes('/train/');
    for (const max of [10, 30, 60]) {
      delays.forEach((each, index) => texts.push(train('R1' + index, max, each, kind && (index % 2 ? 'slow' : 'fast'))));
    }
    for (const delay of [0, 1, 2, 9, 10, 20]) texts.push('Oslo S 23:50 +' + delay + '\n');
    // 'unique:' and 'order:': a station twice, stops out of time order or at the same time
    const head = 'R1' + (kind ? ' fast' : '') + ' 60\n';
    texts.push(head + 'Asker 00:00 +1\nAsker 01:00 +2\n', head + 'Asker 02:00 +1\nLier 01:00 +2\n',
      head + 'Asker 01:00 +1\nLier 01:00 +2\n', head + 'Lier 01:00 +1\nAsker 01:00 +2\n');
    if (kind) texts.push(train('R1', 60, [3, 4], 'fast') + train('R2', 30, [1, 2, 0], 'slow'));
    else {
      // an index in and out of the order of Station_Order.rank, where a space comes first
      // and "a" ranks with "A"
      // and "a" ranks with "A". One train stops at each station, so the index lists them all.
      for (const index of [['Asker', 'Lier'], ['Lier', 'Asker'], ['Oslo', 'Oslo S'], ['Oslo S', 'Oslo'],
        ['Oslo S', 'OsloA'], ['OsloA', 'Oslo S'], ['asker', 'Lier'], ['Lier', 'asker'], ['Asker', 'asker'],
        ['asker', 'Asker'], ['Asker', 'Asker'], ['Asker', 'Lier', 'Asker']]) {
        const trains = [...new Set(index)].map((station, at) => 'R' + (at + 1) + ' 60\n' + station + ' 0' + at + ':00 +1\n');
        texts.push(trains.join('') + '---\n' + index.join('\n') + '\n');
      }
    }
  }
  if (file.endsWith('book.etale')) texts.push('C001 Ann\nC001 Bo\n---\n1 C001\n', 'C001 Ann\nC002 Ann\n---\n1 C002\n');
  if (file.endsWith('orders/orders.etale') && !file.includes('/shop/')) {
    for (const units of [1, 3, 10, 999]) {
      for (const price of ['0.00', '1.99', '49.99', '500.00']) texts.push('order 7\nABC-1234 x' + units + ' @ ' + price + '\nXYZ-0001 x2 @ ' + price + '\n');
    }
  }
  if (file.includes('/shop/')) texts.push('2024-02-29\nABC123 19.99\nXYZ999 0.01\n', '2023-02-29\nABC123 19.99\n');
  return texts;
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
      failing: 0, by_rules: 0, values: 0 };
    for (const text of texts) {
      for (const type of types) {
        const from_host = checker.verdict(host, type, text);
        const reading = ways.read(type, text);
        const from_engine = ['refused', 'accepted', 'two readings'][reading.count];
        group.pairs++;
        if (from_host.verdict === 'accepted' && from_engine === 'accepted') {
          const { differences, compared } = value_differences(checker, from_host.records, reading.node);
          group.values += compared;
          for (const difference of differences) {
            group.failing++;
            const key = 'FAILING value ' + type + ': ' + difference;
            const entry = group.differ.get(key) ?? { count: 0, example: text };
            entry.count++;
            group.differ.set(key, entry);
          }
        }
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
    compare(file, host, engine.rules, types, [...new Set([...pool, ...data, ...near, ...made_texts(file)])], engine.left_out);
  }

  // The report: the log, the step summary, and notes on the run.
  const summary = [];
  const details = [];
  const total = { pairs: 0, same: 0, by_rules: 0, values: 0 };
  for (const group of groups) {
    if (group.note !== undefined) { summary.push(group.title + ': skipped, ' + group.note); continue; }
    total.pairs += group.pairs;
    total.same += group.same;
    total.by_rules += group.by_rules;
    total.values += group.values;
    summary.push(group.title + ': ' + group.types + ' types x ' + group.texts + ' texts, ' + group.same + ' of '
      + group.pairs + ' the same' + (group.by_rules ? ', ' + group.by_rules + ' by rules not carried' : '')
      + (group.values ? ', ' + group.values + ' values' : '') + (group.failing ? ', ' + group.failing + ' FAILING' : ''));
    const differ = [...group.differ].sort((a, b) => Number(b[0].startsWith('FAILING')) - Number(a[0].startsWith('FAILING'))
      || b[1].count - a[1].count);
    if (differ.length) details.push(group.title + ':');
    for (const [key, { count, example }] of differ.slice(0, 6)) {
      details.push('    ' + count + ' x ' + key.slice(0, 240) + ', e.g. ' + JSON.stringify(example.slice(0, 60)));
    }
  }
  const seconds = Math.round((performance.now() - began) / 1000);
  summary.push('all: ' + total.same + ' of ' + total.pairs + ' the same, ' + total.by_rules + ' by rules not carried; '
    + total.values + ' values of fields compared');
  const verdict_line = (failures > 0 ? 'The judge: ' + failures + ' FAILING differences'
    : total.same === total.pairs ? 'The judge: every verdict and every value the same as main'
    : 'The judge: every difference comes from a rule that the engine does not carry yet') + ' (' + seconds + ' s).';
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
