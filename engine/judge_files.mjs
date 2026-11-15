// The file judge: main's checker against the new engine on the errors of files. CI runs it
// after tools/build_ide.sh:   node engine/judge_files.mjs
//
// The files are every .etale file of the library and the examples, and mistakes made from
// each of them, one change at a time: a type renamed to one that is nowhere, the last
// declaration moved to the top, a field renamed to a reserved word, a field line written
// twice, the last field of a record moved first, a path step renamed, a case of a mapping
// dropped or written twice, and the bounds of a range changed.
//
// For each file, main's errors and the engine's errors are compared as sets of lines, in
// main's words. An error of a kind that the engine carries must be the same in both, or the
// run fails. An error of another kind is counted as not carried yet.
import fs from 'node:fs';
import path from 'node:path';
import { Worker, isMainThread } from 'node:worker_threads';
import { home, load } from './etale.mjs';
import { file_errors, carried_kind } from './file_checks.mjs';
import { main_checker } from './main.mjs';
import { mistakes_of } from './mistakes.mjs';

if (isMainThread) {
  const worker = new Worker(new URL(import.meta.url), { resourceLimits: { stackSizeMb: 512 } });
  worker.on('exit', (code) => { process.exitCode = code; });
  worker.on('error', (error) => { console.error(error); process.exitCode = 1; });
} else {
  process.exit(judge());
}

// With JUDGE_CACHE set to a file, main's errors are kept there between runs, by text.
function cached(checker) {
  const where = process.env.JUDGE_CACHE;
  const kept = where && fs.existsSync(where) ? JSON.parse(fs.readFileSync(where, 'utf8')) : {};
  return {
    errors(file, text) {
      const key = file + '\n' + text;
      if (!kept[key]) kept[key] = checker.errors(file, text);
      return kept[key];
    },
    save: () => where && fs.writeFileSync(where, JSON.stringify(kept)),
  };
}

function judge() {
  const began = performance.now();
  const checker = main_checker();
  const from_cache = cached(checker);
  const files = Object.keys(checker.files).filter((name) => name.endsWith('.etale') && name !== '/priv/language.etale')
    .map((name) => name.slice(1)).sort();
  const totals = { files: 0, main: 0, same: 0, not_carried: 0, failing: 0 };
  const not_carried = new Map();
  const same = new Map();
  const kind_of = (error) => error.replace(/^[^ ]* (error: )?/, '').replace(/ \[[^\]]*\]$/, '')
    .replace(/'[^']*'|"[^"]*"|\d+(\.\d+)?/g, '_').slice(0, 70);
  const failing = [];
  for (const file of files) {
    const text = checker.files['/' + file];
    for (const [change, changed] of [['as it is', text], ...mistakes_of(text)]) {
      totals.files++;
      const from_main = from_cache.errors(file, changed);
      let from_engine;
      try {
        from_engine = file_errors(load(path.join(home, file), changed));
      } catch (error) {
        from_engine = ['the engine failed: ' + error.message];
      }
      totals.main += from_main.length;
      // main stops loading on a mistake that the engine does not look for yet: the engine's
      // errors for that text are not compared
      const stopped = from_main.length === 1 && /^[^ ]*:\d+:\d+: /.test(from_main[0]) && !carried_kind(from_main[0]);
      if (stopped) from_engine = [];
      for (const error of from_main) {
        if (from_engine.includes(error)) {
          totals.same++;
          same.set(kind_of(error), (same.get(kind_of(error)) ?? 0) + 1);
        }
        else if (carried_kind(error)) failing.push([file, change, 'main only: ' + error]);
        else {
          totals.not_carried++;
          not_carried.set(kind_of(error), (not_carried.get(kind_of(error)) ?? 0) + 1);
        }
      }
      for (const error of from_engine) {
        if (!from_main.includes(error)) failing.push([file, change, 'engine only: ' + error]);
      }
    }
  }
  from_cache.save();
  totals.failing = failing.length;
  const seconds = Math.round((performance.now() - began) / 1000);
  const lines = [
    totals.files + ' files (' + files.length + ' as they are, the rest with one mistake each): main reports '
      + totals.main + ' errors; the engine reports ' + totals.same + ' of them the same, '
      + totals.not_carried + ' are of kinds not carried yet',
    '',
    'the same, by kind:',
    ...[...same].sort((a, b) => b[1] - a[1]).map(([kind, count]) => '  ' + count + ' x ' + kind),
    '',
    'not carried yet, by kind:',
    ...[...not_carried].sort((a, b) => b[1] - a[1]).map(([kind, count]) => '  ' + count + ' x ' + kind),
    '',
    ...failing.slice(0, Number(process.env.JUDGE_SHOW ?? 40)).map(([file, change, what]) => 'FAILING ' + file + ' (' + change + '): ' + what),
  ];
  const verdict = (failing.length ? 'The file judge: ' + failing.length + ' FAILING differences'
    : 'The file judge: every error of a carried kind the same as main') + ' (' + seconds + ' s).';
  console.log(lines.join('\n') + '\n' + verdict);
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, '## The file judge\n\n```\n' + lines.join('\n') + '\n```\n\n'
      + verdict + '\n');
  }
  if (process.env.GITHUB_ACTIONS) console.log((failing.length ? '::error' : '::notice') + ' title=File judge::' + verdict);
  return failing.length ? 1 : 0;
}
