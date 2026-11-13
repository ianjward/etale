//// Exact decimal numbers: a big integer mantissa and a number of places.
//// Integer is unbounded and Decimal is exact (Step 3), so nothing here rounds:
//// '+' and '-' keep the larger number of places, '*' adds them.

import gleam/int
import gleam/order.{type Order}
import gleam/string

pub type BigInt

@external(javascript, "./ffi.mjs", "big_from_string")
fn big_from_string(s: String) -> BigInt

@external(javascript, "./ffi.mjs", "big_from_int")
pub fn big(n: Int) -> BigInt

@external(javascript, "./ffi.mjs", "big_to_string")
fn big_to_string(a: BigInt) -> String

@external(javascript, "./ffi.mjs", "big_add")
fn big_add(a: BigInt, b: BigInt) -> BigInt

@external(javascript, "./ffi.mjs", "big_sub")
fn big_sub(a: BigInt, b: BigInt) -> BigInt

@external(javascript, "./ffi.mjs", "big_mul")
fn big_mul(a: BigInt, b: BigInt) -> BigInt

@external(javascript, "./ffi.mjs", "big_compare")
fn big_compare(a: BigInt, b: BigInt) -> Int

@external(javascript, "./ffi.mjs", "big_pow10")
fn big_pow10(n: Int) -> BigInt

@external(javascript, "./ffi.mjs", "big_rem")
fn big_rem(a: BigInt, b: BigInt) -> BigInt

@external(javascript, "./ffi.mjs", "big_div")
fn big_div(a: BigInt, b: BigInt) -> BigInt

@external(javascript, "./ffi.mjs", "big_to_int")
fn big_to_int(a: BigInt) -> Int

pub type Decimal {
  Decimal(mantissa: BigInt, places: Int)
}

pub fn from_int(n: Int) -> Decimal {
  Decimal(big(n), 0)
}

pub fn zero() -> Decimal {
  from_int(0)
}

/// Parse "-12", "3.50" and the like. Anything else is an error.
pub fn parse(text: String) -> Result(Decimal, Nil) {
  let #(neg, body) = case text {
    "-" <> rest -> #(True, rest)
    _ -> #(False, text)
  }
  let #(whole, frac) = case string.split_once(body, ".") {
    Ok(#(w, f)) -> #(w, f)
    Error(_) -> #(body, "")
  }
  case all_digits(whole) && whole != "" && { frac == "" || all_digits(frac) } {
    False -> Error(Nil)
    True -> {
      let m = big_from_string(whole <> frac)
      let m = case neg {
        True -> big_sub(big(0), m)
        False -> m
      }
      Ok(Decimal(m, len(frac)))
    }
  }
}

@external(javascript, "./ffi.mjs", "all_digits")
fn all_digits(s: String) -> Bool

@external(javascript, "./ffi.mjs", "length")
fn len(s: String) -> Int

@external(javascript, "./ffi.mjs", "slice")
fn cut(s: String, a: Int, b: Int) -> String

fn align(a: Decimal, b: Decimal) -> #(BigInt, BigInt, Int) {
  let p = int.max(a.places, b.places)
  #(
    big_mul(a.mantissa, big_pow10(p - a.places)),
    big_mul(b.mantissa, big_pow10(p - b.places)),
    p,
  )
}

pub fn add(a: Decimal, b: Decimal) -> Decimal {
  let #(x, y, p) = align(a, b)
  Decimal(big_add(x, y), p)
}

pub fn sub(a: Decimal, b: Decimal) -> Decimal {
  let #(x, y, p) = align(a, b)
  Decimal(big_sub(x, y), p)
}

pub fn mul(a: Decimal, b: Decimal) -> Decimal {
  Decimal(big_mul(a.mantissa, b.mantissa), a.places + b.places)
}

pub fn negate(a: Decimal) -> Decimal {
  Decimal(big_sub(big(0), a.mantissa), a.places)
}

/// Half of a value, exactly (used to sample between two boundaries).
pub fn half(a: Decimal) -> Decimal {
  Decimal(big_mul(a.mantissa, big(5)), a.places + 1)
}

pub fn compare(a: Decimal, b: Decimal) -> Order {
  let #(x, y, _) = align(a, b)
  case big_compare(x, y) {
    -1 -> order.Lt
    0 -> order.Eq
    _ -> order.Gt
  }
}

pub fn eq(a: Decimal, b: Decimal) -> Bool {
  compare(a, b) == order.Eq
}

pub fn lt(a: Decimal, b: Decimal) -> Bool {
  compare(a, b) == order.Lt
}

pub fn le(a: Decimal, b: Decimal) -> Bool {
  compare(a, b) != order.Gt
}

pub fn max(a: Decimal, b: Decimal) -> Decimal {
  case lt(a, b) {
    True -> b
    False -> a
  }
}

pub fn min(a: Decimal, b: Decimal) -> Decimal {
  case lt(a, b) {
    True -> a
    False -> b
  }
}

pub fn is_zero(a: Decimal) -> Bool {
  big_compare(a.mantissa, big(0)) == 0
}

pub fn is_integral(a: Decimal) -> Bool {
  a.places == 0
  || big_compare(big_rem(a.mantissa, big_pow10(a.places)), big(0)) == 0
}

/// The largest integer not above a value.
pub fn floor(a: Decimal) -> Decimal {
  case a.places {
    0 -> a
    p -> {
      let d = big_pow10(p)
      let q = big_div(a.mantissa, d)
      let r = big_rem(a.mantissa, d)
      let q = case big_compare(r, big(0)) < 0 {
        True -> big_sub(q, big(1))
        False -> q
      }
      Decimal(q, 0)
    }
  }
}

