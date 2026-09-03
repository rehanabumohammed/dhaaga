// Dhaaga design tokens · typography
//
// One rule here is not a matter of taste, and it is the reason this file is
// longer than a type scale needs to be:
//
//   EVERY NUMERIC STYLE USES TABULAR FIGURES.
//
// Measurements are stored as numeric(8,3) and money as numeric(14,2); staff
// read them in columns. With proportional figures a `1` is narrower than a `7`,
// so a column of measurements does not align and a chest of 41.5 reads as 415
// to someone scanning quickly. A misread measurement is a ruined garment, which
// is the single most expensive mistake this trade makes. Tabular figures cost
// nothing and remove that class of error.
//
// No font is bundled. The platform default carries Latin everywhere; whether it
// carries Devanagari on every target is UNPROVEN until the render test runs
// (ADR-0014). `locale.native_name` holds 'हिन्दी' and is displayed in V1 even
// though Hindi is not activated, so this is a functional question, not a
// stylistic one.


import 'package:flutter/widgets.dart';

/// Named type scale. Sizes are logical pixels at textScaleFactor 1.0; every one
/// of them must survive 2.0 without clipping, which test/components/ enforces.
abstract final class DhaagaTypography {
  static const _tabular = <FontFeature>[FontFeature.tabularFigures()];

  /// Screen and section titles.
  static const TextStyle titleLarge = TextStyle(
    fontSize: 22,
    height: 1.27,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle titleMedium = TextStyle(
    fontSize: 18,
    height: 1.33,
    fontWeight: FontWeight.w600,
  );

  /// Default reading size. Deliberately 16 rather than 14: this is read at
  /// arm's length, standing, in daylight.
  static const TextStyle body = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w600,
  );

  /// Field labels, chip text, helper text.
  static const TextStyle label = TextStyle(
    fontSize: 14,
    height: 1.43,
    fontWeight: FontWeight.w500,
  );

  /// The floor. Nothing user-facing is smaller than this.
  static const TextStyle caption = TextStyle(
    fontSize: 13,
    height: 1.38,
    fontWeight: FontWeight.w400,
  );

  // --- Numeric styles. Tabular, always. -------------------------------------

  /// A figure inside a sentence or a row.
  static const TextStyle numeric = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w500,
    fontFeatures: _tabular,
  );

  /// A figure a decision rests on: a total, a balance, a final measurement.
  static const TextStyle numericStrong = TextStyle(
    fontSize: 20,
    height: 1.4,
    fontWeight: FontWeight.w700,
    fontFeatures: _tabular,
  );

  /// A figure that is present but subordinate: a previous value, a unit count.
  static const TextStyle numericMuted = TextStyle(
    fontSize: 14,
    height: 1.43,
    fontWeight: FontWeight.w400,
    fontFeatures: _tabular,
  );

  /// Every style in the scale, for the test that asserts the numeric ones carry
  /// tabular figures and the prose ones do not need to.
  static const Map<String, TextStyle> all = <String, TextStyle>{
    'titleLarge': titleLarge,
    'titleMedium': titleMedium,
    'body': body,
    'bodyStrong': bodyStrong,
    'label': label,
    'caption': caption,
    'numeric': numeric,
    'numericStrong': numericStrong,
    'numericMuted': numericMuted,
  };

  /// The subset that must carry tabular figures.
  static const Map<String, TextStyle> numericStyles = <String, TextStyle>{
    'numeric': numeric,
    'numericStrong': numericStrong,
    'numericMuted': numericMuted,
  };

  /// Below this, text is not readable at arm's length in a shop.
  static const double minimumFontSize = 13;
}
