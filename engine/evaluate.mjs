// Values: what the parts of a reading are worth, and the fields worked out from them.
//
// A value is an exact number, a text (TRUE and FALSE are the texts "TRUE" and "FALSE"), a
// record (a node of a record's rule), a list, INVALID, or LATER: it reaches a record around
// this one, so it is worked out only once the whole text is read.
//
// While the text is read, a record whose field is INVALID, or with a 'unique:' list that has
// two items with the same key, has no reading (read.mjs asks valid). Once the whole text is
// read, settle works out what was LATER, in the records around each record, and gives every
// failed rule, claim or mapping, and every 'order:' list whose keys go down.

export const INVALID = Symbol('INVALID');
const LATER = Symbol('LATER');

// ---------- Exact numbers: a fraction of two big integers, in lowest terms

const gcd = (a, b) => {
  for (a = a < 0n ? -a : a, b = b < 0n ? -b : b; b !== 0n;) [a, b] = [b, a % b];
  return a;
};

export class Exact {
  constructor(top, bottom = 1n) {
    if (bottom < 0n) [top, bottom] = [-top, -bottom];
    const common = gcd(top, bottom) || 1n;
    this.top = top / common;
    this.bottom = bottom / common;
  }
}

export function exact(text) {
  const match = /^(-?)(\d+)(?:\.(\d+))?$/.exec(text);
  if (!match) return null;
  const [, sign, whole, part = ''] = match;
  return new Exact(BigInt(sign + whole + part), 10n ** BigInt(part.length));
}

export const plus = (a, b) => new Exact(a.top * b.bottom + b.top * a.bottom, a.bottom * b.bottom);
export const minus = (a, b) => new Exact(a.top * b.bottom - b.top * a.bottom, a.bottom * b.bottom);
export const times = (a, b) => new Exact(a.top * b.top, a.bottom * b.bottom);
const over = (a, b) => new Exact(a.top * b.bottom, a.bottom * b.top);
const order = (a, b) => {
  const difference = a.top * b.bottom - b.top * a.bottom;
  return difference < 0n ? -1 : difference > 0n ? 1 : 0;
};

// The decimal text of a number, for numbers that have one.
export function decimal_text(number) {
  let places = 0n;
  while ((10n ** places) % number.bottom !== 0n) if (++places > 60n) throw new Error('not a decimal');
  const scaled = (number.top * 10n ** places) / number.bottom;
  const digits = (scaled < 0n ? -scaled : scaled).toString().padStart(Number(places) + 1, '0');
  const cut = digits.length - Number(places);
  return (scaled < 0n ? '-' : '') + digits.slice(0, cut) + (places > 0n ? '.' + digits.slice(cut) : '');
}

const fraction_text = (number) => {
  try {
    return decimal_text(number);
  } catch {
    return number.top + '/' + number.bottom;
  }
};

// a mod m, never negative: the arithmetic of 'wrap_at:'.
function wrap(a, m) {
  const whole = (a.top * m.bottom) / (a.bottom * m.top);         // toward zero
  const rest = minus(a, times(m, new Exact(whole)));
  return rest.top < 0n ? plus(rest, m.top < 0n ? times(m, new Exact(-1n)) : m) : rest;
}

// A number rounded to a multiple of the unit. The cut goes toward zero; a cut-off part above
// one half goes one step away from zero, and exactly one half goes as the direction says:
// even, away (from zero), lower or higher.
function round(number, unit, direction) {
  const units = over(number, unit);
  const kept = units.top / units.bottom;
  const left = minus(units, new Exact(kept));
  const half = order(times(new Exact(left.top < 0n ? -left.top : left.top, left.bottom), new Exact(2n)), new Exact(1n));
  const negative = units.top < 0n;
  const away = left.top !== 0n && (half > 0 || (half === 0 && {
    even: kept % 2n !== 0n, away: true, lower: negative, higher: !negative,
  }[direction]));
  return times(new Exact(away ? kept + (negative ? -1n : 1n) : kept), unit);
}

// ---------- Words, for people: a term and a condition as they are written

