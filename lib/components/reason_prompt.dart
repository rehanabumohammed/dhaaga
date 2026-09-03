// "Why did you do that?", asked once, the same way everywhere.
//
// `reason_code` is described in the schema as "The controlled lists behind
// every 'why did you do that' prompt. The owner edits them; the domains they
// attach to are fixed." (0004_configuration.sql:226-227). Some actions cannot
// proceed without one — `audit_reason_requirement` decides which — and the
// answer is what makes the audit trail worth reading months later.
//
// Making this a component rather than a per-screen dialog is the point. If
// every screen builds its own reason dialog, some of them will make it
// skippable, and the audit trail becomes a record of the times somebody
// bothered. Here it is part of the action, and it is the same prompt whether a
// discount is being applied at the counter or stock is being written off in the
// back.
//
// The DOMAIN is application vocabulary — the CHECK constraint fixes the list —
// so its heading comes from the catalogue. The individual reason LABELS are
// tenant-owned rows the shop edits, so they arrive already resolved from the
// caller and are never translated here.

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens/dimensions.dart';
import '../design/tokens/typography.dart';
import '../l10n/app_localizations.dart';

class DhaagaReasonPrompt extends StatelessWidget {
  const DhaagaReasonPrompt({
    required this.domain,
    required this.reasons,
    required this.freeTextRequired,
    required this.onChanged,
    this.selectedCode,
    this.freeText,
    this.showValidation = false,
    this.enabled = true,
    super.key,
  });

  /// A `reason_code.domain` value — `discount`, `stock_wastage`,
  /// `payment_reversal`. Fixed by CHECK constraint, so it is application
  /// vocabulary. Carried for context and for the semantics label.
  final String domain;

  /// Rows from `reason_code` for this domain, with labels the caller has
  /// already resolved. Tenant-owned: the shop writes these words.
  final List<({String code, String label})> reasons;

  /// From `reason_code.requires_text`. When true the free-text box is not
  /// optional and the label says so.
  final bool freeTextRequired;

  final String? selectedCode;
  final String? freeText;

  /// Show the "a reason is needed" message. Off until the caller has tried to
  /// save: telling someone they have not filled in a field they have not
  /// reached yet is noise.
  final bool showValidation;

  final bool enabled;

  final void Function(String? code, String? text) onChanged;

  bool get _missingReason => selectedCode == null;

  bool get _missingText =>
      freeTextRequired && (freeText == null || freeText!.trim().isEmpty);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = DhaagaTheme.of(context);
    final invalid = showValidation && (_missingReason || _missingText);

    return Semantics(
      container: true,
      label: '${l10n.reasonPromptTitle} $domain',
      child: Container(
        padding: const EdgeInsets.all(DhaagaSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: DhaagaRadius.allMd,
          border: Border.all(
            color: invalid ? colors.danger : colors.border,
            width: DhaagaTargets.borderWidth,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              l10n.reasonPromptTitle,
              style: DhaagaTypography.titleMedium.copyWith(
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: DhaagaSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: selectedCode,
              // Without this the label is laid out at its intrinsic width and
              // the field overflows horizontally as soon as the text grows.
              // DropdownButton puts its contents in a Row and only makes them
              // flexible when isExpanded is set:
              //
              //   if (widget.isExpanded) Expanded(child: innerItemsWidget)
              //     else innerItemsWidget
              //
              // A Row gives a non-flexible child unbounded width, so the label
              // never learns how much room it has and demands a single line of
              // whatever length it needs. The width available here does not
              // grow with text scale, but the demand does, so the two cross
              // somewhere around 1.2x — well below the 2.0x the contract
              // requires, and on labels the SHOP OWNER writes and can make any
              // length. isExpanded is the framework's own hook for this; the
              // Row belongs to DropdownButton, so there is nowhere for us to
              // put a Flexible of our own.
              isExpanded: true,
              decoration: InputDecoration(
                hintText: l10n.reasonPromptChoose,
              ),
              items: <DropdownMenuItem<String>>[
                for (final r in reasons)
                  DropdownMenuItem<String>(
                    value: r.code,
                    // A MINIMUM, not a fixed height, and the distinction is
                    // load-bearing. 48 is the WCAG 2.2 target size; a fixed 48
                    // also caps the row, and once isExpanded lets the label
                    // wrap, a second line has nowhere to go. Text that exceeds
                    // its constraints does not throw — RenderParagraph sizes
                    // itself to the constraint and paints the rest clipped —
                    // so a fixed height would trade a loud overflow for a
                    // silently sliced label while the suite went green. Same
                    // intent as the minHeight constraints in
                    // measurement_field.dart.
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: DhaagaTargets.minimumTouch,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        // Tenant-owned label, resolved by the caller.
                        child: Text(r.label, style: DhaagaTypography.body),
                      ),
                    ),
                  ),
              ],
              onChanged: enabled ? (code) => onChanged(code, freeText) : null,
            ),
            const SizedBox(height: DhaagaSpacing.md),
            TextField(
              enabled: enabled,
              minLines: 2,
              maxLines: 4,
              style: DhaagaTypography.body.copyWith(color: colors.onSurface),
              controller: TextEditingController(text: freeText ?? '')
                ..selection = TextSelection.collapsed(
                  offset: (freeText ?? '').length,
                ),
              decoration: InputDecoration(
                labelText: freeTextRequired
                    ? l10n.reasonPromptDetailRequired
                    : l10n.reasonPromptDetail,
              ),
              onChanged: (t) =>
                  onChanged(selectedCode, t.trim().isEmpty ? null : t),
            ),
            if (invalid) ...<Widget>[
              const SizedBox(height: DhaagaSpacing.sm),
              Text(
                l10n.reasonRequired,
                style: DhaagaTypography.caption.copyWith(color: colors.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
