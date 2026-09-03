# ADR-0014 · gen-l10n for application chrome, and the boundary it must not cross

**Status** Accepted · P0 · WP-9
**Decision by** RayHaan (contract ratification), implemented in WP-9

## Context
`README` has asserted since WP-1 that no user-visible string is hard-coded, with
English in V1 and Hindi architecturally present from P0. Migration 0004 splits
the work in two: *"Application chrome is translated in the Flutter message
catalogues; this table exists for data the tenant owns and can add to."*

Nothing built the client half. `lib/main.dart` held four hard-coded strings.

## Decision
Adopt `flutter_localizations` and `gen-l10n`, with `en-IN` complete and `hi-IN`
carrying every key untranslated. Add `intl`, which `gen-l10n` pulls in and which
is needed in its own right for `en-IN` number grouping — `1,00,000`, not
`100,000`.

**Adopted for the build-time missing-key failure, not for convenience.** A
hand-rolled map would localise just as well and would let a missing Hindi key
reach a shop unnoticed. That property is the entire justification for the
dependency; both packages ship from the Flutter and Dart teams, so neither adds
third-party surface.

`intl` is pinned as `any` because `flutter_localizations` constrains it from the
SDK; pinning a second, tighter constraint here is how a Flutter upgrade turns
into a resolution conflict.

## Consequences
* Application chrome — including the display labels for the schema's CHECK-
  constrained enumerations and the fixed `reason_code` domains — lives in
  `lib/l10n/*.arb`.
* Tenant-owned labels stay in the `translation` table and are resolved by the
  caller. Putting `Cutting` in a catalogue would break every shop that renames
  it, and would defeat AP-1.
* `lib/l10n/app_localizations.dart` is generated on `flutter pub get` and is
  excluded from the hard-coded-string scan, since every string in it is a
  catalogue entry by construction.
* Activating Hindi becomes a data change: translate the stub and set
  `locale.is_active`.
