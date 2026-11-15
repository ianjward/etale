// The engine's tests. They need only node:   node engine/test.mjs
import fs from 'node:fs';
import path from 'node:path';
import { home, language, seed, read_file, language_again, stored_form, load } from './etale.mjs';
import { reader } from './read.mjs';
import { file_errors } from './file_checks.mjs';

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

// 7. Worked-out fields, rules, claims and mappings, which the judge compares with main.
const worked = [
  ['priv/stdlib/dates.etale', 'Date', '2024-02-29', 'accepted'],
  ['priv/stdlib/dates.etale', 'Date', '2023-02-29', 'refused'],          // a rule: valid = True
  ['priv/stdlib/dates.etale', 'Date', '1900-02-29', 'refused'],
  ['priv/stdlib/dates.etale', 'Date', '2000-02-29', 'accepted'],
  ['examples/book/book.etale', 'Book', 'examples/book/book_unknown.txt', 'refused'],   // a relation of two lists
  ['examples/xor/xor.etale', 'Assoc', 'examples/xor/xor_bc.txt', 'refused'],
  ['examples/xor/xor.etale', 'Assoc', 'examples/xor/xor_ab_c.txt', 'refused'],
  ['examples/timetable/timetable.etale', 'Stop', 'Oslo S 10:05 +12\n', 'refused'],      // no Train around it
  ['examples/timetable/timetable.etale', 'Stop', 'Oslo S 10:05 +1\n', 'accepted'],      // on time, so no Train is needed
  ['examples/mistakes/mistakes.etale', 'Grade', '60', 'refused'],         // two cases apply
  ['examples/mistakes/mistakes.etale', 'Grade', '70', 'accepted'],
  ['examples/mistakes/mistakes.etale', 'Pair', '65', 'refused'],          // a claim that is false here
  ['examples/mistakes/mistakes.etale', 'Label', '5', 'refused'],          // arithmetic on a text
  ['examples/mistakes/mistakes.etale', 'Note', 'a few words', 'refused'], // no Basket around it
  // 'unique:' and 'order:'
  ['examples/book/book.etale', 'Book', 'C001 Ann\nC001 Bo\n---\n1 C001\n', 'refused'],
  ['examples/timetable/timetable.etale', 'Train', 'R1 60\nAsker 02:00 +1\nLier 01:00 +2\n', 'refused'],
  ['examples/timetable/timetable.etale', 'Train', 'R1 60\nAsker 01:00 +1\nLier 01:00 +2\n', 'accepted'],
  ['examples/timetable/timetable.etale', 'Train', 'R1 60\nAsker 01:00 +1\nAsker 02:00 +2\n', 'refused'],
  ['examples/timetable/timetable.etale', 'Timetable', 'R1 60\nOslo 00:00 +1\nR2 60\nOslo S 01:00 +1\n---\nOslo\nOslo S\n', 'accepted'],
  ['examples/timetable/timetable.etale', 'Timetable', 'R1 60\nOslo 00:00 +1\nR2 60\nOslo S 01:00 +1\n---\nOslo S\nOslo\n', 'refused'],
  ['examples/timetable/timetable.etale', 'Timetable', 'R1 60\nasker 00:00 +1\nR2 60\nLier 01:00 +1\n---\nasker\nLier\n', 'accepted'],
];
for (const [file, type, data, expected] of worked) {
  if (!loaded.has(file)) loaded.set(file, reader(load(path.join(home, file)).rules));
  const text = data.includes('/') ? fs.readFileSync(path.join(home, data), 'utf8') : data;
  const got = verdict(loaded.get(file).ways(type, text));
  test(type + ' on ' + JSON.stringify(data) + ' is ' + expected, got === expected, got);
}
const value_of = (file, type, text, field) => {
  const { count, node } = (file ? reader(load(path.join(home, file)).rules) : language_reader).read(type, text);
  const value = count === 1 ? node.memo?.get(field) : undefined;
  return value?.top !== undefined ? Number(value.top) / Number(value.bottom) : value;
};
const stops = (...delays) => 'R10 60\n' + delays.map((delay, index) =>
  ['Asker', 'Lier', 'Drammen', 'Oslo S'][index] + ' 0' + index + ':00 +' + delay + '\n').join('');
