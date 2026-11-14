// The engine. It reads a text with rules of one shape:
//   a text is a HEAD when it is these parts in a row, and each part is that.
// rules.mjs makes the rules from declarations.
//
// A part is a literal, or one or more types that must all read the same characters (the
// reading and the ways come from the first type). A part may be a list of items, with a
// least and a most count, and no item of a list is empty. A rule may also say which numbers
// its whole text may write (ranges), how many decimal places it writes (places), and that
// the number one part writes compares with the number another part writes, or with a fixed
// number (needs).
//
// From one start in a text, the engine finds every place where a head can end, the number of
// ways it can end there (1, or 2 for "two or more"), and one reading for each end. A reading
// is a node: its head, its rule, where it starts and ends, and one value for each part of the
// rule: a node for a type, null for a literal, and a chain of item values for a list (read
// it with items_of).

const compare = {
  '=': (left, right) => left === right,
  '<': (left, right) => left < right,
  '<=': (left, right) => left <= right,
  '>': (left, right) => left > right,
  '>=': (left, right) => left >= right,
};

export function reader(rules, shortcut = true) {
  const rules_of = new Map();
  for (const rule of rules) {
    if (!rules_of.has(rule.head)) rules_of.set(rule.head, []);
    rules_of.get(rule.head).push(rule);
  }

  // Shortcut: a head whose every rule is one single character, or one such head, is a set of
  // characters. With shortcut false nothing is a set, and the answers are the same.
  const sets = new Map();
  function characters_of(type) {
    if (sets.has(type)) return sets.get(type);
    sets.set(type, null);                             // while it is worked out, it is not a set
    const own_rules = rules_of.get(type) ?? [];
    let set = shortcut && own_rules.length > 0 ? new Set() : null;
    for (const rule of own_rules) {
      const [part] = rule.parts;
      const bare = rule.parts.length === 1 && !part.list && !rule.ranges && !rule.needs;
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
    const number = (start, end) => Number(text.slice(start, end));
    const merge = (ends, end, count, node) => {
      const old = ends.get(end);
      if (old) old.count = Math.min(old.count + count, 2);
      else ends.set(end, { count: Math.min(count, 2), node });
    };

    // Do a rule's ranges, places and needs hold, when its parts end at these bounds?
    function holds(rule, bounds) {
      if (rule.ranges || rule.places !== undefined) {
        const written = text.slice(bounds[0], bounds[bounds.length - 1]);
        const value = Number(written);
        const inside = ([low, high]) => (low === null || value >= low) && (high === null || value <= high);
        if (rule.ranges && !rule.ranges.some(inside)) return false;
        const places = written.includes('.') ? written.length - written.indexOf('.') - 1 : 0;
        if (rule.places !== undefined && places !== rule.places) return false;
      }
      return (rule.needs ?? []).every((need) => compare[need.comparison](
        number(bounds[need.left], bounds[need.left + 1]),
        need.value ?? number(bounds[need.right], bounds[need.right + 1])));
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
        // A rule with needs keeps every way to place its parts apart; any other rule keeps
        // one entry for each end.
        const apart = rule.needs !== undefined;
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
          const end = bounds[bounds.length - 1];
          if (holds(rule, bounds)) merge(ends, end, count, { head: type, rule, start, end, values });
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

    return (head) => ends_of(head, 0).get(text.length) ?? { count: 0, node: null };
  }

  return {
    // In how many ways the whole text is this head: 0, 1, or 2 for "two or more".
    ways: (head, text) => session(text)(head).count,
    // The number of ways, and one reading of the whole text as this head.
    read: (head, text) => session(text)(head),
    heads: () => [...rules_of.keys()],
  };
}

// The items of a list value, in order.
export function items_of(chain) {
  const items = [];
  for (let link = chain; link; link = link.before) items.push(link.item);
  return items.reverse();
}
