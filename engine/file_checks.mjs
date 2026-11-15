// The checks on a file: what main's checker refuses in a file's own declarations, before any
// text is read. Each error is written as main writes it, so the file judge can compare them:
//   FILE:LINE: error: MESSAGE [WHERE]
// and an error that stops a file loading as   FILE:LINE:COLUMN: MESSAGE
//
// Carried so far: the names (a type unknown, used before it is declared, or used by itself;
// two declarations of one name; files that use each other), the fields of a record (reserved
// names, a field twice, a rule with no condition), paths (an unknown field, a field below,
// a list read as one value, a method in the middle), a path to a record around this one that
// may not be there, and mappings (their inputs, their cases, coverage, disjointness and every
// output produced).
import { Exact, exact, plus, minus, times, decimal_text } from './evaluate.mjs';

const reserved = ['value', 'text', 'count', 'sum', 'min', 'max'];
const methods = ['count', 'sum', 'min', 'max'];
const built_in = ['Integer', 'Decimal'];
const literal_numbers = ['Integer_Literal', 'Decimal_Literal', 'Number_Literal'];
const is_type_name = (name) => /^[A-Z]/.test(name ?? '');

// The kinds of error that the engine carries, by the start of main's message.
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
];
export const carried_kind = (error) => carried.some((kind) => kind.test(error));

// ---------- Numbers, exactly

const compare = (a, b) => Math.sign(Number(minus(a, b).top));
const lowest = (numbers) => numbers.reduce((a, b) => (compare(a, b) <= 0 ? a : b));
const highest = (numbers) => numbers.reduce((a, b) => (compare(a, b) >= 0 ? a : b));
const integral = (number) => number.top % number.bottom === 0n;
const floor = (number) => new Exact(number.top / number.bottom - (number.top < 0n && !integral(number) ? 1n : 0n));

// ---------- The errors of a loaded file

