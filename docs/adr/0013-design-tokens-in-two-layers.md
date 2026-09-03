# ADR-0013 · Design tokens in two layers

**Status** Accepted · P0 · WP-9
**Decision by** RayHaan (contract ratification), implemented in WP-9

## Context
WP-9 has to put a colour vocabulary in front of every screen WP-11 will write.
The repository specified none: `lib/main.dart` still carried the Flutter demo's
`Colors.deepPurple`, and no brand fact existed beyond ADR-0005 — the name means
*thread*.

The failure mode for a design system is not an ugly palette. It is a palette
scattered through widgets, where changing it means a sweep through every file
and where no test can see the values at all.

## Decision
Two layers.

* **Layer 1**, `_Primitive`, is a raw ramp, private to `palette.dart`.
* **Layer 2**, `DhaagaColors`, is semantic — `surface`, `onSurface`, `primary`,
  `danger`, `border`, `focus`. **Components bind only to layer 2.**

`DhaagaColors` is a value class rather than a set of statics, so a second theme
is a second instance rather than a refactor. Indigo is the primary: the dye this
trade was built on, and dark enough to carry white text at 12:1.

The palette values are data, ratified by looking at the component gallery
rather than by reading hex codes in a review.

## Consequences
* A palette change is an edit to one file.
* Contrast becomes a property of the token table, so `test/contrast/` can check
  all nineteen pairs in one place. Verified independently in Python before any
  value was written into Dart.
* A raw `Color(0x…)` in a component is now a defect, caught by
  `test/architecture/boundaries_test.dart` — not because literals are ugly, but
  because a literal is invisible to the contrast gate.
* `border` and `borderSubtle` are separate tokens. See ADR-0015.
