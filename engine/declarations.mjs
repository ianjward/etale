// The declarations of a file, from the engine's reading of it as File. The reading follows
// the types of language.etale (Step 7, Lines, Blocks and Files), so this file walks those
// types by name. It gives the declarations that rules.mjs turns into rules.
import { items_of } from './read.mjs';

export function declarations_of(text, file) {
  const line_starts = [0];
  for (let index = 0; index < text.length; index++) if (text[index] === '\n') line_starts.push(index + 1);
  const line_of = (node) => {
    let low = 0;
    let high = line_starts.length - 1;
    while (low < high) {
      const middle = (low + high + 1) >> 1;
      if (line_starts[middle] <= node.start) low = middle;
      else high = middle - 1;
    }
    return low + 1;
  };
  const slice = (node) => text.slice(node.start, node.end);
  const value = (node, name) => node.values[node.rule.parts.findIndex((part) => part.name === name)];
  const optional = (node, name) => items_of(value(node, name))[0];
  const inner = (node) => node.values[0];
  const list = (node, first, rest) =>
    [value(node, first), ...items_of(value(node, rest)).map((tail) => value(tail, 'next'))];
  const decode = (literal) =>
    literal.slice(1, -1).replace(/\\(.)/g, (_, code) => (code === 'n' ? '\n' : code));

  // Items, from Single_Item, Union_Item, Type_Name and Character_Range.
  function item(node) {
    while (node.head === 'Single_Item' || node.head === 'Union_Item') node = inner(node);
    if (node.head === 'Type_Name') return { type: slice(node) };
    if (node.head === 'String_Literal') return { literal: decode(slice(node)) };
    if (node.head === 'Number_Literal') return { literal: slice(node) };
    return { characters: [decode(slice(value(node, 'low'))), decode(slice(value(node, 'high')))] };
  }
  function base_box(node) {
    const box = inner(node);
    return { items: [item(value(box, 'item'))], list: box.head === 'List_Box' };
  }
  function union_box(node) {
    const base = inner(value(node, 'items'));
    if (base.head === 'Character_Range') return { items: [item(base)], list: false };
    return { items: list(base, 'first', 'rest').map(item), list: false };
  }

  // Fixed values: numbers, constants by name, and + - * of them.
  function expression(node) {
    while (['Named_End', 'Term', 'Calculation'].includes(node.head)) node = inner(node);
    if (node.head === 'Number_Literal') return { number: Number(slice(node)) };
    if (node.head === 'Path') return { name: slice(node) };
    if (node.head === 'Arithmetic') {
      const calculation = inner(node);
      const op = { Sum: '+', Difference: '-', Product: '*' }[calculation.head];
      return { op, terms: list(calculation, 'first', 'rest').map(expression) };
    }
    return { op: slice(node), terms: [] };
  }
  function range(node) {
    const shape = node.head === 'Range_Literal' ? inner(node) : node;
    if (shape.head === 'Lower_Range') return { low: expression(shape.values[0]), high: null };
    if (shape.head === 'Upper_Range') return { low: null, high: expression(shape.values[1]) };
    return { low: expression(value(shape, 'low')), high: expression(value(shape, 'high')) };
  }
  function allowed(node) {
    const choice = inner(node);
    if (choice.head !== 'Number_Literal') return range(choice);
    const number = expression(choice);
    return { low: number, high: number };
  }

  // What the parentheses hold: allowed values, a calculation, or conditions.
  function parens(node) {
    if (!node) return {};
    const content = inner(value(node, 'content'));
    if (content.head === 'Allowed_Choice') return { allowed: list(content, 'first', 'rest').map(allowed) };
    if (content.head === 'Range_Literal') return { allowed: [range(content)] };
    if (content.head === 'Calculation') return { calculation: content };
    return { conditions: content };
  }
  function properties(node) {
    const found = { left_out: [] };
    if (!node) return found;
    for (const property of list(node, 'first', 'rest')) {
      const kind = inner(inner(property));
      if (kind.head === 'Count_Property') {
        const quantity = inner(value(kind, 'allowed'));
        if (quantity.head === 'Natural') {
          const count = { number: Number(slice(quantity)) };
          found.count = { least: count, most: count };
        } else {
          const { low, high } = range(quantity);
          found.count = { least: low, most: high };
        }
      } else if (kind.head === 'Digits_Property') found.digits = Number(slice(value(kind, 'digits')));
      else if (kind.head === 'Places_Property') found.places = Number(slice(value(kind, 'places')));
      else found.left_out.push(slice(kind));
    }
    return found;
  }

  // A rule that compares one field with another field or a fixed value.
  function need(node) {
    const conditions = inner(node);
    if (conditions.head !== 'And_Conditions' || items_of(value(conditions, 'rest')).length > 0) return null;
    const condition = value(conditions, 'first');
    const comparison = inner(value(condition, 'comparison'));
    if (comparison.head !== 'Symbol_Comparison') return null;
    const left = slice(value(condition, 'field'));
    const right = inner(value(condition, 'right'));
    const symbol = slice(value(comparison, 'symbol'));
    if (left.includes('.')) return null;
    if (right.head === 'Number_Literal') return { left, comparison: symbol, value: expression(right) };
    if (right.head !== 'Path' || slice(right).includes('.')) return null;
    const name = slice(right);
    if (name[0] === name[0].toUpperCase()) return { left, comparison: symbol, value: { name } };
    return { left, comparison: symbol, right: name };
  }

  function refinement(node) {
    const box = base_box(value(node, 'base'));
    const extra = parens(optional(node, 'parens'));
    const { count, places, left_out } = properties(optional(node, 'properties'));
    const declaration = { name: slice(value(node, 'name')), line: line_of(node), kind: 'refinement', ...box };
    if (count) declaration.count = count;
    if (extra.allowed) declaration.allowed = extra.allowed;
    if (extra.calculation) declaration.constant = expression(extra.calculation);
    if (extra.conditions) left_out.push('a condition');
    if (places !== undefined) declaration.places = places;
    if (left_out.length) declaration.left_out = left_out;
    return declaration;
  }

  function line_declaration(node) {
    if (node.head === 'Refinement_Line') return refinement(node);
    const name = slice(value(node, 'name'));
    const line = line_of(node);
    if (node.head === 'Union_Line') return { name, line, kind: 'union', items: union_box(value(node, 'base')).items };
    const types = list(value(value(node, 'base'), 'items'), 'first', 'rest').map(slice);
    return { name, line, kind: 'intersection', types };
  }

  function layout(node) {
    const head = refinement(value(node, 'head'));
    const positions = items_of(value(node, 'positions')).map((content) => {
      const position = inner(content);
      const number = Number(slice(value(position, 'number')));
      if (position.head === 'Union_Position_Line') return { number, ...union_box(value(position, 'base')) };
      const slot = { number, ...base_box(value(position, 'base')) };
      const { count } = properties(optional(position, 'properties'));
      if (count) slot.count = count;
      return slot;
    });
    return { ...head, kind: 'layout', positions };
  }

  function field_line(node) {
    const line = line_of(node);
    if (node.head === 'Mapped_Field') return { name: slice(value(value(node, 'head'), 'name')), line, role: 'mapping' };
    const name = slice(value(node, 'name'));
    if (node.head === 'Union_Field_Line') return { name, line, role: 'stored', ...union_box(value(node, 'base')) };
    const box = base_box(value(node, 'base'));
    const extra = parens(optional(node, 'parens'));
    const { count, left_out } = properties(optional(node, 'properties'));
    const base = box.items[0].type;
    const field = { name, line, role: 'stored', ...box };
    if (base === 'Needs' || base === 'Claims') {
      field.role = base === 'Needs' ? 'rule' : 'claim';
      if (field.role === 'rule' && extra.conditions) field.need = need(extra.conditions);
    } else if (extra.calculation || extra.conditions) field.role = 'worked';
    if (extra.allowed) field.allowed = extra.allowed;
    if (count) field.count = count;
    if (left_out.length) field.left_out = left_out;
    return field;
  }

  function record(node) {
    const declaration = { name: slice(value(value(node, 'head'), 'name')), line: line_of(node), kind: 'record',
      fields: [], shape: null };
    for (const body_item of items_of(value(node, 'body'))) {
      const content = inner(value(body_item, 'line'));
      if (content.head === 'Field_Content') declaration.fields.push(field_line(inner(content)));
      else if (content.head === 'Shape') {
        declaration.shape = items_of(value(content, 'positions')).map((shape_position) => {
          const position = inner(shape_position);
          const number = Number(slice(value(position, 'number')));
          const { count, digits } = properties(optional(position, 'properties'));
          if (position.head === 'Field_Position') {
            return { number, field: slice(value(value(position, 'base'), 'field')), digits };
          }
          return { number, ...base_box(value(position, 'base')), ...(count ? { count } : {}) };
        });
      }
    }
    return declaration;
  }

  const declarations = [];
  for (const block of items_of(inner(inner(file)))) {
    const node = inner(block);
    if (node.head === 'Record_Block') declarations.push(record(node));
    else if (node.head === 'Layout_Block') declarations.push(layout(node));
    else if (node.head === 'Line_Block') declarations.push(line_declaration(inner(node)));
  }
  return declarations;
}