export function file_errors(loaded) {
  if (loaded.count !== 1) return [];
  const { file, declarations: own, declared } = loaded;
  const errors = [];
  const stop = stopping_error(loaded);
  if (stop) return [stop];
  const by_name = new Map([...declared].map(([name, declaration]) => [name, declaration]));
  for (const declaration of own) by_name.set(declaration.name, declaration);
  const mine = with_digits(own, file);
  for (const declaration of mine) by_name.set(declaration.name, declaration);
  const error = (declaration, line, message, where = declaration.name) =>
    errors.push(file + ':' + line + ': error: ' + message + ' [' + where + ']');

  // A type's place in the order in which main declares types: the language first, then the
  // files that this file uses, then this file from the top.
  const place = (name) => {
    const found = by_name.get(name);
    if (!found) return -1;
    if (found.file !== file) return found.file === 'priv/language.etale' ? found.line : 5e5;
    return 1e6 + found.line - (found.digits_of ? 0.5 : 0);
  };
  const constants = constants_of(by_name);
  const singleton = (name) => one_value(by_name, constants, name);

  function type_ok(declaration, name, line, recursive_ok) {
    if (built_in.includes(name) || literal_numbers.includes(name)) return;
    const here = place(name);
    if (here < 0) error(declaration, line, "unknown type '" + name + "'");
    else if (name === declaration.name && !recursive_ok) {
      error(declaration, line, "'" + name + "' refers to itself; only a record field may, as a list whose count starts at 0");
    } else if (here > place(declaration.name)) {
      error(declaration, line, "type '" + name + "' is used before it is declared (line " + by_name.get(name).line
        + '); a name resolves only to a type declared above');
    }
  }
  const types_of = (items) => (items ?? []).filter((item) => item.type).map((item) => item.type);

  // ---------- Records

  // The fields in main's order: with a text shape, the stored fields in the order that the
  // shape names them, then the others as written. A kept or a collected list is not a field.
  function in_order(declaration) {
    const fields = declaration.fields.filter((each) => !['kept', 'collected'].includes(each.role));
    if (!declaration.shape) return fields;
    const placed = declaration.shape.filter((slot) => slot.field !== undefined)
      .map((slot) => fields.find((each) => each.name === slot.field && each.role === 'stored')).filter(Boolean);
    return [...placed, ...fields.filter((each) => each.role !== 'stored')];
  }

  function check_record(declaration) {
    const above = [];
    for (const field of in_order(declaration)) {
      const where = declaration.name + '.' + field.name;
      if (field.role === 'rule' && !field.condition) {
        error(declaration, field.line, "'" + field.name + " {Needs}' has no condition, so it would always hold; give it one, e.g. "
          + field.name + ' {Needs} (total >= 0)', where);
      }
      if (reserved.includes(field.name)) {
        error(declaration, field.line, "'" + field.name + "' is reserved (" + reserved.join(', ') + ') and cannot name a field', where);
      }
      if (above.includes(field.name)) error(declaration, field.line, "field '" + field.name + "' is declared twice", where);
      for (const name of types_of(['stored', 'worked'].includes(field.role) ? field.items : [])) {
        const recursive_ok = name === declaration.name && Boolean(field.list || field.count)
          && Number((field.count?.least ?? { number: 0 }).number) === 0;
        if (name === declaration.name && !recursive_ok) {
          error(declaration, field.line, 'a record may use its own type only as a list whose count starts at 0, e.g. '
            + 'children {Node...} or next {Chain} count: 0..1', where);
        } else type_ok(declaration, name, field.line, recursive_ok);
      }
      const relations = [];
      for (const path of field_paths(field, declaration, relations)) check_path(declaration, field, path, above);
      for (const [comparison, clauses] of relations) check_relation(declaration, field, comparison, clauses);
      if (field.role === 'mapping') check_mapping(declaration, field, above);
      above.push(field.name);
    }
  }

  // The paths that main checks one by one in a field: its calculation, and the comparisons of
  // its condition that are not relations between lists or 'in'. A kept or a collected list is
  // not a field: a path through it is a path through the list that it comes from.
  function field_paths(field, record, relations = []) {
    const paths = [];
    // the views written above this field: main's reader writes them out as it reads
    const views = new Map(record.fields.slice(0, record.fields.indexOf(field))
      .filter((each) => ['kept', 'collected'].includes(each.role)).map((each) => [each.name, each]));
    // main's reader writes a path of two or more steps through a view as a path through its list
    const through_view = (path) => path?.length > 1 && views.has(path[0]);
    const through = (path, seen = []) => {
      const view = path.length > 1 && views.get(path[0]);
      if (!view || seen.includes(view)) return path;
      const source = view.role === 'kept' ? [(view.condition.all ?? view.condition.any)[0].path[0]] : view.value.path;
      return through([...source, ...path.slice(1)], [...seen, view]);
    };
    const of_term = (term) => {
      if (!term) return;
      if (term.path) paths.push(through(term.path));
      for (const each of term.terms ?? term.choice ?? []) of_term(each);
    };
    const list_field = (name) => record.fields.some((each) => each.name === name && each.role === 'stored'
      && (each.list || each.count));
    const relation = (left, right) => left.length === 2 && right?.length === 2 && list_field(left[0]) && list_field(right[0]);
    if (field.role === 'worked') of_term(field.value);
    if (['rule', 'claim'].includes(field.role) && field.condition) {
      const comparisons = field.condition.all ?? field.condition.any;
      for (const comparison of comparisons) {
        const { path, right } = comparison;
        if (comparison.comparison === 'in' && (!right.path || through_view(path) || through_view(right.path))) continue;
        if (relation(path, right.path)) {
          relations.push([comparison, comparisons.length]);
          continue;
        }
        paths.push(through(path));
        of_term(right);
      }
    }
    return paths;
  }

  // A relation between two lists of the record: '(orders.customer in customers.code)'.
  function check_relation(record, field, { path: [left_list, left_field], comparison, right }, clauses) {
    const where = record.name + '.' + field.name;
    const [right_list, right_field] = right.path;
    const left = left_list + '.' + left_field;
    const other = right_list + '.' + right_field;
    const example = field.name + ' {Needs} (' + left + ' in ' + other + ')';
    const bad = (message) => error(record, field.line, message, where);
    if (field.role === 'claim') return bad('a relation between two lists is a rule, not a claim: ' + example);
    if (!['=', 'in'].includes(comparison)) {
      return bad('two lists are related with in only: each item of ' + left_list + ' matches an item of ' + right_list
        + ', ' + example);
    }
    if (clauses !== 1) return bad('a relation between two lists is a line of its own, with no other condition: ' + example);
    if (left_list === right_list) return bad('a relation is between two different lists: ' + example);
    const item_of = (name) => record_of(field_of(record, name).items[0]?.type);
    const [left_item, right_item] = [item_of(left_list), item_of(right_list)];
    if (!left_item || !right_item) {
      return bad('a relation is between two lists of records: ' + left_list + ' and ' + right_list
        + ' must each be a list of one record type');
    }
    const [one, two] = [field_of(left_item, left_field), field_of(right_item, right_field)];
    if (!one) return bad("'" + left_item.name + "' has no field '" + left_field + "'");
    if (!two) return bad("'" + right_item.name + "' has no field '" + right_field + "'");
    const single = (each) => !each.list && !each.count && !record_of(each.items[0]?.type);
    if (!single(one) || !single(two)) {
      return bad(left + ' and ' + other + ' are compared as single numbers or texts: neither may be a list or a record');
    }
    const same_kind = item_text(one.items[0]) === item_text(two.items[0])
      || (numeric(by_name, one.items) && numeric(by_name, two.items));
    if (!same_kind) {
      bad(left + ' is ' + item_text(one.items[0]) + ' but ' + other + ' is ' + item_text(two.items[0])
        + ': a relation compares fields of the same type');
    }
  }

  // ---------- Paths

  const record_of = (name, seen = new Set()) => {
    const found = by_name.get(name);
    if (!found || seen.has(name)) return undefined;
    if (found.kind === 'record') return found;
    if (found.kind === 'refinement' && found.items.length === 1 && found.items[0].type) {
      return record_of(found.items[0].type, seen.add(name));
    }
    return undefined;
  };
  const field_of = (record, name) => record?.fields?.find((field) => field.name === name
    && !['kept', 'collected'].includes(field.role));

  function check_path(declaration, field, path, above) {
    const where = declaration.name + '.' + field.name;
    const [head, step] = path;
    if (is_type_name(head) && path.length > 1 && by_name.has(head)) {
      const outer = by_name.get(head);
      if (outer.kind === 'record') return walk(declaration, where, path.slice(1), outer, field.line);
      return error(declaration, field.line, "'" + head + "' is not a record, so '" + head + '.' + step
        + "' names nothing; a path that starts with a type reaches a record around this one", where);
    }
    if (is_type_name(head)) {
      if (path.length === 1 && constants.has(head)) return;
      if (place(head) < 0) error(declaration, field.line, "unknown type '" + head + "' in a path", where);
      else if (place(head) >= place(declaration.name)) {
        error(declaration, field.line, "type '" + head + "' is not declared above this line", where);
      } else if (path.length === 1 && singleton(head) === undefined) {
        error(declaration, field.line, "type '" + head + "' has more than one inhabitant, so it is not a value", where);
      }
      return;
    }
    if (!field_of(declaration, head)) return error(declaration, field.line, "unknown field '" + head + "'", where);
    if (head === field.name) return error(declaration, field.line, "field '" + head + "' cannot refer to itself", where);
    if (!above.includes(head)) {
      return error(declaration, field.line, "field '" + head + "' is declared below '" + field.name
        + "'; a field may name only fields above it", where);
    }
    walk(declaration, where, path, declaration, field.line);
  }

  function walk(declaration, where, path, record, line) {
    let at = record;
    let last_field;
    let state = 'one';
    for (let index = 0; index < path.length; index++) {
      const step = path[index];
      const so_far = path.slice(0, index).join('.');
      if (index > 0 && methods.includes(step)) {
        if (state === 'one') error(declaration, line, "'." + step + "' reads a list, but " + so_far + ' is not one', where);
        if (index !== path.length - 1) error(declaration, line, "a method ends the path ('." + step + "')", where);
        if (step !== 'count' && last_field && !numeric(by_name, last_field.items)) {
          error(declaration, line, "'." + step + "' takes a list of numbers", where);
        }
        return;
      }
      const fields_here = at && record_of(at.name);
      if (at && index > 0 && is_type_name(step)) {
        return error(declaration, line, "'" + path.slice(0, index + 1).join('.') + "': a path holds only fields, and a type "
          + 'cannot narrow a list. To keep some of the items, give ' + at.name + ' a field with cases and keep the items on '
          + 'a line of their own, e.g. (' + so_far + '.field = True)', where);
      }
      if (!fields_here) return error(declaration, line, "'" + so_far + "' has no fields", where);
      const next = field_of(fields_here, step);
      if (!next) return error(declaration, line, "'" + at.name + "' has no field '" + step + "'", where);
      if (next.list || next.count) {
        const most = next.count?.most;
        state = most && state === 'one' && Number(most.number) <= 1 ? 'optional' : 'list';
      }
      last_field = next;
      const type = next.items?.length === 1 ? next.items[0].type : undefined;
      at = type && (by_name.get(type)?.kind === 'refinement' && by_name.get(type).list ? record_of(type) : by_name.get(type));
    }
    if (state === 'list') error(declaration, line, path.join('.') + ' is a list: read it with a method, .count or .sum', where);
  }

  // ---------- A path to a record around this one

  // The declarations that can hold a value of this type: as an item, a position or a field,
  // or as a step of a path. A named list of records is not around its items: what holds the
  // list holds them.
  function holders(name) {
    const uses = (items) => (items ?? []).some((item) => item.type === name);
    const found = [];
    for (const each of by_name.values()) {
      const holds = uses(each.items) || (each.positions ?? []).some((slot) => uses(slot.items))
        || (each.fields ?? []).some((field) => field.role === 'stored' && uses(field.items));
      if (!holds) continue;
      const named_list = each.kind === 'refinement' && each.items.length === 1 && record_of(each.items[0].type);
      found.push(...(named_list ? holders(each.name) : [each.name]));
    }
    return [...new Set(found)].sort();
  }
  function escape(name, outer, seen) {
    if (name === outer || seen.includes(name)) return undefined;
    const others = holders(name).filter((holder) => holder !== name);
    if (others.length === 0) return name;
    for (const holder of others) {
      const found = escape(holder, outer, [name, ...seen]);
      if (found) return found;
    }
    return undefined;
  }
  function check_context(declaration) {
    const paths = new Map();
    for (const field of declaration.fields ?? []) {
      for (const path of field_paths(field, declaration)) {
        const [head] = path;
        if (path.length < 2 || head === declaration.name || !is_type_name(head) || by_name.get(head)?.kind !== 'record') continue;
        if (!paths.has(path.join('.'))) paths.set(path.join('.'), head);
      }
    }
    for (const [path, outer] of paths) {
      const root = escape(declaration.name, outer, []);
      if (root === undefined) continue;
      error(declaration, declaration.line, "'" + declaration.name + "' reaches " + path + ', so it must always sit inside '
        + (/^[aeiou]/i.test(outer) ? 'an ' : 'a ') + outer + ', but '
        + (root === declaration.name ? 'nothing holds it inside one' : root + ' holds it without one around'));
    }
  }

  // ---------- Mappings

  function check_mapping(declaration, field, above) {
    const where = declaration.name + '.' + field.name;
    const domains = new Map();
    for (const input of field.inputs) {
      const input_field = field_of(declaration, input);
      if (!input_field || !above.includes(input)) {
        return error(declaration, field.line, "mapping input '" + input + "' must be a field declared above the mapping", where);
      }
      const domain = domain_of(input_field, declaration);
      if (!domain) {
        return error(declaration, field.line, "mapping input '" + input + "' must be of a finite union type or a numeric type "
          + '(text and sequence inputs are not allowed)', where);
      }
      domains.set(input, domain);
    }
    for (const name of types_of(field.items)) type_ok(declaration, name, field.line, false);
    const outputs = finite_values(field.items);
    const cases = expanded_cases(field);
    const boxes = [];
    const output_value = (output) => {
      const fixed = output.type ? singleton(output.type) : output;
      return fixed && (fixed.number !== undefined ? exact(fixed.number) : fixed.text);
    };
    for (const one_case of cases) {
      const value = output_value(one_case.output);
      const line = one_case.line ?? field.line;
      if (value === undefined) {
        return error(declaration, line, "a case output is a singleton (a literal, or a type with one inhabitant); '"
          + item_text(one_case.output) + "' is not", where);
      }
      if (outputs && !outputs.some((each) => same(each, value))) {
        return error(declaration, line, 'case output ' + item_text(one_case.output) + ' is not a value of the output type', where);
      }
      const box = case_box(one_case.when, field.inputs, domains);
      if (typeof box === 'string') return error(declaration, line, box, where);
      boxes.push(box);
    }
    const points = field.inputs.map((input) => {
      const domain = domains.get(input);
      return domain.values ?? sample(domain, boxes, input);
    });
    const combinations = points.length === 1 ? points[0].map((value) => [value])
      : points.length === 2 ? points[0].flatMap((first) => points[1].map((second) => [first, second])) : [];
    const missing = [];
    const overlaps = [];
    for (const combination of combinations) {
      const hits = boxes.map((box, index) => [box, index])
        .filter(([box]) => field.inputs.every((input, at) => in_box(box.get(input), combination[at])))
        .map(([, index]) => index);
      if (hits.length === 0) missing.push(combination);
      else if (hits.length > 1) overlaps.push([combination, hits]);
    }
    const shown = (combination) => field.inputs.map((input, at) => input + ' = ' + value_text(combination[at])).join(', ');
    if (missing.length) {
      error(declaration, field.line, 'cases do not cover every input combination; missing: '
        + missing.slice(0, 4).map(shown).join('; ') + (missing.length > 4 ? ' …' : ''), where);
    }
    if (overlaps.length) {
      const [combination, hits] = overlaps[0];
      error(declaration, field.line, 'cases are not disjoint: ' + shown(combination) + ' matches cases '
        + hits.map((hit) => hit + 1).join(', '), where);
    }
    if (outputs) {
      const produced = cases.map((one_case) => output_value(one_case.output)).filter((value) => value !== undefined);
      const lost = outputs.filter((value) => !produced.some((each) => same(each, value)));
      if (lost.length) {
        error(declaration, field.line, 'no case produces ' + lost.map(value_text).join(', ')
          + '; every value of the output type must be produced by some case', where);
      }
    }
  }

  // A case as a box: for each input it names, the values or the ranges it allows. Or the
  // message of what is wrong with it.
  function case_box(when, inputs, domains) {
    const comparisons = when.all ?? when.any;
    if (when.any && comparisons.length > 1) {
      return "a case is a box: one interval or literal set per input (an '|' between predicates on different inputs is not a box)";
    }
    const box = new Map();
    for (const { path, comparison: written, right } of comparisons) {
      const [name] = path;
      const comparison = written === 'in' ? '=' : written;
      if (path.length !== 1 || !inputs.includes(name)) {
        return 'a case predicate names one of the inputs (' + inputs.join(', ') + "), not '" + path.join('.') + "'";
      }
      if (box.has(name)) return "input '" + name + "' is constrained twice in one case";
      const parts = [];
      for (const value of right.choice ?? [right]) {
        if (value.number !== undefined) parts.push({ at: exact(value.number) });
        else if (value.text !== undefined) parts.push({ at: value.text });
        else if (value.characters) parts.push(...characters(value.characters).map((each) => ({ at: each })));
        else if (value.range) parts.push({ between: value.range.map((end) => (end === null ? null : number_of(end))) });
        else if (value.path?.length === 1 && is_type_name(value.path[0])) {
          const fixed = singleton(value.path[0]);
          if (fixed === undefined) return "'" + value.path[0] + "' is not a single value";
          parts.push({ at: fixed.number !== undefined ? exact(fixed.number) : fixed.text });
        } else return 'a case compares to a literal or a range: no arithmetic, no other fields';
      }
      const domain = domains.get(name);
      if (domain.values) {
        if (comparison !== '=') return "'" + name + "' takes one of a set of values; compare it with '='";
        if (parts.some((part) => part.at === undefined || !domain.values.some((each) => same(each, part.at)))) {
          return "a value in this case is not a value of input '" + name + "'";
        }
        box.set(name, { set: parts.map((part) => part.at) });
      } else box.set(name, { comparison, parts });
    }
    return box;
  }

  // The values that a number input is tried at: every bound that a case or the input names,
  // one below and one above them all, and one between each two.
  function sample(domain, boxes, input) {
    const bounds = [];
    for (const box of boxes) {
      for (const part of box.get(input)?.parts ?? []) {
        if (part.at !== undefined) bounds.push(part.at);
        else bounds.push(...part.between.filter((end) => end !== null));
      }
    }
    if (domain.low !== null) bounds.push(domain.low);
    if (domain.high !== null) bounds.push(domain.high);
    const sorted = unique_numbers(bounds);
    const one = exact('1');
    const points = sorted.length ? [minus(sorted[0], one), plus(sorted[sorted.length - 1], one), ...sorted] : [exact('0')];
    for (let index = 0; index + 1 < sorted.length; index++) {
      const [a, b] = [sorted[index], sorted[index + 1]];
      if (!domain.integer) points.push(times(plus(a, b), exact('0.5')));
      else if (compare(plus(floor(a), one), b) < 0) points.push(plus(floor(a), one));
    }
    return unique_numbers(points).filter((point) => (!domain.integer || integral(point))
      && (domain.low === null || compare(point, domain.low) >= 0) && (domain.high === null || compare(point, domain.high) <= 0));
  }

  // What a mapping input can be: a finite set of values, or numbers between two bounds.
  function domain_of(input, record) {
    if (input.list || input.count) return undefined;
    if (input.role === 'mapping') {
      const values = finite_values(input.items);
      return values && { values };
    }
    const values = finite_values(input.items);
    if (values) return { values };
    if (numeric(by_name, input.items)) {
      return { integer: input.items.every((item) => integer_type(item)), ...field_bounds(input, record) };
    }
    if (['Needs', 'Claims'].includes(input.items[0]?.type)) return { values: ['TRUE'] };
    return undefined;
  }
  function integer_type(item, seen = new Set()) {
    if (item.literal !== undefined) return item.number === true && !item.literal.includes('.');
    if (['Integer', 'Integer_Literal'].includes(item.type)) return true;
    const found = by_name.get(item.type);
    if (!found || seen.has(item.type)) return false;
    seen.add(item.type);
    if (found.kind === 'layout') return found.items[0]?.type === 'Integer';
    if (found.kind === 'refinement') return integer_type(found.items[0], seen);
    if (found.kind === 'intersection') return integer_type({ type: found.types[0] }, seen);
    if (found.kind === 'union') return found.items.every((each) => integer_type(each, seen));
    return false;
  }
  const allowed_bounds = (allowed) => {
    if (!allowed || allowed.length !== 1) return { low: null, high: null };
    const [{ low, high }] = allowed;
    return { low: low && fixed_value(low, constants), high: high && fixed_value(high, constants) };
  };
  const narrow = (a, b) => ({
    low: a.low === null ? b.low : b.low === null ? a.low : highest([a.low, b.low]),
    high: a.high === null ? b.high : b.high === null ? a.high : lowest([a.high, b.high]),
  });
  function field_bounds(input) {
    let bounds = narrow(allowed_bounds(input.allowed), type_bounds(input.items[0], []));
    if (input.value?.path?.at(-1) === 'count') bounds = narrow(bounds, { low: exact('0'), high: null });
    if (input.wrap) {
      const wrap = fixed_value(input.wrap, constants);
      const top = integer_type(input.items[0]) && integral(wrap) ? minus(wrap, exact('1')) : wrap;
      bounds = narrow(bounds, { low: exact('0'), high: top });
    }
    return bounds;
  }
  function type_bounds(item, seen) {
    const any = { low: null, high: null };
    if (item.literal !== undefined) return item.number ? { low: exact(item.literal), high: exact(item.literal) } : any;
    const found = by_name.get(item.type);
    if (!found || seen.includes(item.type)) return any;
    const deeper = [item.type, ...seen];
    if (found.kind === 'union') {
      if (!numeric(by_name, [item])) return any;
      const each = found.items.map((one) => type_bounds(one, deeper));
      return each.some((one) => one.low === null) || each.some((one) => one.high === null) ? {
        low: each.some((one) => one.low === null) ? null : lowest(each.map((one) => one.low)),
        high: each.some((one) => one.high === null) ? null : highest(each.map((one) => one.high)),
      } : { low: lowest(each.map((one) => one.low)), high: highest(each.map((one) => one.high)) };
    }
    if (found.kind === 'intersection') return type_bounds({ type: found.types[0] }, deeper);
    if (found.kind === 'record') return any;
    let bounds = allowed_bounds(found.allowed);
    if (found.kind === 'layout' && built_in.includes(found.items[0]?.type)) {
      const signed = found.positions.some((slot) => slot.items.length === 1 && slot.items[0].literal === '-');
      let digits = 0;
      for (const slot of found.positions) {
        if (slot.items.every((each) => each.literal !== undefined)) continue;
        if (!slot.count) digits += 1;
        else if (slot.count.most === null) { digits = null; break; } else digits += Number(fixed_value(slot.count.most, constants).top);
      }
      const capacity = digits === null ? null : minus(exact('1' + '0'.repeat(digits)), exact('1'));
      bounds = narrow(bounds, { low: signed ? (capacity && minus(exact('0'), capacity)) : exact('0'), high: capacity });
    }
    if (found.kind === 'refinement') bounds = narrow(bounds, type_bounds(found.items[0], deeper));
    return bounds;
  }

  // The values of a finite union, in order, or undefined.
  function finite_values(items, seen = new Set()) {
    const values = [];
    for (const item of items) {
      if (item.literal !== undefined) { values.push(item.number ? exact(item.literal) : item.literal); continue; }
      if (item.characters) { values.push(...characters(item.characters)); continue; }
      const fixed = singleton(item.type);
      if (fixed !== undefined) { values.push(fixed.number !== undefined ? exact(fixed.number) : fixed.text); continue; }
      const found = by_name.get(item.type);
      const plain = found && !seen.has(item.type) && (found.kind === 'union'
        || (found.kind === 'refinement' && !found.list && !found.count && !found.allowed && found.constant === undefined));
      if (!plain) return undefined;
      const inner = finite_values(found.items, new Set([...seen, item.type]));
      if (!inner) return undefined;
      values.push(...inner);
    }
    return values.filter((value, index) => values.findIndex((each) => same(each, value)) === index);
  }

  for (const declaration of mine) {
    check_context(declaration);
    for (const name of [...types_of(declaration.items), ...(declaration.types ?? [])]) {
      type_ok(declaration, name, declaration.line, false);
    }
    for (const slot of declaration.positions ?? declaration.shape ?? []) {
      for (const name of types_of(slot.items)) type_ok(declaration, name, slot.line, false);
    }
    if (declaration.kind === 'record') check_record(declaration);
  }

  return errors;
}

