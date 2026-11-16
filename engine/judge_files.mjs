// The file judge: main's checker against the new engine on the errors of files. CI runs it
// after tools/build_ide.sh:   node engine/judge_files.mjs
//
// The files are every .etale file of the library and the examples, and mistakes made from
// each of them, one change at a time: a type renamed to one that is nowhere, the last
// declaration moved to the top, a field renamed to a reserved word, a field line written
// twice, the last field of a record moved first, a path step renamed, a case of a mapping
// dropped or written twice, the bounds of a range changed, 'places:' lowered by one, 'round: 1'
// added to a calculation, and a text compared with '<'.
//
// For each file the verdict must be the same: refused by both, or by neither, or the run
// fails. The engine's words are its own; main's words only sort main's errors into the kinds
// that the engine carries and those it does not yet. A file that main refuses only for a kind
// not carried is counted, not judged. How many files also have their errors on the same lines
// is printed. A file on which main's checker itself fails is listed and not judged.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { Worker, isMainThread } from 'node:worker_threads';
import { home, load } from './etale.mjs';
import { file_errors } from './file_checks.mjs';
import { main_checker } from './main.mjs';
import { mistakes_of } from './mistakes.mjs';

// The kinds of error that the engine carries, by main's words. An error of one of these kinds
// must be the same in both, or the run fails.
const carried = [
  /: unknown type '/, /: type '.*' is used before it is declared/, /refers to itself; only a record field/,
  /a record may use its own type only as a list/, /' is reserved \(/, /: field '.*' is declared twice/,
  /\{Needs\}' has no condition/, /: unknown field '/, /cannot refer to itself/, /is declared below '/,
  /is a list: read it with a method/, /a method ends the path/, /' reads a list, but /, /' takes a list of numbers/,
  /' has no field '/, /' has no fields /, /' is not a record, so '/, /is not declared above this line/,
  /has more than one inhabitant, so it is not a value/, /, so it must always sit inside /, /a relation between two lists/,
  /two lists are related with in only/, /a relation is between two/, /are compared as single numbers or texts/,
  /: a relation compares fields of the same type/,
  /files use each other in a cycle/, /is already declared \(first declared at/, /is a built-in type/,
  /mapping input '/, /a case output is a singleton/, /^[^ ]* error: case output /, /a case is a box/,
  /a case predicate /, /is constrained twice in one case/, /takes one of a set of values; compare it with/,
  /a value in this case is not a value of input/, /cases do not cover every input/, /cases are not disjoint/,
  /no case produces /, /' is not a single value/, /a case compares to a literal or a range/,
  /, not a number, so it cannot be /, /two texts compared with /, /' applies only to numeric values/,
  /wrap_at: needs a constant above 0/, /a computed field produces a number/, /decimal places but the field holds /,
  /^[^ ]* error: nothing to round: /, /a product may read at most one factor/, /a quotient may not read both/,
  /the val range does not fit what the layout holds/, /a kept list keeps some items of a list of records/,
];
const carried_kind = (error) => carried.some((kind) => kind.test(error));

if (isMainThread) {
  const worker = new Worker(new URL(import.meta.url), { resourceLimits: { stackSizeMb: 512 } });
  worker.on('exit', (code) => { process.exitCode = code; });
  worker.on('error', (error) => { console.error(error); process.exitCode = 1; });
} else {
  process.exit(judge());
}

// A file and its text, as the printed lines below name them.
function key(file, text) {
  return file + ' ' + createHash('sha256').update(text).digest('hex').slice(0, 16);
}

// Main's errors for a file. With JUDGE_CACHE set to a file, they are kept there between runs,
// by text. A run started by hand in CI ('gh workflow run site.yml --ref BRANCH') prints them,
// one line a file: 'main ["FILE HASH", [errors]]'. With JUDGE_MAIN set to a saved log of such a
// run, the judge takes main's errors from those lines and needs no Gleam. A file that the run
// did not print, such as one made by a newer mistakes.mjs, is counted and not judged.
function main_side() {
  if (process.env.JUDGE_MAIN) {
    const printed = new Map();
    for (const [, line] of fs.readFileSync(process.env.JUDGE_MAIN, 'utf8').matchAll(/main (\[".*\])\s*$/gm)) {
      printed.set(...JSON.parse(line));
    }
    const files = {};
    const walk = (folder) => {
      for (const entry of fs.readdirSync(path.join(home, folder), { withFileTypes: true })) {
        const name = folder + '/' + entry.name;
        if (entry.isDirectory()) walk(name);
        else if (name.endsWith('.etale')) files['/' + name] = fs.readFileSync(path.join(home, name), 'utf8');
      }
    };
    walk('priv');
    walk('examples');
    return { files, errors: (file, text) => printed.get(key(file, text)) ?? null, save() {} };
  }
  const checker = main_checker();
  const where = process.env.JUDGE_CACHE;
  const kept = where && fs.existsSync(where) ? JSON.parse(fs.readFileSync(where, 'utf8')) : {};
  return {
    files: checker.files,
    errors(file, text) {
      const at = file + '\n' + text;
      try {
        kept[at] ??= checker.errors(file, text);
      } catch (failure) {
        kept[at] = ['main failed: ' + failure.message];
      }
      return kept[at];
    },
    save: () => where && fs.writeFileSync(where, JSON.stringify(kept)),
  };
}

function judge() {
  const began = performance.now();
  const from_cache = main_side();
  const print = process.env.GITHUB_EVENT_NAME === 'workflow_dispatch';
  const files = Object.keys(from_cache.files).filter((name) => name.endsWith('.etale') && name !== '/priv/language.etale')
    .map((name) => name.slice(1)).sort();
  const totals = { files: 0, main: 0, same: 0, same_lines: 0, not_carried: 0, failing: 0, not_printed: 0 };
  const not_carried = new Map();
  const same = new Map();
  const kind_of = (error) => error.replace(/^[^ ]* (error: )?/, '').replace(/ \[[^\]]*\]$/, '')
    .replace(/'[^']*'|"[^"]*"|\d+(\.\d+)?/g, '_').slice(0, 70);
  const failing = [];
  const main_failed = [];
  for (const file of files) {
    const text = from_cache.files['/' + file];
    for (const [change, changed] of [['as it is', text], ...mistakes_of(text)]) {
      const from_main = from_cache.errors(file, changed);
      if (from_main === null) {
        totals.not_printed++;
        continue;
      }
      if (print) console.log('main ' + JSON.stringify([key(file, changed), from_main]));
      // main's checker itself fails on a few files: they are listed, and not judged
      if (from_main[0]?.startsWith('main failed: ')) {
        main_failed.push(file + ' (' + change + '): ' + from_main[0]);
        continue;
      }
      totals.files++;
      let from_engine;
      try {
        from_engine = file_errors(load(path.join(home, file), changed));
      } catch (error) {
        from_engine = ['the engine failed: ' + error.message];
      }
      totals.main += from_main.length;
      // main stops loading on a mistake that the engine does not look for yet: not judged
      const carried_main = from_main.filter(carried_kind);
      if (carried_main.length === 0 && from_main.length) {
        totals.not_carried++;
        for (const error of from_main) not_carried.set(kind_of(error), (not_carried.get(kind_of(error)) ?? 0) + 1);
        continue;
      }
      // the verdict must be the same: the file refused by both, or by neither
      if (carried_main.length && !from_engine.length) failing.push([file, change, 'main only: ' + carried_main[0]]);
      else if (!from_main.length && from_engine.length) failing.push([file, change, 'engine only: ' + from_engine[0]]);
      else {
        totals.same++;
        const line_of = (error) => error.match(/^[^ ]*?:(\d+):/)?.[1];
        const engine_lines = new Set(from_engine.map(line_of));
        if (carried_main.every((error) => engine_lines.has(line_of(error)))) totals.same_lines++;
        for (const error of carried_main) same.set(kind_of(error), (same.get(kind_of(error)) ?? 0) + 1);
      }
    }
  }
  from_cache.save();
  totals.failing = failing.length;
  const seconds = Math.round((performance.now() - began) / 1000);
  const lines = [
    totals.files + ' files (' + files.length + ' as they are, the rest with one mistake each): the same verdict on '
      + totals.same + ' (' + totals.same_lines + ' of them with every error on the same line); '
      + totals.not_carried + ' refused by main for a kind of error not carried yet'
      + (totals.not_printed ? '; ' + totals.not_printed + ' files are not in the printed log' : ''),
    '',
    'the same verdict, by kind of error from main:',
    ...[...same].sort((a, b) => b[1] - a[1]).map(([kind, count]) => '  ' + count + ' x ' + kind),
    '',
    'not carried yet, by kind:',
    ...[...not_carried].sort((a, b) => b[1] - a[1]).map(([kind, count]) => '  ' + count + ' x ' + kind),
    '',
    ...main_failed.map((what) => 'MAIN FAILED, not judged: ' + what),
    ...failing.slice(0, Number(process.env.JUDGE_SHOW ?? 40)).map(([file, change, what]) => 'FAILING ' + file + ' (' + change + '): ' + what),
  ];
  const verdict = (failing.length ? 'The file judge: ' + failing.length + ' FAILING differences'
    : 'The file judge: every verdict the same as main') + ' (' + seconds + ' s).';
  console.log(lines.join('\n') + '\n' + verdict);
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, '## The file judge\n\n```\n' + lines.join('\n') + '\n```\n\n'
      + verdict + '\n');
  }
  if (process.env.GITHUB_ACTIONS) console.log((failing.length ? '::error' : '::notice') + ' title=File judge::' + verdict);
  return failing.length ? 1 : 0;
}