const values = [
  ['examples/timetable/timetable.etale', 'Train', stops(1, 0, 0, 0), 'average_delay', 0.2],   // a tie goes to even
  ['examples/timetable/timetable.etale', 'Train', stops(3, 0, 0, 0), 'average_delay', 0.8],
  ['examples/timetable/timetable.etale', 'Train', stops(1, 1, 2), 'average_delay', 1.3],
  ['examples/timetable/timetable.etale', 'Train', stops(3, 0, 9), 'late_stop_count', 2],
  ['examples/timetable/timetable.etale', 'Time', '23:50', 'minutes', 1430],
  ['priv/stdlib/dates.etale', 'Date', '2023-02-28', 'r4', 3],                              // wrap_at: 4
  ['priv/stdlib/bits.etale', 'Byte', '01000001', 'number', 65],
  ['examples/train/train.etale', 'Journey', fs.readFileSync(path.join(home, 'examples/train/journey.txt'), 'utf8'), 'delay', 19],
  [null, 'And_Gate', 'TRUEFALSE', 'out', 'FALSE'],                                         // a mapping in the seed
];
for (const [file, type, text, field, expected] of values) {
  const got = value_of(file, type, text, field);
  test(type + '.' + field + ' on ' + JSON.stringify(text.slice(0, 20)) + ' is ' + expected, got === expected, String(got));
}

// 8. The checks on a file, in main's words (the file judge compares them with main).
const errors_of = (file, text) => file_errors(load(path.join(home, file), text));
const mistakes = errors_of('examples/mistakes/mistakes.etale').map((error) => error.replace(/^[^:]*:/, ''));
for (const expected of [
  "4: error: type 'Later' is used before it is declared (line 5); a name resolves only to a type declared above [Early]",
  "9: error: 'value' is reserved (value, text, count, sum, min, max) and cannot name a field [Bad_Name.value]",
  "13: error: field 'b' is declared below 'a'; a field may name only fields above it [Wrong_Order.a]",
  '19: error: items is a list: read it with a method, .count or .sum [Basket.has_four]',
  '24: error: cases do not cover every input combination; missing: score = 40; score = 41 [Grade.pass]',
  '24: error: cases are not disjoint: score = 49 matches cases 3, 4 [Grade.pass]',
  "58: error: 'Note' reaches Basket.items, so it must always sit inside a Basket, but nothing holds it inside one [Note]",
]) test('mistakes.etale:' + expected.slice(0, 70), mistakes.includes(expected), mistakes.join('\n'));
const clean = files.map((file) => path.relative(home, file))
  .filter((file) => !/mistakes|cycle|peek/.test(file) && !file.endsWith('language.etale'));
const unclean = clean.filter((file) => errors_of(file).length > 0);
test('the other ' + clean.length + ' files have no errors', unclean.length === 0, unclean.join(', '));
test('a.etale and b.etale use each other', errors_of('examples/cycle/a.etale')[0]?.includes('files use each other in a cycle'));
test('peek.etale does not see Code', errors_of('examples/shop/orders/peek.etale')[0]?.endsWith("unknown type 'Code' [Peek]"));
const book = fs.readFileSync(path.join(home, 'examples/book/book.etale'), 'utf8');
test('a relation names a field the items have', errors_of('examples/book/book.etale', book.replace('customers.code)',
  'customers.nowhere)'))[0]?.endsWith("'Customer' has no field 'nowhere' [Book.each_order_has_its_customer]"));
test('a name of the language may not be declared again', errors_of('examples/book/book.etale', book + 'Digit {"x"}\n')[0]
  ?.includes("type 'Digit' is already declared (first declared at language.etale:"));

// 9. The engine stays small: its own files, without the tests and the judges.
const code_lines = ['read', 'evaluate', 'declarations', 'rules', 'checks', 'file_checks', 'etale'].map((name) =>
  fs.readFileSync(path.join(home, 'engine', name + '.mjs'), 'utf8').split('\n')
    .filter((line) => line.trim() !== '' && !line.trim().startsWith('//')).length);
const total = code_lines.reduce((a, b) => a + b, 0);
test('the engine is at most 2,000 lines of code (' + total + ')', total <= 2000);

console.log(failed === 0 ? 'all tests passed' : failed + ' failed');
process.exit(failed === 0 ? 0 : 1);
