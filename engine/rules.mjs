// Declarations to rules of one shape (see read.mjs).
//
// A declaration is what declarations.mjs finds in a reading of a file:
//   { name, line, kind: 'union', items }
//   { name, line, kind: 'intersection', types }
//   { name, line, kind: 'refinement', items: [item], list, count, allowed, constant, places }
//   { name, line, kind: 'layout', items: [item], allowed, positions: [slot...] }
//   { name, line, kind: 'record', fields: [field...], shape: [slot...] or null }
// An item is { type }, { literal } or { characters: [first, last] }. A count is
// { least, most } and allowed values are [{ low, high }...], each an expression or null:
// { number }, { name } of a constant, or { op, terms } with + - * on fixed values.
// A slot is a position: { number, items, list, count }, or in a shape { number, field, digits }.
// A field is { name, line, role, items, list, count, allowed, places, need }, where role is stored,
// worked, rule, claim or mapping, and a rule may have a need: { left, comparison, right } with
// two field names, or { left, comparison, value } with an expression.
// Each declaration may list, in left_out, what its lines say that the rules do not carry.

const written_as = { Integer: 'Integer_Literal', Decimal: 'Decimal_Literal' };

// The rules of these declarations. The scope holds every declaration that they may name: it
// gives the constants and the allowed values of a type that a 'digits:' position names. Heads
// made before are heads of their own that other rules already have, so they are not made again.
export function rules_of(declarations, scope = declarations, heads_made_before = []) {
  const by_name = new Map(scope.map((declaration) => [declaration.name, declaration]));
  const constants = new Map();
  const rules = [];
  const left_out = [];
  const made = new Set(heads_made_before);

  function value_of(expression) {
    if (expression === null || expression === undefined) return null;
    if (expression.number !== undefined) return expression.number;
    if (expression.name !== undefined) {
      if (!constants.has(expression.name)) throw new Error(expression.name + ' is not a constant');
      return constants.get(expression.name);
    }
    const values = expression.terms.map(value_of);
    const join = { '+': (a, b) => a + b, '-': (a, b) => a - b, '*': (a, b) => a * b };
    if (!join[expression.op]) throw new Error('not a fixed value');
    return values.reduce(join[expression.op]);
  }
  for (const declaration of scope) {
    if (declaration.constant === undefined) continue;
    try {
      constants.set(declaration.name, value_of(declaration.constant));
    } catch {
      // a worked-out line that is not fixed is not a constant
    }
  }
  const ranges_of = (allowed) => allowed.map(({ low, high }) => [value_of(low), value_of(high)]);
  const make = (head, list_of_rules) => {
    if (made.has(head)) return;
    made.add(head);
    rules.push(...list_of_rules());
  };

  // A part for one item.
  function item_part(item) {
    if (item.literal !== undefined) return { literal: item.literal };
    if (item.characters) {
      const [first, last] = item.characters.map((character) => character.codePointAt(0));
      const head = JSON.stringify(item.characters[0]) + '..' + JSON.stringify(item.characters[1]);
      make(head, () => Array.from({ length: last - first + 1 },
        (_, index) => ({ head, parts: [{ literal: String.fromCodePoint(first + index) }] })));
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
    return { ...part, list: true, least: value_of(count.least) ?? 0, most: value_of(count.most) };
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

  // A rule's need, as places of its parts, if both sides are one stored field each.
  function need_of(need, parts) {
    const place = (name) => parts.findIndex((part) => part.name === name && !part.list);
    const left = place(need.left);
    if (left < 0) return null;
    if (need.right === undefined) {
      try {
        return { left, comparison: need.comparison, value: value_of(need.value) };
      } catch {
        return null;
      }
    }
    const right = place(need.right);
    return right < 0 ? null : { left, comparison: need.comparison, right };
  }

  for (const declaration of declarations) {
    const head = declaration.name;
    for (const what of declaration.left_out ?? []) left_out.push(head + ' (' + what + ')');
    if (declaration.kind === 'union') {
      for (const item of declaration.items) rules.push({ head, parts: [item_part(item)] });
    } else if (declaration.kind === 'intersection') {
      rules.push({ head, parts: [{ types: declaration.types.map((type) => written_as[type] ?? type) }] });
    } else if (declaration.kind === 'refinement') {
      const part = part_of({ ...declaration, allowed: undefined }, head + '.base');
      const rule = { head, parts: [part] };
      const constant = constants.get(head);
      if (declaration.allowed) rule.ranges = ranges_of(declaration.allowed);
      if (constant !== undefined) rule.ranges = [[constant, constant]];
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
        if (!field) throw new Error(head + ': its text shape names ' + slot.field + ', not a stored field');
        return field_part(head, field, slot.digits);
      });
      const needs = [];
      for (const field of declaration.fields.filter((field) => field.role !== 'stored')) {
        const need = field.role === 'rule' && field.need ? need_of(field.need, parts) : null;
        if (need) needs.push(need);
        else left_out.push(head + '.' + field.name + ' (' + (field.role === 'worked' ? 'worked out' : 'a ' + field.role) + ')');
        for (const what of field.left_out ?? []) left_out.push(head + '.' + field.name + ' (' + what + ')');
      }
      for (const field of stored) {
        for (const what of field.left_out ?? []) left_out.push(head + '.' + field.name + ' (' + what + ')');
      }
      rules.push({ head, parts, ...(needs.length ? { needs } : {}) });
    }
  }
  return { rules, left_out };
}

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
    + (part.name ? ' (' + part.name + ')' : '');
  const range = ([low, high]) =>
    low === null ? 'at most ' + high : high === null ? 'at least ' + low : 'from ' + low + ' to ' + high;
  const needs = (rule.needs ?? []).map((need) => ', and ' + rule.parts[need.left].name + ' '
    + need.comparison + ' ' + (need.value ?? rule.parts[need.right].name));
  return 'a text is a ' + rule.head + ' when it is: '
    + (rule.parts.map(one).join(', then ') || 'nothing')
    + (rule.ranges ? ', and its number is ' + rule.ranges.map(range).join(' or ') : '')
    + (rule.places !== undefined ? ', with ' + rule.places + ' decimal places' : '')
    + needs.join('');
}
