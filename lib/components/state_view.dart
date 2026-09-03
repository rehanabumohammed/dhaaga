// The five states, expressed once.
//
// Every screen WP-11 writes will need ready, loading, empty, error and
// disabled. Deciding what each looks like per screen is how an application ends
// up telling a counter "no orders" and "could not load orders" in the same
// grey italic — and those two demand opposite reactions from staff. One says
// carry on, the other says something is wrong. Conflating them is a real
// operational error, not an aesthetic one.
//
// Conventions this encodes, from the locked contract section G:
//   * loading   is in place and non-blocking. Content already on screen stays
//               readable; a counter under pressure keeps working.
//   * empty     names what is absent, in a sentence.
//   * error     names the problem where it happened and offers the remedy.
//   * disabled  is visibly inert and still perceivable (3:1), and says why to
//               a screen reader rather than going silent.
//
// Every string here comes from the catalogue. A caller with a better sentence
// than the generic one should pass it — "no orders yet" beats "nothing here
// yet" — but it must pass a localised string, not a literal.

import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens/dimensions.dart';
import '../design/tokens/typography.dart';
import '../l10n/app_localizations.dart';

enum ViewState { ready, loading, empty, error, disabled }

class DhaagaStateView extends StatelessWidget {
  const DhaagaStateView({
    required this.state,
    required this.ready,
    this.emptyMessage,
    this.errorMessage,
    this.disabledReason,
    this.onRetry,
    super.key,
  });

  final ViewState state;

  /// Built only when [state] is [ViewState.ready]. A builder rather than a
  /// widget so a caller does not pay to construct content that will not show.
  final Widget Function() ready;

  /// Catalogue-sourced. Should name what is absent.
  final String? emptyMessage;

  /// Catalogue-sourced. Should name the problem and the remedy.
  final String? errorMessage;

  /// Catalogue-sourced. Announced to assistive technology so inertness is
  /// explained rather than merely visible.
  final String? disabledReason;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = DhaagaTheme.of(context);

    return switch (state) {
      ViewState.ready => ready(),
      ViewState.loading => _Loading(label: l10n.stateLoading),
      ViewState.empty => _Message(
          text: emptyMessage ?? l10n.stateEmpty,
          color: colors.onSurfaceMuted,
        ),
      ViewState.error => _Message(
          text: errorMessage ?? l10n.stateError,
          color: colors.danger,
          background: colors.dangerSurface,
          action: onRetry == null
              ? null
              : OutlinedButton(
                  onPressed: onRetry,
                  child: Text(l10n.actionRetry),
                ),
        ),
      ViewState.disabled => Semantics(
          enabled: false,
          label: disabledReason ?? l10n.stateDisabledHint,
          child: Opacity(
            // Inert to the eye. The colour underneath still clears 3:1, so
            // "disabled" reads as deliberate rather than as broken rendering.
            opacity: 0.55,
            child: IgnorePointer(child: ready()),
          ),
        ),
    };
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = DhaagaTheme.of(context);
    // Non-blocking and in place: a bar, not a full-screen spinner over content
    // the reader was part-way through.
    return Semantics(
      liveRegion: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DhaagaSpacing.sm),
        child: LinearProgressIndicator(
          minHeight: DhaagaSpacing.xs,
          color: colors.primary,
          backgroundColor: colors.surfaceMuted,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    required this.color,
    this.background,
    this.action,
  });

  final String text;
  final Color color;
  final Color? background;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(DhaagaSpacing.lg),
      decoration: background == null
          ? null
          : BoxDecoration(
              color: background,
              borderRadius: DhaagaRadius.allMd,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(text, style: DhaagaTypography.body.copyWith(color: color)),
          if (action != null) ...<Widget>[
            const SizedBox(height: DhaagaSpacing.md),
            action!,
          ],
        ],
      ),
    );
  }
}
