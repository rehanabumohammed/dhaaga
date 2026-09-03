# ADR-0016 · Money and measurements cross the client boundary as integers

**Status** Accepted · P0 · WP-9
**Decision by** RayHaan (contract ratification), implemented in WP-9

## Context
`app.money_amount` is `numeric(14,2)`, commented *"Exact decimal currency
amount. Never float."* `measurement_value.value_numeric` is `numeric(8,3)`.
There is no `double precision`, `real` or `float` column anywhere in the schema,
and BR-04 depends on that.

Dart has no built-in exact decimal. The obvious moves are both wrong: passing a
`double` reintroduces, at the last and most visible moment, exactly the error
the ledger design exists to prevent; adding a decimal package buys exactness at
the cost of a third-party dependency in the foundation layer.

## Decision
Exact values cross the boundary as integers in the smallest unit.

* **Money**: `int` minor units — paise. `numeric(14,2)` tops out at
  999,999,999,999.99, i.e. 99,999,999,999,999 paise, comfortably inside a 64-bit
  `int`. `DhaagaMoneyText` has no constructor taking a `double`.
* **Measurements**: `int` thousandths. `numeric(8,3)` tops out at 99,999.999.

Formatting never divides. The integer part is grouped with `intl` and the
two-digit remainder is appended as text. Parsing is string arithmetic:
`41.5` becomes `41500` without `double.parse`.

A fourth decimal place is **truncated, not rounded**. `numeric(8,3)` cannot hold
it, and rounding a measurement up is not a display routine's decision.

## Consequences
* No decimal package.
* `test/components/exact_values_test.dart` checks the cases a double would fail:
  `0.1 + 0.2`, `8,80,000.07`, the largest value the column can hold, and a
  lossless parse-format round trip.
* Callers convert once, at the WP-11 boundary, where the row is read.
* The eighths a tailor actually works in are exact: 1/8 is 125 thousandths, not
  whatever 0.125 rounds to.
