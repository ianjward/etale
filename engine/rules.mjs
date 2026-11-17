// Declarations to rules of one shape (see read.mjs).
//
// A declaration is what declarations.mjs finds in a reading of a file:
//   { name, line, kind: 'union', items }
//   { name, line, kind: 'intersection', types }
//   { name, line, kind: 'refinement', items: [item], list, count, allowed, constant, places }
//   { name, line, kind: 'layout', items: [item], allowed, positions: [slot...] }
//   { name, line, kind: 'record', fields: [field...], shape: [slot...] or null }
// An item is { type }, { literal } or { characters: [first, last] }; a number literal also has
// number: true. A count is { least, most } and allowed values are [{ low, high }...], each a
// fixed value or null: { number } as written, { name } of a constant, or { op, terms } with
// + - * of fixed values. A slot is a position: { number, items, list, count }, or in a shape
// { number, field, digits }.
//
// A field is { name, line, role, items, list, count, allowed, places, ... }. Its role is stored,
// worked (value: a term, with round and wrap), kept (condition), collected (value: a path), rule
// or claim (condition), mapping (inputs and cases), or made (a record made from values:
// positions, one path for each stored field of the record). A term is { number }, { text },
// { path: [names] }, { op, terms }, { range: [low, high] }, { choice: [terms] } or
// { characters: [first, last] }. A condition is { all: [comparison...] } or { any: [...] }, and
// a comparison is { path, comparison, right: term }. Each declaration may list, in left_out,
// what its lines say that the rules do not carry.
//
// A record's rule holds its stored fields as named parts, and every other field in fields,
// with constants and types of one value written out as their values:
//   { name, value: term, round: { unit, direction }, wrap }      a worked-out value
//   { name, keep: list, condition }                              a kept list
//   { name, collect: [list, field] }                             a collected list
//   { name, make: type, fields: [stored names], values: [terms] } a made record
//   { name, inputs, cases: [{ output, when }] }                  a mapping
//   { name, needs: condition }  and  { name, claims: condition } a rule and a claim
// A field with 'while' has repeat: { condition, next: [terms], fields: [starred names], floors },
// and a field wrapped at a field has wrap_by: its path. A made list has each: true, one record
// for each item of the value marked all: true; a list from items is { name, list_of: [terms] }.
// A constant record is the term { constant: { name, make, fields, values } }, a constant list
// { list: [terms] }.
// A comparison between a field of the items of two lists of the record has relation: true.
// A stored list's part may have unique and order, each the path of a key of its items, and a
// stored text's part may have ranks: the rank of each character, from the mapping that its
// 'order:' names.
import { exact, plus, minus, times, decimal_text, term_words as term, condition_words as condition } from './evaluate.mjs';

const written_as = { Integer: 'Integer_Literal', Decimal: 'Decimal_Literal' };
const literal_numbers = ['Integer_Literal', 'Decimal_Literal', 'Number_Literal'];

