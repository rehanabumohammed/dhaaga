// Measurement entry, in the shapes the schema actually stores.
//
// `template_field.input_type` is CHECK-constrained to
// decimal | fraction | integer | select | text | boolean (0005_customers.sql:497)
// and `measurement_value.value_numeric` is `numeric(8,3)` (0005:522). No stock
// Flutter widget handles the `fraction` case, which is the one that matters
// most: a tailor works in halves, quarters and eighths, and asking someone to
// type 41.375 for 41⅜ at a counter is how a chest measurement becomes wrong.
//
// The value crosses this boundary as an integer count of THOUSANDTHS, matching
// numeric(8,3) exactly (ADR-0016). `numeric(8,3)` tops out at 99,999.999, i.e.
// 99,999,999 thousandths — nowhere near an int's limit. Nothing here parses to
// or from a double: 41.5 becomes 41500 by string arithmetic, because a measure-
// ment that survives a round trip through binary floating point is a measure-
// ment you have to apologise for later.
//
// The field label is NOT localised here. `template_field` labels are
// tenant-owned and live in the `translation` table (0005:444, 0004:78): the
// shop names its own measurements, and the caller passes the resolved string.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/theme.dart';
import '../design/tokens/dimensions.dart';
import '../design/tokens/typography.dart';
import '../l10n/app_localizations.dart';

/// Mirrors `template_field.input_type`.
enum MeasurementInputType { decimal, fraction, integer, select, text, boolean }

/// The fractions a tailor actually uses, as exact thousandths.
///
/// Eighths, because that is the granularity of a tape measure. Values are
/// exact: an eighth is 125 thousandths, not 0.125 rounded to whatever the
/// hardware nearest-representable happens to be.
const List<({int thousandths, String glyph})> tailoringFractions =
    <({int thousandths, String glyph})>[
  (thousandths: 0, glyph: '—'),
  (thousandths: 125, glyph: '⅛'), // 1/8
  (thousandths: 250, glyph: '¼'), // 1/4
  (thousandths: 375, glyph: '⅜'), // 3/8
  (thousandths: 500, glyph: '½'), // 1/2
  (thousandths: 625, glyph: '⅝'), // 5/8
  (thousandths: 750, glyph: '¾'), // 3/4
  (thousandths: 875, glyph: '⅞'), // 7/8
];

class DhaagaMeasurementField extends StatelessWidget {
  const DhaagaMeasurementField({
    required this.inputType,
    required this.fieldLabel,
    required this.onChanged,
    this.valueThousandths,
    this.valueText,
    this.options,
    this.errorMessage,
    this.enabled = true,
    super.key,
  });

  final MeasurementInputType inputType;

  /// Already resolved by the caller from the `translation` table. This widget
  /// must never look a tenant label up.
  final String fieldLabel;

  /// Exact value in thousandths. Null means empty.
  final int? valueThousandths;

  /// Used by [MeasurementInputType.text].
  final String? valueText;

  /// Used by [MeasurementInputType.select]. Labels are caller-resolved.
  final List<({String code, String label})>? options;

  final void Function(int? thousandths, String? text) onChanged;

  /// Catalogue-sourced, supplied by the caller. Shown beside the field, not as
  /// a toast: a message the reader has already dismissed helps nobody.
  final String? errorMessage;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = DhaagaTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          fieldLabel,
          style: DhaagaTypography.label.copyWith(
            color: enabled ? colors.onSurface : colors.disabledForeground,
          ),
        ),
        const SizedBox(height: DhaagaSpacing.sm),
        _control(context),
        if (errorMessage != null) ...<Widget>[
          const SizedBox(height: DhaagaSpacing.xs),
          Text(
            errorMessage!,
            style: DhaagaTypography.caption.copyWith(color: colors.danger),
          ),
        ],
      ],
    );
  }

  Widget _control(BuildContext context) => switch (inputType) {
        MeasurementInputType.fraction => _FractionEntry(
            valueThousandths: valueThousandths,
            enabled: enabled,
            onChanged: (v) => onChanged(v, null),
          ),
        MeasurementInputType.decimal => _NumberEntry(
            valueThousandths: valueThousandths,
            allowDecimalPoint: true,
            enabled: enabled,
            onChanged: (v) => onChanged(v, null),
          ),
        MeasurementInputType.integer => _NumberEntry(
            valueThousandths: valueThousandths,
            allowDecimalPoint: false,
            enabled: enabled,
            onChanged: (v) => onChanged(v, null),
          ),
        MeasurementInputType.select => _SelectEntry(
            options: options ?? const <({String code, String label})>[],
            selected: valueText,
            enabled: enabled,
            onChanged: (code) => onChanged(null, code),
          ),
        MeasurementInputType.text => _TextEntry(
            value: valueText,
            enabled: enabled,
            onChanged: (t) => onChanged(null, t),
          ),
        MeasurementInputType.boolean => _BooleanEntry(
            value: valueText == 'true',
            enabled: enabled,
            onChanged: (b) => onChanged(null, b ? 'true' : 'false'),
          ),
      };
}

// --- exact conversion, no floating point anywhere ---------------------------