// A field written with 'digits:' gets a fixed-width form of its number type, as main's reader
// makes it: 'Hour.2', declared just above the record, a layout of the type's base.
function with_digits(own, file) {
  const out = [];
  const made = new Set();
  for (const declaration of own) {
    const extra = [];
    const retyped = new Map();
    for (const slot of declaration.shape ?? []) {
      const field = declaration.fields.find((each) => each.name === slot.field);
      const type = field?.items.length === 1 ? field.items[0].type : undefined;
      if (slot.digits === undefined || !type) continue;
      const name = type + '.' + slot.digits;
      retyped.set(field.name, name);
      if (made.has(name)) continue;
      made.add(name);
      const found = own.find((each) => each.name === type);
      const base = !found ? type : found.items?.length === 1 && found.items[0].type ? found.items[0].type : 'Integer';
      const digits = { number: String(slot.digits) };
      extra.push({ name, kind: 'layout', line: declaration.line, file, digits_of: type, items: [{ type: base }],
        ...(found?.kind === 'refinement' && found.allowed ? { allowed: found.allowed } : {}),
        positions: [{ number: 1, line: declaration.line, items: [{ type: 'Digit' }], count: { least: digits, most: digits } }] });
    }
    out.push(...extra);
    out.push(retyped.size === 0 ? declaration : { ...declaration, fields: declaration.fields.map((field) =>
      (retyped.has(field.name) ? { ...field, items: [{ type: retyped.get(field.name) }] } : field)) });
  }
  return out;
}