export const term_words = (term) =>
  term.number ?? (term.text !== undefined ? JSON.stringify(term.text)
    : term.path ? term.path.join('.')
    : term.op ? term.terms.map(term_words).join(' ' + term.op + ' ')
    : term.range ? (term.range[0] ?? '') + '..' + (term.range[1] ?? '')
    : term.choice.map(term_words).join(' | '));
export const condition_words = (condition) => (condition.all ?? condition.any)
  .map((comparison) => comparison.path.join('.') + ' ' + comparison.comparison + ' ' + term_words(comparison.right))
  .join(condition.all ? ' & ' : ' | ');

// ---------- Lists

export class Sequence {
  constructor(items, most) {
    this.items = items;
    this.most = most;
  }
}

const ZERO = new Exact(0n);
const folds = {
  count: (items) => new Exact(BigInt(items.length)),
  sum: (items) => (items.every((item) => item instanceof Exact) ? items.reduce(plus, ZERO) : INVALID),
  min: (items) => least_or_most(items, -1),
  max: (items) => least_or_most(items, 1),
};
function least_or_most(items, side) {
  if (items.length === 0 || !items.every((item) => item instanceof Exact)) return INVALID;
  return items.reduce((best, item) => (order(item, best) === side ? item : best));
}

// ---------- Fields

// The lines of a rule by name: a stored field is a part, the others are its fields.
const lines = new WeakMap();
function lines_of(rule) {
  let found = lines.get(rule);
  if (found) return found;
  found = new Map();
  rule.parts.forEach((part, index) => { if (part.name !== undefined) found.set(part.name, { name: part.name, part: index }); });
  for (const field of rule.fields ?? []) found.set(field.name, field);
  lines.set(rule, found);
  return found;
}

const is_record = (value) => value?.rule?.record === true;
const stop = (value) => value === INVALID || value === LATER;
const holds_as = { '=': (side) => side === 0, in: (side) => side === 0, '<': (side) => side < 0,
  '<=': (side) => side <= 0, '>': (side) => side > 0, '>=': (side) => side >= 0 };

