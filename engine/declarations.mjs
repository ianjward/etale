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
    if (node.head === 'Number_Literal') return { literal: slice(node), number: true };
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
    if (node.head === 'Number_Literal') return { number: slice(node) };
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
          const count = { number: slice(quantity) };
          found.count = { least: count, most: count };
        } else {
          const { low, high } = range(quantity);
          found.count = { least: low, most: high };
        }
      } else if (kind.head === 'Digits_Property') found.digits = Number(slice(value(kind, 'digits')));
      else if (kind.head === 'Places_Property') found.places = Number(slice(value(kind, 'places')));
      else if (kind.head === 'Round_Property') {
        const direction = optional(kind, 'direction');
        found.round = { unit: slice(value(kind, 'unit')), direction: direction ? slice(value(direction, 'word')) : 'even' };
      } else if (kind.head === 'Wrap_Property') found.wrap = expression(value(kind, 'modulus'));
      else found.left_out.push(slice(kind));
    }
    return found;
  }

  // Values in calculations and conditions: numbers, texts, paths, + - * /, ranges, choices
  // and ranges of characters.
  function term(node) {
    while (['Value', 'Choice_Value', 'Term', 'Calculation', 'Named_End', 'Range_Literal'].includes(node.head)) node = inner(node);
    const ends = (low, high) => ({ range: [low && term(low), high && term(high)] });
    switch (node.head) {
      case 'Number_Literal': return { number: slice(node) };
      case 'String_Literal': return { text: decode(slice(node)) };
      case 'Path': return { path: slice(node).split('.') };
      case 'Quotient': return { op: '/', terms: [term(value(node, 'dividend')), term(value(node, 'divisor'))] };
      case 'Multi_Value': return { choice: list(node, 'first', 'rest').map(term) };
      case 'Lower_Range': return ends(node.values[0], null);
      case 'Upper_Range': return ends(null, node.values[1]);
      case 'Character_Range': return { characters: ['low', 'high'].map((end) => decode(slice(value(node, end)))) };
      case 'Arithmetic': {
        const calculation = inner(node);
        return { op: { Sum: '+', Difference: '-', Product: '*' }[calculation.head], terms: list(calculation, 'first', 'rest').map(term) };
      }
      default: return ends(value(node, 'low'), value(node, 'high'));
    }
  }

  // A condition: comparisons joined by & (all) or by | (any).
  function condition(node) {
    while (node.head === 'Conditions' || node.head === 'Or_Conditions') node = inner(node);
    if (node.head === 'Single_Choice') return { any: [comparison(node)] };
    return { [node.head === 'And_Conditions' ? 'all' : 'any']: list(node, 'first', 'rest').map(comparison) };
  }
  function comparison(node) {
    let kind = value(node, 'comparison');
    if (kind.head === 'Comparison') kind = inner(kind);
    const symbol = kind.head === 'Symbol_Comparison' ? slice(value(kind, 'symbol')) : 'in';
    return { path: slice(value(node, 'field')).split('.'), comparison: symbol, right: term(value(node, 'right')) };
  }

  // A mapping: its inputs, and its cases. With one input, a case gives only its values.
  function mapping(node, line) {
    const head = value(node, 'head');
    const inputs_node = value(head, 'inputs');
    const second = optional(inputs_node, 'second');
    const inputs = [slice(value(inputs_node, 'first')), ...(second ? [slice(value(second, 'next'))] : [])];
    const cases = items_of(value(node, 'cases')).map((case_node) => {
      const output = inner(value(case_node, 'output'));
      const when = inner(value(case_node, 'when'));
      const single = (symbol, right) => ({ all: [{ path: [inputs[0]], comparison: symbol, right: term(right) }] });
      return {
        output: output.head === 'Range_Box' ? term(value(output, 'range')) : output_item(inner(value(output, 'item'))),
        when: when.head === 'Conditions' ? condition(when)
          : when.head === 'Bound_Case' ? single(slice(value(when, 'symbol')), value(when, 'bound'))
          : single('=', when),
      };
    });
    return { name: slice(value(head, 'name')), line, role: 'mapping', inputs, cases };
  }
  function output_item(node) {
    if (node.head === 'Type_Name') return { type: slice(node) };
    return node.head === 'String_Literal' ? { text: decode(slice(node)) } : { number: slice(node) };
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

  // A field line: stored, worked out (a calculation, or a list kept or collected from a list),
  // a rule, a claim or a mapping.
  function field_line(node) {
    const line = line_of(node);
    if (node.head === 'Mapped_Field') return mapping(node, line);
    const name = slice(value(node, 'name'));
    if (node.head === 'Union_Field_Line') return { name, line, role: 'stored', ...union_box(value(node, 'base')) };
    const box = base_box(value(node, 'base'));
    const extra = parens(optional(node, 'parens'));
    const { count, places, round, wrap, left_out } = properties(optional(node, 'properties'));
    const base = box.items[0].type;
    const field = { name, line, role: 'stored', ...box };
    if (places !== undefined) field.places = places;
    if (base === 'Needs' || base === 'Claims') {
      field.role = base === 'Needs' ? 'rule' : 'claim';
      if (extra.conditions) field.condition = condition(extra.conditions);
    } else if (extra.calculation) {
      field.role = box.list ? 'collected' : 'worked';
      field.value = term(extra.calculation);
    } else if (extra.conditions) {
      field.role = 'kept';
      field.condition = condition(extra.conditions);
      if (!box.list) left_out.push('a condition');
    }
    if (round) field.round = round;
    if (wrap) field.wrap = wrap;
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