// ---------- Errors that stop a file loading

function stopping_error(loaded) {
  const { file, declarations: own, declared, language = [], uses } = loaded;
  // files that use each other
  if (uses) {
    const visit = (each, stack) => {
      if (stack.includes(each)) return [...stack.slice(stack.indexOf(each)), each];
      for (const next of uses.get(each) ?? []) {
        const cycle = visit(next, [...stack, each]);
        if (cycle) return cycle;
      }
      return undefined;
    };
    const cycle = visit(file, []);
    if (cycle) {
      return file + ':1:1: files use each other in a cycle: ' + cycle.join(' -> ') + '; move the shared types into one file';
    }
  }
  // a name declared twice
  const first = new Map([...language, ...declared.values()].filter((each) => each.file !== file)
    .map((each) => [each.name, each]));
  for (const declaration of own) {
    const before = first.get(declaration.name);
    if (before) {
      return file + ':' + declaration.line + ":1: type '" + declaration.name + "' is already declared (first declared at "
        + before.file.replace(/^priv\/(?=language\.etale)/, '') + ':' + before.line + '); two files may not declare the same name';
    }
    if (built_in.includes(declaration.name)) {
      return file + ':' + declaration.line + ":1: type '" + declaration.name + "' is a built-in type";
    }
    first.set(declaration.name, declaration);
  }
  return undefined;
}

