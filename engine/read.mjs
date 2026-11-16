// The engine. It reads a text with rules of one shape:
//   a text is a HEAD when it is these parts in a row, and each part is that.
// rules.mjs makes the rules from declarations.
//
// A part is a literal, or one or more types that must all read the same characters (the
// reading and the ways come from the first type). A part may be a list of items, with a
// least and a most count, and no item of a list is empty. A rule may also say which numbers
// its whole text may write (ranges) and how many decimal places it writes (places). A
// record's rule names its stored fields among its parts, and may have fields worked out from
// them: values, kept and collected lists, mappings, rules and claims (see rules.mjs).
//
// From one start in a text, the engine finds every place where a head can end, the number of
// ways it can end there (1, or 2 for "two or more"), and one reading for each end. A reading
// is a node: its head, its rule, where it starts and ends, and one value for each part of the
// rule: a node for a type, null for a literal, and a chain of item values for a list (read
// it with items_of). A record with a field that is INVALID, or a 'unique:' list with two
// items of the same key, has no reading (evaluate.mjs).
// Once the whole text has one reading, the fields that reach a record around their own are
// worked out, and a failed rule, claim or mapping refuses the text.
import { evaluator } from './evaluate.mjs';

export function reader(rules) {
  const numeric = new Set(rules.filter((rule) => rule.number).map((rule) => rule.head));
  // the rules whose readings are checked: a record with fields or a 'unique:' list
  const checked = new Set(rules.filter((rule) => rule.fields || rule.parts.some((part) => part.unique)));
  const rules_of = new Map();
  for (const rule of rules) {
    if (!rules_of.has(rule.head)) rules_of.set(rule.head, []);
    rules_of.get(rule.head).push(rule);
  }

  // Shortcut: a head whose every rule is one single character, or one such head, is a set of
  // characters, read one character at a time.
  const sets = new Map();
  function characters_of(type) {
    if (sets.has(type)) return sets.get(type);
    sets.set(type, null);                             // while it is worked out, it is not a set
    const own_rules = rules_of.get(type) ?? [];
    let set = own_rules.length > 0 ? new Set() : null;
    for (const rule of own_rules) {
      const [part] = rule.parts;
      const bare = rule.parts.length === 1 && !part.list && !rule.ranges && !rule.fields;
      const plain = set && bare && rule.places === undefined;
      const inner = plain && part.types?.length === 1 ? characters_of(part.types[0]) : null;
      if (plain && part.literal?.length === 1) set.add(part.literal);
      else if (inner) inner.forEach((character) => set.add(character));
      else set = null;
    }
    sets.set(type, set);
    return set;
  }

  function session(text) {
    const found = new Map();
    const nowhere = new Map();
    const evaluation = evaluator(text, numeric);
    const broken = [];                                // what refused the readings of the whole text
    const merge = (ends, end, count, node) => {
      const old = ends.get(end);
      if (old) old.count = Math.min(old.count + count, 2);
      else ends.set(end, { count: Math.min(count, 2), node });
    };

    // Do a rule's ranges and places hold on this reading, and is no field of it INVALID?
    function holds(rule, node) {
      if (rule.ranges || rule.places !== undefined) {
        const written = text.slice(node.start, node.end);
        const value = Number(written);
        const inside = ([low, high]) => (low === null || value >= low) && (high === null || value <= high);
        if (rule.ranges && !rule.ranges.some(inside)) return false;
        const places = written.includes('.') ? written.length - written.indexOf('.') - 1 : 0;
        if (rule.places !== undefined && places !== rule.places) return false;
      }
      return !checked.has(rule) || evaluation.valid(node);
    }

    // Every place where a text that starts here can end as this type.
    function ends_of(type, start) {
      const set = characters_of(type);
      if (set) {
        if (!set.has(text[start])) return nowhere;
        return new Map([[start + 1, { count: 1, node: { head: type, start, end: start + 1 } }]]);
      }
      const key = type + ' ' + start;
      if (found.has(key)) return found.get(key);
      const ends = new Map();
      found.set(key, ends);                           // asked again here, it has no reading yet
      for (const rule of rules_of.get(type) ?? []) {
        // A checked rule keeps every way to place its parts apart; any other rule keeps one
        // entry for each end.
        const apart = checked.has(rule);
        let reached = [{ bounds: [start], count: 1, values: [] }];
        for (const part of rule.parts) {
          const next = new Map();
          for (const entry of reached) {
            for (const [end, result] of part_ends(part, entry.bounds[entry.bounds.length - 1])) {
              const place = apart ? entry.bounds.join() + ',' + end : end;
              const count = entry.count * result.count;
              const old = next.get(place);
              if (old) old.count = Math.min(old.count + count, 2);
              else next.set(place, { bounds: [...entry.bounds, end], count: Math.min(count, 2),
                values: [...entry.values, result.node] });
            }
          }
          reached = [...next.values()];
        }
        for (const { bounds, count, values } of reached) {
          const node = { head: type, rule, start, end: bounds[bounds.length - 1], values };
          if (holds(rule, node)) merge(ends, node.end, count, node);
          else if (start === 0 && node.end === text.length) broken.push(...(node.failures ?? []));
        }
      }
      return ends;
    }

    // One item of a part: a literal, or a type, or several types that end at the same place.
    function item_ends(part, start) {
      if (part.literal !== undefined) {
        if (!text.startsWith(part.literal, start)) return nowhere;
        return new Map([[start + part.literal.length, { count: 1, node: null }]]);
      }
      const first = ends_of(part.types[0], start);
      if (part.types.length === 1) return first;
      const others = part.types.slice(1);
      const all_end_at = ([end]) => others.every((other) => ends_of(other, start).has(end));
      return new Map([...first].filter(all_end_at));
    }

    // A part: one item, or a list of items, each of which reads at least one character.
    function part_ends(part, start) {
      if (!part.list) return item_ends(part, start);
      const least = part.least ?? 0;
      const most = part.most ?? Infinity;
      const ends = new Map();
      if (least === 0) merge(ends, start, 1, null);
      let reached = new Map([[start, { count: 1, node: null }]]);
      for (let items = 1; reached.size > 0 && items <= most; items++) {
        const next = new Map();
        for (const [from, entry] of reached) {
          for (const [end, item] of item_ends(part, from)) {
            if (end > from) merge(next, end, entry.count * item.count, { item: item.node, before: entry.node });
          }
        }
        if (items >= least) for (const [end, entry] of next) merge(ends, end, entry.count, entry.node);
        reached = next;
      }
      return ends;
    }

    return (head) => {
      const whole = ends_of(head, 0).get(text.length) ?? { count: 0, node: null, failures: [...new Set(broken)] };
      if (whole.count !== 1) return whole;
      const failures = evaluation.settle(whole.node);
      return failures.length ? { count: 0, node: whole.node, failures } : whole;
    };
  }

  return {
    // The number of ways, and one reading of the whole text as this head.
    read: (head, text) => session(text)(head),
  };
}

// The items of a list value, in order.
export function items_of(chain) {
  const items = [];
  for (let link = chain; link; link = link.before) items.push(link.item);
  return items.reverse();
}
