// A schema status, shown as a word a person recognises.
//
// The database defines roughly forty enumerated vocabularies in CHECK
// constraints — a sales order is draft/confirmed/cancelled, a number lease is
// active/exhausted/expired/returned, a stock transfer is
// draft/in_transit/received/cancelled. Those codes are the schema's, they are
// stable, and they are not English. `in_transit` must never reach a user.
//
// This widget takes the CODE and resolves the label itself, so the resolution
// happens in one place and a screen cannot accidentally print a raw value.
//
// WP-9 ships the mechanism plus the four vocabularies the gallery exercises.
// Adding a vocabulary is two edits — a case here and its keys in the catalogue
// — and WP-11 adds them as its screens need them. That is a deliberate scope
// line, not an omission: declaring all forty now would mean forty sets of
// labels written without a screen to check them against.

import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens/dimensions.dart';
import '../design/tokens/palette.dart';
import '../design/tokens/typography.dart';
import '../l10n/app_localizations.dart';

/// A CHECK-constrained vocabulary in the schema.
enum StatusVocabulary {
  /// `sales_order.lifecycle` — draft | confirmed | cancelled
  salesOrderLifecycle,

  /// `number_lease.status` — active | exhausted | expired | returned
  numberLeaseStatus,

  /// `stock_transfer.status` — draft | in_transit | received | cancelled
  stockTransferStatus,

  /// tax document status — draft | issued | cancelled
  taxDocumentStatus,
}

/// How a status should read at a glance. Tone is about the reader's next
/// action, not about whether the state is "good": a cancelled order is not an
/// error, but it is a stop.
enum StatusTone { neutral, inProgress, positive, stopped }

class DhaagaStatusChip extends StatelessWidget {
  const DhaagaStatusChip({
    required this.statusCode,
    required this.vocabulary,
    super.key,
  });

  /// The schema's code, verbatim — `in_transit`, not `On the way`.
  final String statusCode;

  final StatusVocabulary vocabulary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = DhaagaTheme.of(context);

    final label = statusLabel(l10n, vocabulary, statusCode) ?? l10n.statusUnknown;
    final tone = statusTone(vocabulary, statusCode);
    final (Color fg, Color bg) = _toneColors(tone, colors);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: DhaagaSpacing.md,
        vertical: DhaagaSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: DhaagaRadius.allPill,
        border: Border.all(color: fg, width: DhaagaTargets.borderWidth),
      ),
      child: Text(
        label,
        style: DhaagaTypography.label.copyWith(color: fg),
      ),
    );
  }

  static (Color, Color) _toneColors(StatusTone tone, DhaagaColors c) =>
      switch (tone) {
        StatusTone.neutral => (c.onSurfaceMuted, c.surfaceMuted),
        StatusTone.inProgress => (c.primary, c.surfaceMuted),
        StatusTone.positive => (c.success, c.successSurface),
        StatusTone.stopped => (c.danger, c.dangerSurface),
      };
}

/// The label for a code, or null if this build has no word for it.
///
/// Null rather than a guess: a wrong label is worse than a visible gap, and
/// the caller shows [AppLocalizations.statusUnknown] so the gap is obvious in
/// the gallery rather than plausible in production.
String? statusLabel(
  AppLocalizations l10n,
  StatusVocabulary vocabulary,
  String code,
) =>
    switch ((vocabulary, code)) {
      (StatusVocabulary.salesOrderLifecycle, 'draft') => l10n.statusOrderDraft,
      (StatusVocabulary.salesOrderLifecycle, 'confirmed') =>
        l10n.statusOrderConfirmed,
      (StatusVocabulary.salesOrderLifecycle, 'cancelled') =>
        l10n.statusOrderCancelled,
      (StatusVocabulary.numberLeaseStatus, 'active') => l10n.statusLeaseActive,
      (StatusVocabulary.numberLeaseStatus, 'exhausted') =>
        l10n.statusLeaseExhausted,
      (StatusVocabulary.numberLeaseStatus, 'expired') => l10n.statusLeaseExpired,
      (StatusVocabulary.numberLeaseStatus, 'returned') =>
        l10n.statusLeaseReturned,
      (StatusVocabulary.stockTransferStatus, 'draft') =>
        l10n.statusTransferDraft,
      (StatusVocabulary.stockTransferStatus, 'in_transit') =>
        l10n.statusTransferInTransit,
      (StatusVocabulary.stockTransferStatus, 'received') =>
        l10n.statusTransferReceived,
      (StatusVocabulary.stockTransferStatus, 'cancelled') =>
        l10n.statusTransferCancelled,
      (StatusVocabulary.taxDocumentStatus, 'draft') => l10n.statusDocumentDraft,
      (StatusVocabulary.taxDocumentStatus, 'issued') =>
        l10n.statusDocumentIssued,
      (StatusVocabulary.taxDocumentStatus, 'cancelled') =>
        l10n.statusDocumentCancelled,
      _ => null,
    };

StatusTone statusTone(StatusVocabulary vocabulary, String code) =>
    switch ((vocabulary, code)) {
      (_, 'draft') => StatusTone.neutral,
      (_, 'cancelled') => StatusTone.stopped,
      (StatusVocabulary.salesOrderLifecycle, 'confirmed') => StatusTone.positive,
      (StatusVocabulary.numberLeaseStatus, 'active') => StatusTone.inProgress,
      (StatusVocabulary.numberLeaseStatus, 'exhausted') => StatusTone.neutral,
      (StatusVocabulary.numberLeaseStatus, 'expired') => StatusTone.stopped,
      (StatusVocabulary.numberLeaseStatus, 'returned') => StatusTone.neutral,
      (StatusVocabulary.stockTransferStatus, 'in_transit') =>
        StatusTone.inProgress,
      (StatusVocabulary.stockTransferStatus, 'received') => StatusTone.positive,
      (StatusVocabulary.taxDocumentStatus, 'issued') => StatusTone.positive,
      _ => StatusTone.neutral,
    };

/// Every (vocabulary, code) pair this build claims to render. The completeness
/// test walks these and asserts each resolves to a real label, so a catalogue
/// key removed in one place fails the suite rather than showing "Unknown" to a
/// shop.
const Map<StatusVocabulary, List<String>> declaredStatusCodes =
    <StatusVocabulary, List<String>>{
  StatusVocabulary.salesOrderLifecycle: <String>[
    'draft', 'confirmed', 'cancelled',
  ],
  StatusVocabulary.numberLeaseStatus: <String>[
    'active', 'exhausted', 'expired', 'returned',
  ],
  StatusVocabulary.stockTransferStatus: <String>[
    'draft', 'in_transit', 'received', 'cancelled',
  ],
  StatusVocabulary.taxDocumentStatus: <String>[
    'draft', 'issued', 'cancelled',
  ],
};