// The rules of these declarations. The scope holds every declaration that they may name: it
// gives the constants and the allowed values of a type that a 'digits:' position names. Heads
// made before are heads of their own that other rules already have, so they are not made again.
export function rules_of(declarations, scope = declarations, heads_made_before = []) {
  const by_name = new Map(scope.map((declaration) => [declaration.name, declaration]));
  const constants = new Map();
  const rules = [];
  const left_out = [];
  const made = new Set(heads_made_before);

  const value_of = (expression) => fixed_value(expression, constants);
  const to_number = (fixed) => (fixed === null ? null : Number(fixed.top) / Number(fixed.bottom));
  const as_number = (expression) => to_number(value_of(expression));
  for (const declaration of scope) {
    if (declaration.constant === undefined) continue;
    try {
      constants.set(declaration.name, value_of(declaration.constant));
    } catch {
      // a worked-out line that is not fixed is not a constant
    }
  }
  const ranges_of = (allowed) => allowed.map(({ low, high }) => [as_number(low), as_number(high)]);
  const make = (head, list_of_rules) => {
    if (made.has(head)) return;
    made.add(head);
    rules.push(...list_of_rules());
  };

  // A type is numeric when its texts are numbers: Integer, Decimal, their literals, and what
  // refines them or picks among numbers.
  function numeric(name, seen = new Set()) {
    if (name in written_as || literal_numbers.includes(name)) return true;
    const declaration = by_name.get(name);
    if (!declaration || seen.has(name)) return false;
    seen.add(name);
    const all = (items) => items.every((item) => item.number || (item.type && numeric(item.type, seen)));
    if (declaration.kind === 'union') return all(declaration.items);
    if (declaration.kind === 'refinement') return !declaration.list && all(declaration.items);
    if (declaration.kind === 'intersection') return numeric(declaration.types[0], seen);
    return false;
  }

  // A part for one item.
  function item_part(item) {
    if (item.literal !== undefined) return { literal: item.literal };
    if (item.characters) {
      const head = JSON.stringify(item.characters[0]) + '..' + JSON.stringify(item.characters[1]);
      make(head, () => characters(item.characters).map((literal) => ({ head, parts: [{ literal }] })));
      return { types: [head] };
    }
    return { types: [written_as[item.type] ?? item.type] };
  }

  // A part for a line: its items, its list and count, and its allowed values. Several items
  // or allowed values get a head of their own, named after the owner.
  function part_of(line, owner, name) {
    let part = line.items.length === 1 ? item_part(line.items[0]) : { types: [owner] };
    if (line.items.length > 1) {
      make(owner, () => line.items.map((item) => ({ head: owner, parts: [item_part(item)] })));
    }
    if (line.allowed || (line.places !== undefined && line.role === 'stored')) {
      const inner = part;
      make(owner, () => [{ head: owner, parts: [inner], ...(line.allowed ? { ranges: ranges_of(line.allowed) } : {}),
        ...(line.places !== undefined ? { places: line.places } : {}) }]);
      part = { types: [owner] };
    }
    if (name !== undefined) part = { name, ...part };
    if (!line.list && !line.count) return part;
    const count = line.count ?? { least: null, most: null };
    return { ...part, list: true, least: as_number(count.least) ?? 0, most: as_number(count.most) };
  }

  // A field typed by a named list of records, 'stops {Stops...}' with 'Stops {Stop...}', holds
  // that list: its items and its count.
  function holding(line) {
    const named = line.list && line.items.length === 1 ? by_name.get(line.items[0].type) : undefined;
    const item = named?.kind === 'refinement' && named.list ? named.items[0].type : undefined;
    if (item === undefined || by_name.get(item)?.kind !== 'record') return line;
    return { ...line, items: [{ type: item }], count: named.count };
  }

  // A shape position that holds a field, with its 'digits:' if it has one.
  function field_part(owner, field, digits) {
    if (digits === undefined) return part_of(holding(field), owner + '.' + field.name, field.name);
    const type = field.items[0].type;
    const head = type + '.' + digits;
    const allowed = by_name.get(type)?.allowed;
    make(head, () => [{ head, parts: [{ types: ['Digit'], list: true, least: digits, most: digits }],
      ...(allowed ? { ranges: ranges_of(allowed) } : {}) }]);
    return part_of({ ...field, items: [{ type: head }] }, owner + '.' + field.name, field.name);
  }

  const one_of = (name) => one_value(by_name, constants, name);

  // A term with its constants and types of one value written out, a finite union as the
  // choice of its values, and its ranges fixed.
  function resolve(term) {
    if (term.path?.length === 1 && by_name.get(term.path[0])?.call) {
      return { ...constant_record(term.path[0]), ...(term.all ? { all: true } : {}) };
    }
    if (term.path?.length === 1 && /^[A-Z]/.test(term.path[0])) {
      const fixed = one_of(term.path[0]) ?? union_values(by_name, constants, term.path[0]);
      if (!fixed) throw new Error(term.path[0] + ' has no one value');
      return Array.isArray(fixed) ? { choice: fixed } : fixed;
    }
    if (term.number !== undefined || term.text !== undefined || term.path) return term;
    if (term.op) return { op: term.op, terms: term.terms.map(resolve) };
    if (term.choice) return { choice: term.choice.map(resolve).flatMap((each) => each.choice ?? [each]) };
    if (term.range) {
      return { range: term.range.map((end) => {
        if (end === null) return null;
        const fixed = resolve(end);
        if (fixed.number === undefined) throw new Error('a range end is not a fixed number');
        return fixed.number;
      }) };
    }
    throw new Error('not carried');
  }

  // The lowest value a field allows, as text, or null.
  function floor_of(field, seen = new Set()) {
    const low = field.allowed?.length === 1 ? field.allowed[0].low : null;
    if (low !== null && low !== undefined) return decimal_text(value_of(low));
    const type = field.items?.[0]?.type;
    const found = by_name.get(type);
    if (!found || seen.has(type) || found.kind !== 'refinement') return null;
    return floor_of(found, seen.add(type));
  }

  // A constant record, 'Every_4 {Leap_Rule} (Years_Per_Leap, True)': its type made with its
  // values, one for each starred field. A constant list holds constant records, in order.
  const constant_records = new Map();
  function constant_record(name) {
    if (constant_records.has(name)) return constant_records.get(name);
    const declaration = by_name.get(name);
    let found;
    if (declaration.list) found = { list: declaration.call.map(resolve) };
    else {
      const type = declaration.items[0].type;
      const made = by_name.get(type);
      if (made?.kind !== 'record') throw new Error(name + ' is not a record');
      const starred = made.fields.filter((each) => each.required).map((each) => each.name);
      if (starred.length !== declaration.call.length) throw new Error(name + ': the wrong number of values');
      found = { constant: { name, make: type, fields: starred, values: declaration.call.map(resolve) } };
    }
    constant_records.set(name, found);
    return found;
  }

  // A record's fields other than its stored ones.
  function fields_of(declaration) {
    const lists = new Set(declaration.fields.filter((field) => field.list || ['kept', 'collected'].includes(field.role))
      .map((field) => field.name));
    const in_list = (path) => path.length === 2 && lists.has(path[0]);
    const condition_of = (condition, through) => {
      const comparisons = (condition.all ?? condition.any).map((comparison) => {
        let { path, right } = comparison;
        if (through !== undefined) {
          // a kept list's condition names each field through its list
          const step = (each) => {
            if (each.length !== 2 || each[0] !== through) throw new Error('not through ' + through);
            return [each[1]];
          };
          path = step(path);
          if (right.path?.length === 2) right = { path: step(right.path) };
        }
        const relation = through === undefined && ['=', 'in'].includes(comparison.comparison)
          && in_list(path) && right.path !== undefined && in_list(right.path);
        return { path, comparison: comparison.comparison, right: resolve(right), ...(relation ? { relation } : {}) };
      });
      return { [condition.all ? 'all' : 'any']: comparisons };
    };
    const fields = [];
    for (const field of declaration.fields.filter((each) => each.role !== 'stored')) {
      const name = field.name;
      try {
        if ((field.left_out ?? []).includes('a condition')) throw new Error('a condition');
        if (field.role === 'rule' || field.role === 'claim') {
          if (!field.condition) throw new Error('no condition');
          fields.push({ name, [field.role === 'rule' ? 'needs' : 'claims']: condition_of(field.condition) });
        } else if (field.role === 'kept') {
          const sources = new Set((field.condition.all ?? field.condition.any).map((comparison) => comparison.path[0]));
          const [source] = sources;
          if (sources.size !== 1 || !lists.has(source)) throw new Error('not a kept list');
          fields.push({ name, keep: source, condition: condition_of(field.condition, source) });
        } else if (field.role === 'made') {
          // a made record: its positions give its stored fields, in the order they are declared
          const type = field.makes ?? field.items[0].type;
          const made = by_name.get(type);
          if (made?.kind !== 'record') throw new Error('not a record');
          const stored = made.fields.filter((each) => each.role === 'stored' && (!field.call || each.required)).map((each) => each.name);
          if (stored.length !== field.positions.length || field.positions.some((slot) => !slot.path && !slot.value)) throw new Error('a made position');
          // a list of made records: one for each item of the list marked '...'
          fields.push({ name, make: type, fields: stored, values: field.positions.map((slot) => resolve(slot.value ?? { path: slot.path })),
            ...((field.each ?? field.list) ? { each: true } : {}) });
        } else if (field.role === 'listed') {
          fields.push({ name, list_of: field.values.map(resolve) });
        } else if (field.role === 'collected') {
          if (!field.value.path || !in_list(field.value.path)) throw new Error('not a collected list');
          fields.push({ name, collect: field.value.path });
        } else if (field.role === 'mapping') {
          const cases = field.cases.flatMap(({ output, when }) => {
            if (!output.range) {
              const value = output.type ? one_of(output.type) : output;
              if (!value) throw new Error(output.type + ' has no one value');
              return [{ output: value, when: condition_of(when) }];
            }
            // a range of numbers for a range of characters, first to first
            const [low, high] = output.range.map((end) => Number(end.number));
            const characters = (when.all ?? [])[0]?.right.characters;
            const [first, last] = (characters ?? []).map((character) => character.codePointAt(0));
            if (!characters || when.all.length !== 1 || last - first !== high - low) throw new Error('a range of outputs');
            return Array.from({ length: high - low + 1 }, (_, index) => ({ output: { number: String(low + index) },
              when: { all: [{ ...when.all[0], right: { text: String.fromCodePoint(first + index) } }] } }));
          });
          fields.push({ name, inputs: field.inputs, cases });
        } else {
          const worked = { name, value: resolve(field.value) };
          let round = field.round;
          // a quotient with no round: is exact, or rounds to its places
          if (!round && worked.value.op === '/') {
            const places = field.places ?? by_name.get(field.items[0].type)?.places ?? 0;
            round = { unit: places === 0 ? '1' : '0.' + '1'.padStart(places, '0'), direction: 'even' };
          }
          if (round) worked.round = round;
          if (field.wrap?.name !== undefined && /^[a-z]/.test(field.wrap.name)) worked.wrap_by = field.wrap.name;
          else if (field.wrap) worked.wrap = decimal_text(value_of(field.wrap));
          fields.push(worked);
        }
        if (field.repeat) {
          // while the condition holds, the record is made again from the next values; each
          // starred field keeps to its floor, the lowest value it allows
          const starred = declaration.fields.filter((each) => each.required);
          if (starred.length !== field.repeat.next.length) throw new Error('next');
          fields.at(-1).repeat = {
            condition: condition_of(field.repeat.condition),
            next: field.repeat.next.map(resolve),
            fields: starred.map((each) => each.name),
            floors: starred.map((each) => floor_of(each)),
          };
        }
      } catch {
        left_out.push(declaration.name + '.' + name + ' (' + (field.role === 'rule' ? 'a rule' : field.role) + ')');
      }
    }
    return fields;
  }

  const worked = new Map();
  const worked_fields = (declaration) => {
    if (!worked.has(declaration)) worked.set(declaration, fields_of(declaration));
    return worked.get(declaration);
  };

  // The ranks that a mapping such as Station_Order.rank gives characters: each case whose
  // output is a number and whose one comparison is = to a text or a choice of texts. The first
  // case for a character counts.
  function ranks_of([type, name, ...more]) {
    const declaration = by_name.get(type);
    if (more.length || declaration?.kind !== 'record') return undefined;
    const mapping = worked_fields(declaration).find((field) => field.name === name && field.cases);
    if (!mapping) return undefined;
    const ranks = {};
    for (const { output, when } of mapping.cases) {
      const [only, ...others] = when.all ?? when.any;
      if (output.number === undefined || others.length || !['=', 'in'].includes(only.comparison)) continue;
      for (const right of only.right.choice ?? [only.right]) {
        if (right.text !== undefined && !Object.hasOwn(ranks, right.text)) ranks[right.text] = output.number;
      }
    }
    return ranks;
  }

  for (const declaration of declarations) {
    const head = declaration.name;
    for (const what of declaration.left_out ?? []) left_out.push(head + ' (' + what + ')');
    const made_from = rules.length;
    if (declaration.kind === 'union') {
      for (const item of declaration.items) rules.push({ head, parts: [item_part(item)] });
    } else if (declaration.kind === 'intersection') {
      rules.push({ head, parts: [{ types: declaration.types.map((type) => written_as[type] ?? type) }] });
    } else if (declaration.kind === 'refinement') {
      const part = part_of({ ...declaration, allowed: undefined }, head + '.base');
      const rule = { head, parts: [part] };
      const constant = constants.get(head);
      if (declaration.allowed) rule.ranges = ranges_of(declaration.allowed);
      if (constant !== undefined) rule.ranges = [[to_number(constant), to_number(constant)]];
      else if (declaration.constant !== undefined) left_out.push(head + ' (worked out)');
      if (declaration.places !== undefined) rule.places = declaration.places;
      rules.push(rule);
    } else if (declaration.kind === 'layout') {
      const parts = declaration.positions.map((slot) => part_of(slot, head + '.' + slot.number));
      rules.push({ head, parts, ...(declaration.allowed ? { ranges: ranges_of(declaration.allowed) } : {}) });
    } else if (declaration.kind === 'record') {
      const stored = declaration.fields.filter((field) => field.role === 'stored');
      const slots = declaration.shape ?? stored.map((field) => ({ field: field.name }));
      const parts = slots.map((slot) => {
        if (slot.field === undefined) return part_of(holding(slot), head + '.' + slot.number);
        const field = stored.find((each) => each.name === slot.field);
        if (!field) {
          // refused by the file checks: a text shape holds only stored fields
          left_out.push(head + ' (its text shape names ' + slot.field + ', not a stored field)');
          return { literal: '' };
        }
        const part = field_part(head, field, slot.digits);
        if (field.items.every((item) => item.number || (item.type && numeric(item.type)))) part.number = true;
        for (const what of ['unique', 'order']) {
          if (!field[what]) continue;
          const ranks = !part.list && what === 'order' ? ranks_of(field.order.path) : undefined;
          if (part.list) part[what] = field[what].path;
          else if (ranks) part.ranks = ranks;
          else left_out.push(head + '.' + field.name + ' (' + what + ': ' + field[what].path.join('.') + ')');
        }
        return part;
      });
      for (const field of declaration.fields) {
        for (const what of field.left_out ?? []) {
          if (what !== 'a condition') left_out.push(head + '.' + field.name + ' (' + what + ')');
        }
      }
      const fields = worked_fields(declaration);
      rules.push({ head, record: true, parts, ...(fields.length ? { fields } : {}) });
    }
    if (numeric(head)) for (const rule of rules.slice(made_from)) if (rule.head === head) rule.number = true;
  }
  return { rules, left_out };
}

