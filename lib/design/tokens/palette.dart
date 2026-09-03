// Dhaaga design tokens · colour
//
// Two layers, and the separation is the whole point (ADR-0013).
//
//   Layer 1 · _Primitive  a raw ramp. Referenced by layer 2 and by nothing else.
//   Layer 2 · DhaagaColors semantic names. The ONLY names a component may use.
//
// A component that writes `Color(0x...)` or reaches into `_Primitive` has broken
// the contract: it makes a palette change a sweep through every widget instead
// of an edit to this file, and it puts a colour outside the reach of the
// contrast test in test/contrast/.
//
// Every pair below is verified against WCAG 2.2 AA by test/contrast/
// palette_contrast_test.dart, which fails the build on a regression. The
// thresholds come from the locked WP-9 contract section F:
//   * 7:1  for primary reading surfaces
//   * 4.5:1 for all other text
//   * 3:1  for non-text that identifies a control (WCAG 1.4.11)
//
// Indigo is the primary because indigo is the dye this trade was built on; it
// is also, usefully, dark enough to carry white text at 12:1.

import 'dart:ui' show Color;

/// Layer 1. Raw values. Not for use outside this file.
abstract final class _Primitive {
  static const indigo900 = Color(0xFF161E45);
  static const indigo700 = Color(0xFF243069);
  static const indigo600 = Color(0xFF2E3D85);

  static const neutral000 = Color(0xFFFFFFFF);
  static const neutral050 = Color(0xFFF7F5F2);
  static const neutral200 = Color(0xFFDAD5CE);
  static const neutral400 = Color(0xFF8D857B);
  static const neutral500 = Color(0xFF6B6560);
  static const neutral700 = Color(0xFF464240);
  static const neutral900 = Color(0xFF1B1A19);

  static const red700 = Color(0xFF9B1C1C);
  static const red050 = Color(0xFFFDECEC);

  static const amber800 = Color(0xFF7A4E00);
  static const amber100 = Color(0xFFFDF0D5);

  static const green800 = Color(0xFF175E3B);
  static const green050 = Color(0xFFE8F3ED);
}

/// Layer 2. The semantic surface every component binds to.
///
/// One instance exists today ([light]). The shape is a value class rather than
/// a set of statics so that adding a second theme later is a new instance and
/// a `Theme.of` lookup, not a refactor of every component (ADR-0017 records why
/// dark is deferred rather than absent).
final class DhaagaColors {
  const DhaagaColors({
    required this.surface,
    required this.surfaceMuted,
    required this.onSurface,
    required this.onSurfaceMuted,
    required this.primary,
    required this.onPrimary,
    required this.primaryPressed,
    required this.danger,
    required this.onDanger,
    required this.dangerSurface,
    required this.warning,
    required this.warningSurface,
    required this.success,
    required this.successSurface,
    required this.border,
    required this.borderSubtle,
    required this.focus,
    required this.disabledForeground,
  });

  /// The ground everything sits on.
  final Color surface;

  /// A recessed ground: grouped rows, input wells, the gallery's backdrop.
  final Color surfaceMuted;

  /// Primary reading text. Held to 7:1 — a counter is read in daylight.
  final Color onSurface;

  /// Secondary text. AA only; never used for a number a decision rests on.
  final Color onSurfaceMuted;

  final Color primary;
  final Color onPrimary;
  final Color primaryPressed;

  /// Destructive. Never shares a treatment with [primary]: cancelling an order
  /// and confirming one must not look alike.
  final Color danger;
  final Color onDanger;
  final Color dangerSurface;

  final Color warning;
  final Color warningSurface;

  final Color success;
  final Color successSurface;

  /// A boundary that identifies a control. Held to 3:1 (WCAG 1.4.11).
  final Color border;

  /// A divider that carries no meaning and delineates no control. Exempt from
  /// 1.4.11 and therefore NOT held to 3:1. If you are about to draw the edge of
  /// an input, a chip or a pressable row, you want [border] instead.
  final Color borderSubtle;

  final Color focus;

  /// Inert but still perceivable. WCAG exempts inactive controls; the contract
  /// asks for perceivable anyway, so this clears 3:1 on both grounds.
  final Color disabledForeground;

  static const light = DhaagaColors(
    surface: _Primitive.neutral000,
    surfaceMuted: _Primitive.neutral050,
    onSurface: _Primitive.neutral900,
    onSurfaceMuted: _Primitive.neutral500,
    primary: _Primitive.indigo700,
    onPrimary: _Primitive.neutral000,
    primaryPressed: _Primitive.indigo900,
    danger: _Primitive.red700,
    onDanger: _Primitive.neutral000,
    dangerSurface: _Primitive.red050,
    warning: _Primitive.amber800,
    warningSurface: _Primitive.amber100,
    success: _Primitive.green800,
    successSurface: _Primitive.green050,
    border: _Primitive.neutral400,
    borderSubtle: _Primitive.neutral200,
    focus: _Primitive.indigo700,
    disabledForeground: _Primitive.neutral500,
  );

  /// Deliberately unused today, and deliberately present: it is the reason
  /// [indigo600] exists in layer 1 and the reason this is a value class. Any
  /// second theme is a second instance of this class.
  static const Color reservedAccent = _Primitive.indigo600;
  static const Color reservedInk = _Primitive.neutral700;
}