// The values of one text. Numeric holds the heads whose texts are numbers.
export function evaluator(text, numeric) {
  const fail = (node, message) => (node.failures ??= []).push(message);

  // The value of a part's node: the record it is, or its text, read as a number when its type
  // or the field's type is numeric.
  function item_value(node, number) {
    if (!node) return INVALID;
    for (let at = node; ; at = at.values[0]) {
      if (is_record(at)) return at;
      if (numeric.has(at.head)) number = true;
      const parts = at.rule?.parts;
      if (!parts || parts.length !== 1 || !parts[0].types || parts[0].list || !at.values[0]) break;
    }
    const written = text.slice(node.start, node.end);
    return number ? exact(written) ?? INVALID : written;
  }
  function stored_value(part, value) {
    if (!part.list) return item_value(value, part.number);
    const items = [];
    for (let link = value; link; link = link.before) items.push(item_value(link.item, part.number));
    return new Sequence(items.reverse(), part.most);
  }

  // A field of a record. Outside is the records around it, innermost first, or null while
  // the text is being read. Each field is worked out once; a LATER is worked out again.
  function get(node, name, outside) {
    const memo = (node.memo ??= new Map());
    if (memo.has(name)) return memo.get(name);
    const line = lines_of(node.rule).get(name);
    const busy = (node.busy ??= new Set());
    if (!line || busy.has(name)) return INVALID;
    busy.add(name);
    const value = line.part !== undefined
      ? stored_value(node.rule.parts[line.part], node.values[line.part])
      : work(node, line, outside);
    busy.delete(name);
    if (value !== LATER) memo.set(name, value);
    return value;
  }

  function work(node, line, outside) {
    if (line.needs || line.claims) {
      const result = test(line.needs ?? line.claims, node, outside);
      if (result === 'yes' || (line.claims && result === INVALID)) return 'TRUE';
      if (result === LATER) return LATER;
      fail(node, node.head + '.' + line.name + ': ' + condition_words(line.needs ?? line.claims)
        + (result === INVALID ? ' (an input is INVALID)' : ''));
      return INVALID;
    }
    if (line.cases) return mapping(node, line, outside);
    if (line.sequence) return sequence(node, line, outside);
    if (line.keep !== undefined || line.collect) return list_from(node, line, outside);
    let value;
    if (line.round) {
      const terms = (line.value.op === '/' ? line.value.terms : [line.value]).map((term) => calculate(term, node, outside));
      if (terms.includes(LATER)) return LATER;
      if (!terms.every((term) => term instanceof Exact)) return INVALID;
      const [dividend, divisor = new Exact(1n)] = terms;
      if (divisor.top === 0n) {
        fail(node, node.head + '.' + line.name + ': the divisor is 0');
        return INVALID;
      }
      value = round(over(dividend, divisor), exact(line.round.unit), line.round.direction);
    } else {
      value = calculate(line.value, node, outside);
      if (value?.range) return INVALID;
    }
    if (line.wrap !== undefined && value instanceof Exact && exact(line.wrap).top !== 0n) value = wrap(value, exact(line.wrap));
    return value;
  }

  // A numbered sequence: its positions in order, each written as a text. A number takes its
  // 'digits:', and a list is its items in order.
  function sequence(node, line, outside) {
    let written = '';
    for (const position of line.sequence) {
      if (position.literal !== undefined) { written += position.literal; continue; }
      const value = get(node, position.field, outside);
      if (stop(value)) return value;
      const items = value instanceof Sequence ? value.items : [value];
      for (const item of items) {
        if (stop(item)) return item;
        if (item instanceof Exact) {
          const digits = decimal_text(item);
          if (position.digits !== undefined && digits.replace('-', '').length > position.digits) return INVALID;
          written += position.digits === undefined ? digits : digits.padStart(position.digits, '0');
        } else if (typeof item === 'string') written += item;
        else return INVALID;
      }
    }
    return written;
  }

  // A kept list, the items of a list that meet a condition, or a collected list, one field of
  // each item of a list.
  function list_from(node, line, outside) {
    const source = get(node, line.keep ?? line.collect[0], outside);
    if (stop(source)) return source;
    if (!(source instanceof Sequence)) return INVALID;
    const around = outside && [node, ...outside];
    const items = [];
    for (const item of source.items) {
      if (!is_record(item)) return INVALID;
      const result = line.keep !== undefined ? test(line.condition, item, around) : get(item, line.collect[1], around);
      if (stop(result)) return result;
      if (result instanceof Sequence) items.push(...result.items);
      else if (line.keep === undefined) items.push(result);
      else if (result === 'yes') items.push(item);
    }
    return new Sequence(items, source.most);
  }

  // A mapping: take each input in order; stop when no case left names it; drop the cases
  // that name it and fail. Exactly one case must be left.
  function mapping(node, line, outside) {
    let cases = line.cases;
    let later = false;
    const yes = (result) => (result === LATER ? (later = true) : result === 'yes');
    const names = (when, input) => (when.all ?? when.any).some((comparison) => comparison.path[0] === input);
    for (const input of line.inputs) {
      if (!cases.some((each) => names(each.when, input))) break;
      const value = get(node, input, outside);
      if (value === LATER) return LATER;
      if (value === INVALID) return later ? LATER : INVALID;
      cases = cases.filter((each) => !names(each.when, input) || (each.when.all
        ? each.when.all.every((comparison) => comparison.path[0] !== input || yes(compare(comparison, node, outside)))
        : yes(test(each.when, node, outside))));
    }
    if (later) return LATER;
    if (cases.length === 1) return calculate(cases[0].output, node, outside);
    fail(node, node.head + '.' + line.name + ': ' + cases.length + ' cases apply');
    return INVALID;
  }

  // ---------- Paths, calculations and conditions

  function path_value(path, node, outside) {
    const [head, ...steps] = path;
    let value;
    let walk = outside && [node, ...outside];
    if (lines_of(node.rule).has(head)) value = get(node, head, outside);
    else if (steps.length === 0) return INVALID;
    else {                                            // the nearest record of that type around this one
      if (outside === null) return LATER;
      const at = walk.findIndex((record) => record.head === head);
      if (at < 0) {
        fail(node, 'there is no ' + head + ' around this ' + node.head + ', so ' + path.join('.') + ' names nothing');
        return INVALID;
      }
      value = walk[at];
      walk = walk.slice(at + 1);
    }
    for (const step of steps) {
      if (stop(value)) return value;
      if (value instanceof Sequence && folds[step]) value = folds[step](value.items);
      else if (value instanceof Sequence) {
        const items = [];
        for (const item of value.items) {
          const each = is_record(item) ? get(item, step, walk) : INVALID;
          if (stop(each)) return each;
          if (each instanceof Sequence) items.push(...each.items);
          else items.push(each);
        }
        value = new Sequence(items, value.most);
      } else if (is_record(value)) value = get(value, step, walk);
      else return INVALID;
    }
    // a list is one value only when it holds at most one item, and 0 when it has none
    if (value instanceof Sequence) return value.most !== null && value.most <= 1 ? value.items[0] ?? ZERO : INVALID;
    return value;
  }

  function calculate(expression, node, outside) {
    if (expression.number !== undefined) return exact(expression.number);
    if (expression.text !== undefined) return expression.text;
    if (expression.path) return path_value(expression.path, node, outside);
    if (expression.range) return { range: expression.range.map((end) => (end === null ? null : exact(end))) };
    if (!expression.op) return INVALID;
    const terms = expression.terms.map((term) => calculate(term, node, outside));
    if (!terms.every((term) => term instanceof Exact)) return terms.includes(LATER) ? LATER : INVALID;
    return terms.reduce({ '+': plus, '-': minus, '*': times, '/': over }[expression.op]);
  }

  // A condition: comparisons joined by & (all) or by | (any). The result is yes, no,
  // INVALID or LATER.
  function test(condition, node, outside) {
    const results = (condition.all ?? condition.any).map((comparison) => compare(comparison, node, outside));
    if (condition.all) {
      return results.includes(INVALID) ? INVALID : results.includes('no') ? 'no' : results.includes(LATER) ? LATER : 'yes';
    }
    return results.includes('yes') ? 'yes' : results.includes(INVALID) ? INVALID : results.includes(LATER) ? LATER : 'no';
  }

  function compare(comparison, node, outside) {
    if (comparison.relation) return relate(comparison, node, outside);
    const left = path_value(comparison.path, node, outside);
    if (stop(left)) return left;
    for (const each of comparison.right.choice ?? [comparison.right]) {
      const right = calculate(each, node, outside);
      if (stop(right)) return right;
      // two texts compare by the ranks of their characters when the field has an 'order:'
      const ordering = ['<', '<=', '>', '>='].includes(comparison.comparison);
      const side = ordering && typeof left === 'string' && typeof right === 'string'
        ? rank_order(ranks_of(node, comparison.path, outside), left, right) : null;
      if (side !== null ? holds_as[comparison.comparison](side) : holds(left, comparison.comparison, right)) return 'yes';
    }
    return 'no';
  }
  // A range or a text takes = (or in) only.
  function holds(left, comparison, right) {
    const equal = comparison === '=' || comparison === 'in';
    if (right?.range) {
      const [low, high] = right.range;
      return equal && left instanceof Exact && (low === null || order(low, left) <= 0) && (high === null || order(left, high) <= 0);
    }
    if (right instanceof Exact) return left instanceof Exact && holds_as[comparison](order(left, right));
    return equal && typeof right === 'string' && left === right;
  }

  // ---------- Keys of the items of a list, for 'unique:' and 'order:'

  // An item's key: a field, or a field of a field's record.
  function key_of(item, path, outside) {
    let value = item;
    for (const step of path) {
      if (!is_record(value)) return INVALID;
      const record = value;
      value = get(record, step, outside);
      outside = outside && [record, ...outside];
    }
    return value;
  }
  // What two keys must differ in: numbers by value, everything else by its text.
  const key_text = (value) =>
    value instanceof Exact ? fraction_text(value)
    : typeof value === 'string' ? value
    : value instanceof Sequence ? '[' + value.items.map(key_text).join(', ') + ']'
    : is_record(value) ? text.slice(value.start, value.end)
    : value.description;
  // The ranks that the field a path reaches orders its texts by, if it has an 'order:'.
  function ranks_of(record, path, outside) {
    for (let at = 0; is_record(record); at++) {
      const line = lines_of(record.rule).get(path[at]);
      if (at === path.length - 1) return line?.part === undefined ? undefined : record.rule.parts[line.part].ranks;
      record = get(record, path[at], outside);
    }
    return undefined;
  }
  // Two texts, character by character: the first ranks that differ decide, and a text that
  // runs out first comes first. Null when there are no ranks, or a character has none.
  function rank_order(ranks, a, b) {
    if (!ranks) return null;
    const [left, right] = [Array.from(a), Array.from(b)];
    for (let at = 0; ; at++) {
      if (at === left.length || at === right.length) return Math.sign(left.length - right.length);
      if (!Object.hasOwn(ranks, left[at]) || !Object.hasOwn(ranks, right[at])) return null;
      const side = order(exact(ranks[left[at]]), exact(ranks[right[at]]));
      if (side !== 0) return side;
    }
  }
  // While reading: no two items of a 'unique:' list share their key.
  function distinct(node, part) {
    const list = get(node, part.name, null);
    const seen = new Map();
    for (const [index, item] of (list instanceof Sequence ? list.items : []).entries()) {
      if (!is_record(item)) return true;
      const key = key_text(key_of(item, part.unique, null));
      if (seen.has(key)) {
        fail(node, node.head + '.' + part.name + ' is unique by ' + part.unique.join('.') + ', but items '
          + seen.get(key) + ' and ' + (index + 1) + ' both have ' + JSON.stringify(key));
        return false;
      }
      seen.set(key, index + 1);
    }
    return true;
  }
  // Once read: the first place where the keys of an 'order:' list go down, or null. Numbers go
  // down by value, and texts by the ranks of their field's 'order:'; other keys never do.
  function goes_down(record, part, outside) {
    const list = record.memo.get(part.name);
    const around = [record, ...outside];
    const items = list instanceof Sequence ? list.items : [];
    for (let at = 1; at < items.length; at++) {
      const [before, after] = [items[at - 1], items[at]].map((item) => key_of(item, part.order, around));
      const down = before instanceof Exact && after instanceof Exact ? order(before, after) > 0
        : typeof before === 'string' && typeof after === 'string'
          && rank_order(ranks_of(items[at - 1], part.order, around), before, after) === 1;
      if (down) {
        return record.head + '.' + part.name + ': item ' + (at + 1) + ' is out of order by ' + part.order.join('.');
      }
    }
    return null;
  }

  // A relation between two lists of this record: every value on the left is a value on the right.
  function relate(comparison, node, outside) {
    const sides = [comparison.path, comparison.right.path].map(([list, field]) => {
      const source = get(node, list, outside);
      if (stop(source)) return source;
      if (!(source instanceof Sequence)) return INVALID;
      const values = [];
      for (const item of source.items) {
        const each = is_record(item) ? get(item, field, outside && [node, ...outside]) : INVALID;
        if (stop(each)) return each;
        values.push(...(each instanceof Sequence ? each.items : [each]));
      }
      return values;
    });
    const stopped = sides.find(stop);
    if (stopped) return stopped;
    const same = (a, b) => (a instanceof Exact && b instanceof Exact ? order(a, b) === 0 : typeof a === 'string' && a === b);
    return sides[0].every((left) => sides[1].some((right) => same(left, right))) ? 'yes' : 'no';
  }

  return {
    // While reading: no field of this record is INVALID, and its 'unique:' lists hold.
    valid: (node) => [...lines_of(node.rule).keys()].every((name) => get(node, name, null) !== INVALID)
      && node.rule.parts.every((part) => !part.unique || distinct(node, part)),
    // Once the whole text is read: the value of the reading, its LATER fields worked out in
    // the records around each record, and the failures of every record that its fields hold.
    settle(node) {
      const failures = [];
      const visit = (value, outside) => {
        if (value instanceof Sequence) value.items.forEach((item) => visit(item, outside));
        if (!is_record(value)) return;
        for (const name of lines_of(value.rule).keys()) get(value, name, outside);
        failures.push(...(value.failures ?? []));
        for (const part of value.rule.parts) {
          const down = part.order && goes_down(value, part, outside);
          if (down) failures.push(down);
        }
        for (const part of value.rule.parts) if (part.name !== undefined) visit(value.memo.get(part.name), [value, ...outside]);
      };
      visit(item_value(node, false), []);
      return failures;
    },
  };
}