// A fixed value, exactly: a number, a constant by name, or + - * of fixed values. Null stays
// null. Constants gives each constant's value by name.
export function fixed_value(expression, constants) {
  if (expression === null || expression === undefined) return null;
  if (expression.number !== undefined) return exact(String(expression.number));
  if (expression.name !== undefined) {
    const fixed = constants.get(expression.name);
    if (fixed === undefined) throw new Error(expression.name + ' is not a constant');
    return fixed;
  }
  const join = { '+': plus, '-': minus, '*': times }[expression.op];
  if (!join) throw new Error('not a fixed value');
  return expression.terms.map((term) => fixed_value(term, constants)).reduce(join);
}

// The value of a type that has one value, such as True or a constant, or undefined.
export function one_value(by_name, constants, name, seen = new Set()) {
  if (constants.has(name)) return { number: decimal_text(constants.get(name)) };
  const declaration = by_name.get(name);
  if (!declaration || seen.has(name) || !['union', 'refinement'].includes(declaration.kind)) return undefined;
  if (declaration.items.length !== 1 || declaration.list || declaration.count || declaration.allowed) return undefined;
  const [item] = declaration.items;
  if (item.literal !== undefined) return item.number ? { number: item.literal } : { text: item.literal };
  return item.type && one_value(by_name, constants, item.type, seen.add(name));
}

