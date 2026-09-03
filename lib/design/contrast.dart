// WCAG 2.2 relative luminance and contrast.
//
// This exists so the accessibility floor in the locked contract is a build
// gate rather than a good intention. test/contrast/ walks every semantic pair
// in DhaagaColors through it and fails on a regression, which means a palette
// change cannot quietly drop a pair below its threshold.
//
// The maths is WCAG 2.x, verbatim:
//   https://www.w3.org/TR/WCAG22/#dfn-relative-luminance
//   https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio
//
// The same computation was run over this palette in Python before any value
// was written into palette.dart. Two independent implementations agreeing is
// worth more than one implementation asserting.

import 'dart:math' as math;
import 'dart:ui' show Color;

/// The contrast thresholds the locked contract sets, in one place so a test
/// cannot quietly use a softer number than the contract states.
abstract final class ContrastThreshold {
  /// Primary reading surfaces. Above AA on purpose: a counter is read standing,
  /// in daylight, often by someone who did not choose the lighting.
  static const double readingSurface = 7.0;

  /// WCAG 2.2 AA, normal text (1.4.3).
  static const double bodyText = 4.5;

  /// WCAG 2.2 AA, large text (1.4.3) and non-text content (1.4.11): control
  /// boundaries, focus rings, meaningful icons.
  static const double largeTextAndNonText = 3.0;
}

/// Relative luminance of [color], per WCAG 2.2. Alpha is ignored: a token is
/// composited before it is measured, and a translucent token would make the
/// ratio depend on whatever happens to be underneath.
///
/// Uses the `.r`/`.g`/`.b` double components rather than the deprecated
/// `.value`, so `flutter analyze` stays clean.
double relativeLuminance(Color color) {
  double channel(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// Contrast ratio between two colours: 1.0 (identical) to 21.0 (black on white).
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Whether [foreground] on [background] clears [threshold].
bool meetsContrast(Color foreground, Color background, double threshold) =>
    contrastRatio(foreground, background) >= threshold;

/// One checked pair, so a failing test can say which pair and by how much
/// rather than only that something failed.
final class ContrastCheck {
  const ContrastCheck({
    required this.label,
    required this.foreground,
    required this.background,
    required this.threshold,
    required this.rationale,
  });

  final String label;
  final Color foreground;
  final Color background;
  final double threshold;

  /// Why this pair has this threshold. A future reader tempted to lower one
  /// should have to read the reason first.
  final String rationale;

  double get ratio => contrastRatio(foreground, background);
  bool get passes => ratio >= threshold;

  @override
  String toString() => '$label: ${ratio.toStringAsFixed(2)}:1 '
      '(needs ${threshold.toStringAsFixed(1)}:1) — $rationale';
}
