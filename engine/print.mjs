// Printing is reading run backwards (language.etale, Step 9). A literal prints as itself and
// a character as written. Spacing holds no value, so a type that reads only spaces, such as
// Pad, Gap or End_Spaces, prints its first form: a union's first item, a list's fewest items.
// So does a position of a record that holds no value inside it. Formatting a file is printing
// it from its own reading as File.
//
// The printed text must read back in exactly one way, to the same values. If it does not,
// printing fails.
import { items_of } from './read.mjs';

export function printer(rules) {
  const rules_of = new Map();
  for (const rule of rules) {
    if (!rules_of.has(rule.head)) rules_of.set(rule.head, []);
    rules_of.get(rule.head).push(rule);
  }

  const firsts = new Map();
  function first_of_type(type) {
    if (firsts.has(type)) return firsts.get(type);
    firsts.set(type, '');
    const [rule] = rules_of.get(type) ?? [];
    firsts.set(type, rule ? rule.parts.map(first_of_part).join('') : '');
    return firsts.get(type);
  }
  function first_of_part(part) {
    if (part.literal !== undefined) return part.literal;
    const one = first_of_type(part.types[0]);
    return part.list ? one.repeat(part.least ?? 0) : one;
  }

  // Does every text of a type hold only spaces? One character alone is not spacing.
  const only_spaces = new Map();
  function spaces(type) {
    if (only_spaces.has(type)) return only_spaces.get(type);
    only_spaces.set(type, true);
    const own = rules_of.get(type) ?? [];
    const found = own.length > 0 && own.every((rule) => rule.parts.every((part) =>
      (part.literal !== undefined ? /^ *$/.test(part.literal) : spaces(part.types[0]))));
    only_spaces.set(type, found);
    return found;
  }
  const one_character = (type) => (rules_of.get(type) ?? []).every((rule) =>
    rule.parts.length === 1 && rule.parts[0].literal?.length === 1);
  const spacing = (part) => part.types && spaces(part.types[0]) && !one_character(part.types[0]);

  // Does a reading hold a value: a record with a stored field, anywhere inside it?
  const holding = new WeakMap();
  function holds(node) {
    if (!node || !node.rule) return false;
    if (holding.has(node)) return holding.get(node);
    const found = (node.rule.record && node.rule.parts.some((part) => part.name !== undefined))
      || node.rule.parts.some((part, index) => items(part, node, index).some(holds));
    holding.set(node, found);
    return found;
  }
  const items = (part, node, index) => (part.list ? items_of(node.values[index]) : [node.values[index]]);

  // The text of a reading. With values only, spacing prints nothing: what is left must be the
  // same when the printed text is read back.
  function print(text, node, values_only = false) {
    if (!node) return '';
    if (!node.rule) return text.slice(node.start, node.end);
    return node.rule.parts.map((part, index) => {
      const own = items(part, node, index);
      if (part.literal !== undefined) return part.literal.repeat(own.length);
      const empty = node.rule.record && part.name === undefined && !own.some(holds);
      if (spacing(part) || empty) return values_only ? '' : first_of_part(part);
      return own.map((item) => print(text, item, values_only)).join(values_only ? '|' : '');
    }).join('');
  }

  return {
    // The canonical text of a reading of text, and whether it reads back to the same values.
    print(reader, head, text, node) {
      const printed = print(text, node);
      const again = reader.read(head, printed);
      const same = again.count === 1 && print(printed, again.node, true) === print(text, node, true);
      return { printed, same };
    },
  };
}
