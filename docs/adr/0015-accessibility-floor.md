# ADR-0015 · WCAG 2.2 AA as a build gate, and 7:1 where staff read

**Status** Accepted · P0 · WP-9
**Decision by** RayHaan (contract ratification), implemented in WP-9

## Context
The objective is a client usable "in a bright shop". That is not testable.
A number is.

## Decision
* **WCAG 2.2 AA is the universal enforced floor** — 4.5:1 body text, 3:1 large
  text and non-text content that identifies a control (1.4.11).
* **7:1 on primary reading surfaces**: body text, and money at strong emphasis.
* Touch targets ≥ 48 × 48 dp. Visible focus indicator. Text scaling to 2.0×
  with no overflow or truncation.

AA everywhere rather than AAA everywhere. AAA across a whole palette is
reachable only by collapsing toward black-on-white, which removes the semantic
colour distinctions that stop a staff member confirming an order when they meant
to cancel one. AAA where reading actually happens is the stronger combination
and the one that can be enforced without becoming the test people disable.

## Consequences
* `test/contrast/palette_contrast_test.dart` fails the build on a regression.
  Nineteen pairs, each carrying the reason for its threshold, so a future reader
  tempted to lower one has to read why first.
* The first run of the equivalent Python check **failed**: a hairline border at
  1.46:1 against a 3:1 requirement. WCAG 1.4.11 exempts decorative non-text
  content but not a boundary that identifies a control, so the token was split:
  `border` (control boundaries, 3.64:1) and `borderSubtle` (dividers only,
  exempt, and asserted to stay below 3:1 so the two cannot be quietly merged).
* A design that cannot meet the floor changes; the floor does not.
