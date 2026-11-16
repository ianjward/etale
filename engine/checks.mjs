// The two refusals, as questions about rules (decided on 14 November 2026). Each is one check
// for every kind of declaration, because every kind of declaration is rules of one shape.
//
// 1. No type can reach itself before it reads a character.
// 2. No item of a list, and no item that may be absent (count: 0..1), can be the empty text.
//    Such a list has more than one reading: for the empty text, any number of empty items.

// Which heads can be the empty text: add heads until nothing new follows.
function empty_heads(rules) {
  const can_be_empty = new Set();
  const item_can_be_empty = (part) =>
    part.literal !== undefined
      ? part.literal === ''
      : part.types.every((type) => can_be_empty.has(type));
  const part_can_be_empty = (part) => (part.list && (part.least ?? 0) === 0) || item_can_be_empty(part);
  for (let grew = true; grew;) {
    grew = false;
    for (const rule of rules) {
      if (!can_be_empty.has(rule.head) && rule.parts.every(part_can_be_empty)) {
        can_be_empty.add(rule.head);
        grew = true;
      }
    }
  }
  return { part_can_be_empty, item_can_be_empty };
}

// The heads that can start with themselves before any character is read.
export function starts_with_itself(rules) {
  const { part_can_be_empty } = empty_heads(rules);
  const heads = [...new Set(rules.map((rule) => rule.head))];
  const can_start = new Map(heads.map((head) => [head, new Set()]));
  for (const rule of rules) {
    for (const part of rule.parts) {
      for (const type of part.types ?? []) can_start.get(rule.head).add(type);
      if (!part_can_be_empty(part)) break;
    }
  }
  for (let grew = true; grew;) {                         // what starts my start also starts me
    grew = false;
    for (const head of heads) {
      for (const type of [...can_start.get(head)]) {
        for (const further of can_start.get(type) ?? []) {
          if (!can_start.get(head).has(further)) {
            can_start.get(head).add(further);
            grew = true;
          }
        }
      }
    }
  }
  return heads.filter((head) => can_start.get(head).has(head));
}

// The heads whose rule holds a list, or an item that may be absent, whose item can be empty.
export function lists_of_empty_items(rules) {
  const { item_can_be_empty } = empty_heads(rules);
  const holds_one = (rule) => rule.parts.some((part) => part.list && item_can_be_empty(part));
  return [...new Set(rules.filter(holds_one).map((rule) => rule.head))];
}

// The two refusals as messages, one for each declaration that they name. A head of its own
// that rules.mjs made for a line ('Owner.field') names its owner.
export function refusals(rules, declared) {
  const messages = [];
  const owner = (head) => declared.get(head) ?? declared.get(head.split('.')[0]);
  const report = (heads, words) => {
    const seen = new Set();
    for (const head of heads) {
      const declaration = owner(head);
      if (!declaration || seen.has(declaration)) continue;
      seen.add(declaration);
      messages.push(declaration.file + ':' + declaration.line + ': ' + declaration.name + ' ' + words);
    }
  };
  report(starts_with_itself(rules), 'can reach itself before it reads a character');
  report(lists_of_empty_items(rules), 'holds a list, or an optional item, whose item can be the empty text');
  return messages;
}
