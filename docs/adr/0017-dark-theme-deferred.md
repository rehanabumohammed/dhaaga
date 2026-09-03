# ADR-0017 · Dark theme is deferred, and the theme layer stays swappable

**Status** Accepted · P0 · WP-9
**Decision by** RayHaan (contract ratification, point 13)

## Context
A light and dark pair was named in the quoted WP-9 scope. Nothing in the
repository requires one, and applying the product-value test to it gave the
weakest answer of anything in the package: the stated objective is a client
"legible in a bright shop", which argues for a high-contrast **light** theme.
The dark-mode benefit is comfort in a dim back room — real, but marginal against
the cost of designing, contrast-checking and golden-testing a second palette.

## Decision
Ship one theme. Do not build dark in WP-9.

Keep the architecture ready for it at no extra cost: `DhaagaColors` is a value
class rather than a set of statics, `DhaagaTheme` is an inherited widget that
supplies an instance, and `dhaagaTheme()` takes the token set as a parameter. A
second theme is a second `DhaagaColors` instance and its own row of contrast
checks — not a refactor of any component.

## Consequences
* The golden matrix halves: five primitives × five states × **one** theme × two
  text scales.
* Every component still reads colour through `DhaagaTheme.of(context)`, so none
  of them will need touching when a second theme arrives.
* Two primitives in layer 1 (`indigo600`, `neutral700`) are unreferenced today
  and kept deliberately: they are the shape of the second palette, and removing
  them would make adding it look larger than it is.
* If dark is wanted later it is a token set, a contrast row and a golden run.
  That is the whole cost, and it was paid for in the architecture rather than in
  the scope.