/// Parses `41.5` or `41` into thousandths (41500, 41000) without a double.
///
/// Returns null when the text is not a number. More than three decimal places
/// is truncated rather than rounded: `numeric(8,3)` cannot hold the fourth
/// digit, and silently rounding a measurement up is not this widget's decision
/// to make.
int? parseThousandths(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  final negative = text.startsWith('-');
  final body = negative ? text.substring(1) : text;
  if (body.isEmpty) return null;

  final parts = body.split('.');
  if (parts.length > 2) return null;

  final wholeText = parts[0].isEmpty ? '0' : parts[0];
  if (!RegExp(r'^\d+$').hasMatch(wholeText)) return null;

  var fractionText = parts.length == 2 ? parts[1] : '';
  if (fractionText.isNotEmpty && !RegExp(r'^\d+$').hasMatch(fractionText)) {
    return null;
  }
  fractionText = fractionText.padRight(3, '0').substring(0, 3);

  final whole = int.tryParse(wholeText);
  final fraction = int.tryParse(fractionText.isEmpty ? '0' : fractionText);
  if (whole == null || fraction == null) return null;

  final total = whole * 1000 + fraction;
  return negative ? -total : total;
}

/// Renders thousandths back to text, trimming trailing zeros so 41500 shows as
/// `41.5` rather than `41.500`.
String formatThousandths(int? thousandths) {
  if (thousandths == null) return '';
  final negative = thousandths < 0;
  final magnitude = thousandths.abs();
  final whole = magnitude ~/ 1000;
  var fraction = (magnitude % 1000).toString().padLeft(3, '0');
  while (fraction.endsWith('0')) {
    fraction = fraction.substring(0, fraction.length - 1);
  }
  final sign = negative ? '-' : '';
  return fraction.isEmpty ? '$sign$whole' : '$sign$whole.$fraction';
}

// --- controls ---------------------------------------------------------------

class _FractionEntry extends StatelessWidget {
  const _FractionEntry({
    required this.valueThousandths,
    required this.enabled,
    required this.onChanged,
  });

  final int? valueThousandths;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = DhaagaTheme.of(context);

    final whole = valueThousandths == null ? null : valueThousandths! ~/ 1000;
    final fraction = valueThousandths == null ? 0 : valueThousandths! % 1000;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextField(
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(),
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            style: DhaagaTypography.numeric.copyWith(color: colors.onSurface),
            controller: TextEditingController(text: whole?.toString() ?? '')
              ..selection = TextSelection.collapsed(
                offset: (whole?.toString() ?? '').length,
              ),
            decoration: InputDecoration(labelText: l10n.measurementWhole),
            onChanged: (text) {
              final w = int.tryParse(text.trim());
              if (w == null) {
                onChanged(fraction == 0 ? null : fraction);
              } else {
                onChanged(w * 1000 + fraction);
              }
            },
          ),
        ),
        const SizedBox(width: DhaagaSpacing.md),
        Expanded(
          child: Semantics(
            label: l10n.measurementFraction,
            child: DropdownButtonFormField<int>(
              initialValue: fraction,
              decoration: InputDecoration(labelText: l10n.measurementFraction),
              style: DhaagaTypography.numeric.copyWith(color: colors.onSurface),
              items: <DropdownMenuItem<int>>[
                for (final f in tailoringFractions)
                  DropdownMenuItem<int>(
                    value: f.thousandths,
                    child: SizedBox(
                      height: DhaagaTargets.minimumTouch,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          f.thousandths == 0
                              ? l10n.measurementFractionNone
                              : f.glyph,
                          style: DhaagaTypography.numeric,
                        ),
                      ),
                    ),
                  ),
              ],
              onChanged: enabled
                  ? (f) => onChanged(((whole ?? 0) * 1000) + (f ?? 0))
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _NumberEntry extends StatelessWidget {
  const _NumberEntry({
    required this.valueThousandths,
    required this.allowDecimalPoint,
    required this.enabled,
    required this.onChanged,
  });

  final int? valueThousandths;
  final bool allowDecimalPoint;
  final bool enabled;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = DhaagaTheme.of(context);
    final text = formatThousandths(valueThousandths);

    return TextField(
      enabled: enabled,
      keyboardType: TextInputType.numberWithOptions(decimal: allowDecimalPoint),
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(
          allowDecimalPoint ? RegExp(r'[0-9.]') : RegExp(r'[0-9]'),
        ),
      ],
      style: DhaagaTypography.numeric.copyWith(color: colors.onSurface),
      controller: TextEditingController(text: text)
        ..selection = TextSelection.collapsed(offset: text.length),
      decoration: InputDecoration(
        constraints: const BoxConstraints(
          minHeight: DhaagaTargets.minimumTouch,
        ),
        errorText: null,
        helperText: null,
        hintText: l10n.measurementWhole,
      ),
      onChanged: (raw) => onChanged(parseThousandths(raw)),
    );
  }
}

class _SelectEntry extends StatelessWidget {
  const _SelectEntry({
    required this.options,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final List<({String code, String label})> options;
  final String? selected;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: selected,
      items: <DropdownMenuItem<String>>[
        for (final o in options)
          DropdownMenuItem<String>(
            value: o.code,
            child: SizedBox(
              height: DhaagaTargets.minimumTouch,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                // Caller-resolved tenant label. Not a catalogue string.
                child: Text(o.label, style: DhaagaTypography.body),
              ),
            ),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}

class _TextEntry extends StatelessWidget {
  const _TextEntry({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String? value;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = value ?? '';
    return TextField(
      enabled: enabled,
      style: DhaagaTypography.body,
      controller: TextEditingController(text: text)
        ..selection = TextSelection.collapsed(offset: text.length),
      decoration: const InputDecoration(
        constraints: BoxConstraints(minHeight: DhaagaTargets.minimumTouch),
      ),
      onChanged: (t) => onChanged(t.isEmpty ? null : t),
    );
  }
}

class _BooleanEntry extends StatelessWidget {
  const _BooleanEntry({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: DhaagaTargets.minimumTouch,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Switch(
          value: value,
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}