/// a mod m, never negative: the wrapping arithmetic of the 'mod' setting.
pub fn modulo(a: Decimal, m: Decimal) -> Decimal {
  let #(x, y, p) = align(a, m)
  let r = big_rem(x, y)
  let r = case big_compare(r, big(0)) < 0 {
    True ->
      big_add(r, case big_compare(y, big(0)) < 0 {
        True -> big_sub(big(0), y)
        False -> y
      })
    False -> r
  }
  Decimal(r, p)
}

pub fn to_int(a: Decimal) -> Int {
  big_to_int(floor(a).mantissa)
}

/// Written with its places, as a literal would be: 1200.00, -3, 0.5.
pub fn to_string(a: Decimal) -> String {
  let s = big_to_string(a.mantissa)
  let #(neg, digits) = case s {
    "-" <> rest -> #("-", rest)
    _ -> #("", s)
  }
  case a.places {
    0 -> neg <> digits
    p -> {
      let digits = string.pad_start(digits, p + 1, "0")
      let n = len(digits)
      neg <> cut(digits, 0, n - p) <> "." <> cut(digits, n - p, n)
    }
  }
}

/// Shortest form, for messages: 10, 0.5, -2.25.
pub fn to_short(a: Decimal) -> String {
  case is_integral(a) {
    True -> to_string(floor(a))
    False -> {
      let s = to_string(a)
      trim_zeros(s)
    }
  }
}

fn trim_zeros(s: String) -> String {
  case string.ends_with(s, "0") {
    True -> trim_zeros(string.drop_end(s, 1))
    False -> s
  }
}

/// The same value written with exactly n places: 19.9 -> 19.90. Fails when the
/// value needs more than n places, since printing never rounds (Step 9).
pub fn with_places(a: Decimal, n: Int) -> Result(Decimal, Nil) {
  case int.compare(a.places, n) {
    order.Eq -> Ok(a)
    order.Lt -> Ok(Decimal(big_mul(a.mantissa, big_pow10(n - a.places)), n))
    order.Gt -> {
      let d = big_pow10(a.places - n)
      case big_compare(big_rem(a.mantissa, d), big(0)) == 0 {
        True -> Ok(Decimal(big_div(a.mantissa, d), n))
        False -> Error(Nil)
      }
    }
  }
}

/// The digits of the absolute value of an integral value: -42 -> "42".
pub fn abs_digits(a: Decimal) -> String {
  let s = to_string(floor(a))
  case s {
    "-" <> rest -> rest
    _ -> s
  }
}

pub fn is_negative(a: Decimal) -> Bool {
  big_compare(a.mantissa, big(0)) < 0
}

/// A quotient cut to a number of places toward zero, with what was cut off.
/// 'kept' has exactly the places asked for; 'exact' says nothing was cut;
/// 'negative' says the exact value is below 0.
pub type Cut {
  Cut(kept: Decimal, exact: Bool, negative: Bool, cut_off: BigInt, unit: BigInt)
}

/// a / b cut to n places toward zero. Error when b is 0.
pub fn divide(a: Decimal, b: Decimal, n: Int) -> Result(Cut, Nil) {
  case is_zero(b) {
    True -> Error(Nil)
    False -> {
      let #(x, y, _) = align(a, b)
      let x = big_mul(x, big_pow10(n))
      let q = big_div(x, y)
      let r = big_rem(x, y)
      let exact = big_compare(r, big(0)) == 0
      let negative = case exact {
        True -> big_compare(q, big(0)) < 0
        False ->
          { big_compare(x, big(0)) < 0 } != { big_compare(y, big(0)) < 0 }
      }
      Ok(Cut(Decimal(q, n), exact, negative, big_abs(r), big_abs(y)))
    }
  }
}

fn big_abs(a: BigInt) -> BigInt {
  case big_compare(a, big(0)) < 0 {
    True -> big_sub(big(0), a)
    False -> a
  }
}

/// What a cut took off, as a fraction of the last place kept (0 up to but
/// not including 1), written with k places. When the fraction needs more
/// places, a 5 is put after the k places cut toward zero: the result then
/// lies strictly between two values of k places, so it compares with every
/// literal of k places or fewer exactly as the true fraction does.
pub fn cut_fraction(c: Cut, k: Int) -> Decimal {
  let scaled = big_mul(c.cut_off, big_pow10(k))
  let q = big_div(scaled, c.unit)
  case big_compare(big_rem(scaled, c.unit), big(0)) == 0 {
    True -> Decimal(q, k)
    False -> Decimal(big_add(big_mul(q, big(10)), big(5)), k + 1)
  }
}

/// The last digit kept is odd.
pub fn last_digit_odd(a: Decimal) -> Bool {
  big_compare(big_rem(big_abs(a.mantissa), big(2)), big(1)) == 0
}

/// One step of the cut's last place away from zero.
pub fn away_from_zero(c: Cut) -> Decimal {
  let step = case c.negative {
    True -> big(-1)
    False -> big(1)
  }
  Decimal(big_add(c.kept.mantissa, step), c.kept.places)
}

/// The largest value of n places not above a: floor at n places.
pub fn floor_places(a: Decimal, n: Int) -> Decimal {
  let assert Ok(c) = divide(a, from_int(1), n)
  case c.exact || !c.negative {
    True -> c.kept
    False -> away_from_zero(c)
  }
}

/// The smallest value of n places not below a: ceiling at n places.
pub fn ceiling_places(a: Decimal, n: Int) -> Decimal {
  let assert Ok(c) = divide(a, from_int(1), n)
  case c.exact || c.negative {
    True -> c.kept
    False -> away_from_zero(c)
  }
}

/// One unit of the last of n places: 0.01 for 2.
pub fn unit(n: Int) -> Decimal {
  Decimal(big(1), n)
}
