// "You are working offline, and here is how long for."
//
// Offline is a supported mode, not a fault: the schema has carried
// `device.last_sync_at`, `device.offline_minutes_total`, client-generatable
// uuids and `audit_event.occurred_at`/`recorded_at` since WP-2 precisely so a
// counter keeps working when the connection does not. So this banner is
// informative, never modal — interrupting someone's work to announce degraded
// connectivity is worse than the degradation.
//
// It escalates once the device has been unsynced longer than the shop's
// tolerance. THAT TOLERANCE IS NOT IN THIS FILE. It is
// `offline.warn_after_hours`, a `config.manage` setting seeded at 48 whose
// description reads "Unsynced duration after which a device shows the
// offline-too-long state (§5.4)". The owner can change it without a release,
// which is the whole of AP-1. The caller resolves it through the WP-6
// resolvers and hands this widget a status; the number 48 appears nowhere
// here, and scan_hardcoded.py would catch it if it did — `warn_after` is
// already in its RULE_WORDS.
//
// The engine behind this — the outbox, the sync, the pull cursors — is WP-8.
// This widget takes a status and a duration and draws them.

import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens/dimensions.dart';
import '../design/tokens/typography.dart';
import '../l10n/app_localizations.dart';

enum OfflineStatus {
  /// Connected. The banner renders nothing.
  online,

  /// No connection, within the shop's tolerance. Informative.
  offline,

  /// No connection for longer than `offline.warn_after_hours`. Escalated.
  staleBeyondThreshold,
}

class DhaagaOfflineBanner extends StatelessWidget {
  const DhaagaOfflineBanner({
    required this.status,
    this.unsyncedFor,
    super.key,
  });

  final OfflineStatus status;

  /// How long since this device last reached the server. Null when unknown or
  /// never synced.
  final Duration? unsyncedFor;

  @override
  Widget build(BuildContext context) {
    if (status == OfflineStatus.online) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final colors = DhaagaTheme.of(context);
    final escalated = status == OfflineStatus.staleBeyondThreshold;

    final (Color fg, Color bg) = escalated
        ? (colors.danger, colors.dangerSurface)
        : (colors.warning, colors.warningSurface);

    final hours = unsyncedFor == null ? 0 : unsyncedFor!.inHours;

    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: DhaagaSpacing.lg,
          vertical: DhaagaSpacing.md,
        ),
        decoration: BoxDecoration(
          color: bg,
          border: Border(
            bottom: BorderSide(
              color: fg,
              width: DhaagaTargets.borderWidth,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              l10n.offlineWorking,
              style: DhaagaTypography.bodyStrong.copyWith(color: fg),
            ),
            const SizedBox(height: DhaagaSpacing.xs),
            Text(
              l10n.offlineUnsynced(hours),
              style: DhaagaTypography.numericMuted.copyWith(color: fg),
            ),
            if (escalated) ...<Widget>[
              const SizedBox(height: DhaagaSpacing.xs),
              Text(
                l10n.offlineTooLong,
                style: DhaagaTypography.body.copyWith(color: fg),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Chooses the status from a duration and a threshold.
  ///
  /// The threshold is a parameter, not a constant: it comes from
  /// `offline.warn_after_hours` via the WP-6 resolvers. Kept here as a pure
  /// function so the escalation rule is testable without a widget, and so the
  /// caller has one obvious place to apply the setting rather than each screen
  /// inventing its own comparison.
  static OfflineStatus classify({
    required bool connected,
    required Duration? unsyncedFor,
    required Duration warnAfter,
  }) {
    if (connected) return OfflineStatus.online;
    if (unsyncedFor == null) return OfflineStatus.offline;
    return unsyncedFor >= warnAfter
        ? OfflineStatus.staleBeyondThreshold
        : OfflineStatus.offline;
  }
}

/// Exposed for the gallery and tests: the tones this banner can take, without
/// needing to construct one.
const Map<OfflineStatus, String> offlineStatusDebugNames =
    <OfflineStatus, String>{
  OfflineStatus.online: 'online',
  OfflineStatus.offline: 'offline',
  OfflineStatus.staleBeyondThreshold: 'staleBeyondThreshold',
};
