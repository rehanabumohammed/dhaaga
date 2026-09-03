// Money, displayed exactly.
//
// `app.money_amount` is `numeric(14,2)` and its comment reads "Exact decimal
// currency amount. Never float." (0002_app_foundation.sql:149,157). There is no
// `double precision`, `real` or `float` column anywhere in the schema, and
// BR-04 depends on that.
//
// Dart has no built-in exact decimal. Rather than add a decimal package, money
// crosses this boundary as an integer count of MINOR UNITS — paise — which is
// exact by construction (ADR-0016). `numeric(14,2)` tops out at
// 999,999,999,999.99, i.e. 99,999,999,999,999 paise, comfortably inside Dart's
// 64-bit int.
//
// The formatting below never divides. Dividing by 100 to get rupees would
// produce a double and reintroduce, at the last moment and in the most visible
// place, exactly the error the ledger design exists to prevent. The integer
// part is grouped and the two-digit remainder is appended as text.

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../design/theme.dart';
import '../design/tokens/typography.dart';

/// How much weight a figure carries.
enum MoneyEmphasis {
  /// A figure in a row or a sentence.
  normal,

  /// A figure a decision rests on: a total, a balance owed. Held to 7:1.
  strong,

  /// Present but subordinate: a previous value, a subtotal already summed.
  muted,
}

/// Renders an exact currency amount with tabular figures.
///
/// Takes [amountMinorUnits] — paise, not rupees, and an `int`, not a `double`.
/// There is deliberately no constructor that accepts a floating-point amount.
class DhaagaMoneyText extends StatelessWidget {
  const DhaagaMoneyText({
    required this.amountMinorUnits,
    required this.currencyCode,
    this.emphasis = MoneyEmphasis.normal,
    this.showSign = false,
    this.semanticsLabel,
    super.key,
  });

  /// Exact amount in minor units. May be negative.
  final int amountMinorUnits;

  /// ISO 4217, e.g. `INR`. Supplied by the caller from the business's
  /// configuration; this widget holds no default currency, because a default
  /// currency would be a business rule living in the client.
  final String currencyCode;

  final MoneyEmphasis emphasis;

  /// Show a leading `+` on positive amounts. Off by default; useful in a
  /// ledger view where direction matters as much as magnitude.
  final bool showSign;

  /// Overrides the announced text. Callers with context ("balance due") should
  /// pass one; the default announces the figure alone.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = DhaagaTheme.of(context);
    final locale = Localizations.localeOf(context).toString();
    final formatted = formatMinorUnits(
      amountMinorUnits: amountMinorUnits,
      currencyCode: currencyCode,
      locale: locale,
      showSign: showSign,
    );

    final (TextStyle style, Color color) = switch (emphasis) {
      MoneyEmphasis.strong => (DhaagaTypography.numericStrong, colors.onSurface),
      MoneyEmphasis.normal => (DhaagaTypography.numeric, colors.onSurface),
      MoneyEmphasis.muted => (DhaagaTypography.numericMuted, colors.onSurfaceMuted),
    };

    return Text(
      formatted,
      style: style.copyWith(color: color),
      semanticsLabel: semanticsLabel ?? formatted,
    );
  }
}

/// Formats minor units without ever producing a floating-point value.
///
/// Separated from the widget so the arithmetic can be tested directly, and so
/// a golden test is not the only thing standing between a rounding bug and a
/// customer's invoice.
String formatMinorUnits({
  required int amountMinorUnits,
  required String currencyCode,
  required String locale,
  bool showSign = false,
}) {
  final negative = amountMinorUnits < 0;

  // `abs()` on the most negative int is itself, which would flip the sign of
  // the output. The amount cannot legitimately reach that magnitude, but a
  // display routine should not be the thing that decides so silently.
  final magnitude =
      amountMinorUnits == -9223372036854775808 ? 0 : amountMinorUnits.abs();

  final major = magnitude ~/ 100;
  final minor = magnitude % 100;

  // Integer grouping only. en-IN groups as 1,00,000 rather than 100,000, which
  // intl knows and a hand-rolled formatter would get wrong.
  final grouped = NumberFormat.decimalPattern(locale).format(major);
  final symbol = _symbolFor(currencyCode, locale);

  final sign = negative ? '-' : (showSign ? '+' : '');
  final minorText = minor.toString().padLeft(2, '0');

  return '$sign$symbol$grouped.$minorText';
}

/// The currency symbol, with the code itself as the fallback. A code shown in
/// full is honest; a wrong symbol is not.
String _symbolFor(String currencyCode, String locale) {
  try {
    return NumberFormat.simpleCurrency(locale: locale, name: currencyCode)
        .currencySymbol;
  } on Exception {
    return '$currencyCode ';
  }
}
