// Main's checker, compiled by Gleam: the judges load it from the page that tools/build_ide.sh
// builds. It needs a deep stack, so the judges run it in a worker.
import fs from 'node:fs';
import path from 'node:path';
import { home } from './etale.mjs';

// Main's checker, from the page that tools/build_ide.sh builds.
export function main_checker() {
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
  const render = globalThis.__load('etale/check.mjs').render;
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
      return { verdict, reason: [outcome.error, ...new Set(outcome.failures.toArray())].filter(Boolean).join('; '),
        records: outcome.ok ? outcome.records.toArray() : [] };
    },
    show: globalThis.__load('etale/evaluate.mjs').show,
    // The errors that main reports for a file, given its text: a file it cannot load gives its
    // one error, as 'file:line:col: message'; else each error in the file, as main prints it.
    errors(file, text) {
      const result = program.load_text(base, text, '/' + file);
      if (!result.isOk()) {
        const { msg, file: where, line, col } = result[0];
        return [where + ':' + line + ':' + col + ': ' + msg];
      }
      return result[0][1].diags.toArray().filter((diag) => diag.severity === 'error' && diag.file === file)
        .map(render);
    },
  };
}
