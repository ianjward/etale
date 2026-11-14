// The engine's tests. They need only node:   node engine/test.mjs
import fs from 'node:fs';
import path from 'node:path';
import { home, language, seed, read_file, language_again, stored_form, load } from './etale.mjs';
import { reader } from './read.mjs';

let failed = 0;
const test = (what, ok, detail = '') => {
  if (!ok) failed++;
  console.log((ok ? 'ok     ' : 'FAILED ') + what + (ok || !detail ? '' : ': ' + detail));
};
const verdict = (count) => ['refused', 'accepted', 'two readings'][count];
const timed = (work) => {
  const began = performance.now();
  const result = work();
  return [result, Math.round(performance.now() - began)];
};

// 1. The fixed point: the stored rules read language.etale, and its reading gives them back.
const [again, milliseconds] = timed(() => language_again());
test('language.etale reads as File in exactly one way (' + milliseconds + ' ms)', again.count === 1);
test('its reading gives back the stored rules (' + seed.length + ')', stored_form(again.rules) === stored_form(seed));
test('language.etale reads in under 5 seconds', milliseconds < 5000, milliseconds + ' ms');

// 2. Every file of the repository reads as File in exactly one way.
const files = [];
const walk = (folder) => {
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    const full = path.join(folder, entry.name);
    if (entry.isDirectory()) walk(full);
    else if (entry.name.endsWith('.etale')) files.push(full);
  }
};
walk(path.join(home, 'priv'));
walk(path.join(home, 'examples'));
const unread = files.filter((file) => read_file(file).count !== 1);
test('all ' + files.length + ' files read as File in exactly one way', unread.length === 0,
  unread.map((file) => path.relative(home, file)).join(', '));

// 3. The two refusals find nothing in language.etale, the library or the examples, except the
//    two files of examples/cycle, which use each other's types (main refuses them too).
const refused = [];
for (const file of files.filter((file) => file !== language)) {
  for (const problem of load(file).problems) refused.push(path.relative(home, file) + ': ' + problem);
}
const outside_cycle = refused.filter((problem) => !problem.startsWith('examples/cycle/'));
test('the two refusals find nothing outside examples/cycle', outside_cycle.length === 0, outside_cycle.join('; '));
test('they refuse both files of examples/cycle', ['a', 'b'].every((name) =>
  refused.some((problem) => problem.startsWith('examples/cycle/' + name + '.etale'))));

// 4. The two refusals on small theories (claude/etale-one-rule-shape-2026-11-14.md, section 8).
const theory = (text) => load(path.join(home, 'engine', 'test.etale'), text);
const loop = theory('Loop {}\n  more {Loop...}\n\nMarks {}\n  digit {Digit} count: 0..1\n'
  + '  rest {Marks} count: 0..1\n  text {Text}\n    1. {digit}\n    2. {rest}\n    3. {"!"}\n');
test('Loop and Marks can reach themselves before a character, and are refused',
  ['Loop', 'Marks'].every((name) => loop.problems.some((problem) => problem.includes(name + ' can reach itself'))),
  loop.problems.join('; '));
const digits = theory('Maybe_Digit {}\n  digit {Digit} count: 0..1\n\nDigits {}\n  items {Maybe_Digit...}\n');
test('a list whose item can be the empty text is refused',
  digits.problems.length === 1 && digits.problems[0].includes('Digits holds a list'), digits.problems.join('; '));
const fixed = theory('Digit_Item {}\n  digit {Digit} count: 0..1\n  text {Text}\n    1. {digit}\n    2. {";"}\n\n'
  + 'Digit_Items {}\n  items {Digit_Item...}\n');
test('the fix, a mark in each item, is not refused', fixed.problems.length === 0, fixed.problems.join('; '));
test('and it reads ";7;;" as three items in one way', reader(fixed.rules).ways('Digit_Items', ';7;;') === 1);

// 5. The data of the examples, as main's own tests read it.
const cases = [
  ['examples/book/book.etale', 'Book', 'examples/book/book.txt', 'accepted'],
  ['examples/orders/orders.etale', 'Order', 'examples/orders/order_1042.txt', 'accepted'],
  ['examples/timetable/timetable.etale', 'Timetable', 'examples/timetable/timetable.txt', 'accepted'],
  ['examples/train/train.etale', 'Journey', 'examples/train/journey.txt', 'accepted'],
  ['examples/xor/xor.etale', 'Assoc', 'examples/xor/xor.txt', 'accepted'],
  ['examples/temperature/temperature.etale', 'Reading', 'oslo -12', 'accepted'],
  ['examples/temperature/temperature.etale', 'Temperature', '-95', 'refused'],
  ['examples/meeting/meeting.etale', 'Meeting', '2024-02-29 room_4', 'accepted'],
  ['examples/shop/money.etale', 'Money', '19.99', 'accepted'],
  ['examples/shop/money.etale', 'Money', '19.9', 'refused'],
  ['examples/timetable/timetable.etale', 'Time', '09:20', 'accepted'],
  ['examples/timetable/timetable.etale', 'Time', '24:00', 'refused'],
  ['examples/timetable/timetable.etale', 'Time', '9:20', 'refused'],
];
const loaded = new Map();
for (const [file, type, data, expected] of cases) {
  if (!loaded.has(file)) loaded.set(file, reader(load(path.join(home, file)).rules));
  const text = data.includes('/') ? fs.readFileSync(path.join(home, data), 'utf8') : data;
  const got = verdict(loaded.get(file).ways(type, text));
  test(type + ' on ' + data + ' is ' + expected, got === expected, got);
}

// 6. What language.etale says of its own texts.
const language_reader = reader(seed);
const own = [
  ['Bounded_Range', '0..23', 'accepted'], ['Bounded_Range', '5..1', 'refused'],
  ['Bounded_Range', '5..5', 'refused'], ['File', 'X {Text}\n#' + 'a'.repeat(99) + '\n', 'accepted'],
  ['File', 'X {Text}\n#' + 'a'.repeat(100) + '\n', 'refused'], ['File', 'X {A | B & C}\n', 'refused'],
  ['File', 'X {{A}}\n', 'refused'], ['File', 'Stop {}\n delay {Integer}\n', 'refused'],
];
for (const [type, text, expected] of own) {
  const got = verdict(language_reader.ways(type, text));
  test(type + ' on ' + JSON.stringify(text.length > 30 ? text.slice(0, 30) + '...' : text) + ' is ' + expected,
    got === expected, got);
}

// 7. The engine stays small: its own files, without the tests and the judge.
const code_lines = ['read', 'declarations', 'rules', 'checks', 'etale'].map((name) =>
  fs.readFileSync(path.join(home, 'engine', name + '.mjs'), 'utf8').split('\n')
    .filter((line) => line.trim() !== '' && !line.trim().startsWith('//')).length);
const total = code_lines.reduce((a, b) => a + b, 0);
test('the engine is at most 2,000 lines of code (' + total + ')', total <= 2000);

console.log(failed === 0 ? 'all tests passed' : failed + ' failed');
process.exit(failed === 0 ? 0 : 1);