// ---------- Values

const same = (a, b) => (typeof a === 'string' || typeof b === 'string' ? a === b : compare(a, b) === 0);
const value_text = (value) => (typeof value === 'string'
  ? (value === 'TRUE' || value === 'FALSE' ? value : JSON.stringify(value)) : decimal_text(value));
const number_of = (end) => exact(String(end.number ?? end));
const unique_numbers = (numbers) => [...numbers].sort(compare).filter((number, index, all) => index === 0
  || compare(all[index - 1], number) !== 0);
const characters = ([first, last]) => Array.from({ length: last.codePointAt(0) - first.codePointAt(0) + 1 },
  (_, index) => String.fromCodePoint(first.codePointAt(0) + index));
const item_text = (item) => (item.type ?? (item.text !== undefined ? JSON.stringify(item.text) : item.number));

// The constants of the scope: a refinement whose parentheses hold a fixed value.
function constants_of(by_name) {
  const constants = new Map();
  const value = (name, seen) => {
    if (constants.has(name)) return constants.get(name);
    const found = by_name.get(name);
    if (found?.constant === undefined || seen.includes(name)) return undefined;
    try {
      const fixed = fixed_value(found.constant, { get: (other) => value(other, [name, ...seen]) });
      constants.set(name, fixed);
      return fixed;
    } catch {
      return undefined;
    }
  };
  for (const name of by_name.keys()) value(name, []);
  return constants;
}
function fixed_value(expression, constants) {
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

// The one value of a type that has one: a constant, or a literal through refinements.
function one_value(by_name, constants, name, seen = new Set()) {
  if (constants.has(name)) return { number: decimal_text(constants.get(name)) };
  const found = by_name.get(name);
  if (!found || seen.has(name) || !['union', 'refinement'].includes(found.kind)) return undefined;
  if (found.items.length !== 1 || found.list || found.count || found.allowed) return undefined;
  const [item] = found.items;
  if (item.literal !== undefined) return item.number ? { number: item.literal } : { text: item.literal };
  return item.type && one_value(by_name, constants, item.type, seen.add(name));
}

function numeric(by_name, items, seen = new Set()) {
  return items.every((item) => {
    if (item.number) return true;
    if (!item.type) return false;
    if (built_in.includes(item.type) || literal_numbers.includes(item.type)) return true;
    const found = by_name.get(item.type);
    if (!found || seen.has(item.type)) return false;
    const deeper = new Set([...seen, item.type]);
    if (found.kind === 'union') return numeric(by_name, found.items, deeper);
    if (found.kind === 'refinement') return numeric(by_name, [found.items[0]], deeper);
    if (found.kind === 'intersection') return numeric(by_name, [{ type: found.types[0] }], deeper);
    if (found.kind === 'layout') return built_in.includes(found.items[0]?.type);
    return false;
  });
}

// A mapping's cases, with a range of numbers for a range of characters written out, first to
// first.
function expanded_cases(field) {
  return field.cases.flatMap(({ line, output, when }) => {
    if (!output.range) return [{ line, output, when }];
    const [low, high] = output.range.map((end) => Number(end.number));
    const range = (when.all ?? [])[0]?.right.characters;
    if (!range || when.all.length !== 1) return [{ line, output, when }];
    return characters(range).slice(0, high - low + 1).map((character, index) => ({ line,
      output: { number: String(low + index) }, when: { all: [{ ...when.all[0], right: { text: character } }] } }));
  });
}

function in_box(constraint, value) {
  if (!constraint) return true;
  if (constraint.set) return constraint.set.some((each) => same(each, value));
  if (typeof value === 'string') return false;
  return constraint.parts.some((part) => {
    if (part.between) {
      const [low, high] = part.between;
      return constraint.comparison === '=' && (low === null || compare(low, value) <= 0)
        && (high === null || compare(value, high) <= 0);
    }
    const order = compare(value, part.at);
    return { '=': order === 0, '<': order < 0, '<=': order <= 0, '>': order > 0, '>=': order >= 0 }[constraint.comparison] ?? false;
  });
}
