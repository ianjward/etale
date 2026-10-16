// JSON values for printing: numbers keep their exact source text.
import { Ok, Error, toList } from "../gleam.mjs";
import { PNum, PText, PRec, PList } from "./printer.mjs";
import { parse as parse_decimal } from "./decimal.mjs";

function convert(v) {
  if (v && typeof v === "object" && v.__num !== undefined) {
    const d = parse_decimal(v.__num);
    if (!(d instanceof Ok)) throw new globalThis.Error("not an exact number: " + v.__num);
    return new PNum(d[0]);
  }
  if (typeof v === "string") return new PText(v);
  if (typeof v === "boolean") return new PText(v ? "TRUE" : "FALSE");
  if (Array.isArray(v)) return new PList(toList(v.map(convert)));
  if (v && typeof v === "object") return new PRec(toList(Object.entries(v).map(([k, x]) => [k, convert(x)])));
  throw new globalThis.Error("null has no text");
}

export function parse_json(text) {
  try {
    const raw = JSON.parse(text, (k, v, ctx) =>
      typeof v === "number" ? { __num: ctx && ctx.source ? ctx.source : String(v) } : v);
    return new Ok(convert(raw));
  } catch (e) {
    return new Error(String(e.message || e));
  }
}