// The values of a type that is a finite union of literals, such as Kernel_Word, or undefined.
export function union_values(by_name, constants, name, seen = new Set()) {
  const declaration = by_name.get(name);
  if (!declaration || seen.has(name) || !['union', 'refinement'].includes(declaration.kind)) return undefined;
  if (declaration.list || declaration.count || declaration.allowed) return undefined;
  const values = [];
  for (const item of declaration.items) {
    const fixed = item.type ? one_value(by_name, constants, item.type) : undefined;
    const inner = item.type && !fixed ? union_values(by_name, constants, item.type, new Set([...seen, name])) : undefined;
    if (item.literal !== undefined) values.push(item.number ? { number: item.literal } : { text: item.literal });
    else if (item.characters) values.push(...characters(item.characters).map((text) => ({ text })));
    else if (fixed) values.push(fixed);
    else if (inner) values.push(...inner);
    else return undefined;
  }
  return values;
}

// The characters of a range such as "A".."Z", in code-point order.
export const characters = ([first, last]) => Array.from({ length: last.codePointAt(0) - first.codePointAt(0) + 1 },
  (_, index) => String.fromCodePoint(first.codePointAt(0) + index));

// A rule in plain words, for people.
export function in_words(rule) {
  const how_many = (part) =>
    !part.list ? ''
    : part.most === null ? part.least + ' or more '
    : part.least === part.most ? part.least + ' '
    : part.least + ' to ' + part.most + ' ';
  const one = (part) =>
    how_many(part)
    + (part.literal !== undefined ? JSON.stringify(part.literal) : part.types.join(' and also '))
    + (part.name ? ' (' + [part.name, part.unique && 'no two with the same ' + part.unique.join('.'),
      part.order && 'ordered by ' + part.order.join('.'), part.ranks && 'ordered by the ranks of its characters']
      .filter(Boolean).join(', ') + ')' : '');
  const range = ([low, high]) =>
    low === null ? 'at most ' + high : high === null ? 'at least ' + low : 'from ' + low + ' to ' + high;
  const field = (each) => each.name + (
    each.needs ? ' needs ' + condition(each.needs)
    : each.claims ? ' claims ' + condition(each.claims)
    : each.keep ? ' keeps the items of ' + each.keep + ' where ' + condition(each.condition)
    : each.collect ? ' collects ' + each.collect[1] + ' from each item of ' + each.collect[0]
    : each.make ? ' is a ' + each.make + ' made with ' + each.fields.map((name, at) => name + ' ' + term(each.values[at])).join(', ')
    : each.cases ? ' is ' + each.cases.map((one_case) => term(one_case.output) + ' when ' + condition(one_case.when)).join(', or ')
    : ' is ' + term(each.value) + (each.round ? ', rounded to ' + each.round.unit + ' (' + each.round.direction + ')' : '')
      + (each.wrap ? ', wrapped at ' + each.wrap : '') + (each.wrap_by ? ', wrapped at ' + each.wrap_by : ''))
    + (each.repeat ? ', where ' + condition(each.repeat.condition) + ' no longer holds; while it holds, the record is made '
      + 'again with ' + each.repeat.fields.map((name, at) => name + ' ' + term(each.repeat.next[at])).join(', ') : '');
  return 'a text is a ' + rule.head + ' when it is: '
    + (rule.parts.map(one).join(', then ') || 'nothing')
    + (rule.ranges ? ', and its number is ' + rule.ranges.map(range).join(' or ') : '')
    + (rule.places !== undefined ? ', with ' + rule.places + ' decimal places' : '')
    + (rule.fields ?? []).map((each) => '; where ' + field(each)).join('');
}
