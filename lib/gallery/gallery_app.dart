// The component gallery.
//
// This is WP-9's acceptance artefact and it is NOT a screen. It composes
// nothing a shop uses to do a job, reads no data, and has no router — screens
// belong to WP-11 ("There are no screens; the rules are in the database and
// WP-11 onward will call them", ADR-0012:209).
//
// What it is for: rendering every primitive in every state so the palette can
// be judged by looking at it rather than by reading hex values, and so the
// golden tests have something stable to photograph. The large-text toggle
// exists because 2.0x is a requirement, and a requirement nobody can see is a
// requirement nobody checks.

import 'package:flutter/material.dart';

import '../components/measurement_field.dart';
import '../components/money_text.dart';
import '../components/offline_banner.dart';
import '../components/reason_prompt.dart';
import '../components/state_view.dart';
import '../components/status_chip.dart';
import '../design/theme.dart';
import '../design/tokens/dimensions.dart';
import '../design/tokens/palette.dart';
import '../design/tokens/typography.dart';
import '../l10n/app_localizations.dart';
import '../l10n/locale_resolution.dart';

class DhaagaGalleryApp extends StatefulWidget {
  const DhaagaGalleryApp({super.key});

  @override
  State<DhaagaGalleryApp> createState() => _DhaagaGalleryAppState();
}

class _DhaagaGalleryAppState extends State<DhaagaGalleryApp> {
  bool _largeText = false;

  @override
  Widget build(BuildContext context) {
    // Resolution uses the same function the application will: null inputs mean
    // no user override and no business default, so it lands on the seeded
    // en-IN. The gallery does not choose a language of its own.
    final locale = resolveLocale();

    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).galleryTitle,
      locale: locale,
      supportedLocales: dhaagaSupportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: dhaagaTheme(DhaagaColors.light),
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: _largeText ? DhaagaTargets.maximumTextScale : 1.0,
        maxScaleFactor: _largeText ? DhaagaTargets.maximumTextScale : 1.0,
        child: DhaagaTheme(colors: DhaagaColors.light, child: child!),
      ),
      home: _GalleryHome(
        largeText: _largeText,
        onLargeTextChanged: (v) => setState(() => _largeText = v),
      ),
    );
  }
}

class _GalleryHome extends StatelessWidget {
  const _GalleryHome({
    required this.largeText,
    required this.onLargeTextChanged,
  });

  final bool largeText;
  final ValueChanged<bool> onLargeTextChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = DhaagaTheme.of(context);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        title: Text(l10n.galleryTitle, style: DhaagaTypography.titleLarge),
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        actions: <Widget>[
          Row(
            children: <Widget>[
              Text(l10n.galleryLargeText, style: DhaagaTypography.label),
              Switch(value: largeText, onChanged: onLargeTextChanged),
              const SizedBox(width: DhaagaSpacing.sm),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(DhaagaSpacing.lg),
        children: <Widget>[
          GallerySection(
            title: l10n.gallerySectionOffline,
            child: const Column(
              children: <Widget>[
                DhaagaOfflineBanner(
                  status: OfflineStatus.offline,
                  unsyncedFor: Duration(hours: 3),
                ),
                SizedBox(height: DhaagaSpacing.md),
                DhaagaOfflineBanner(
                  status: OfflineStatus.staleBeyondThreshold,
                  unsyncedFor: Duration(hours: 61),
                ),
              ],
            ),
          ),
          GallerySection(
            title: l10n.gallerySectionMoney,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                DhaagaMoneyText(
                  amountMinorUnits: 12345678,
                  currencyCode: 'INR',
                  emphasis: MoneyEmphasis.strong,
                ),
                SizedBox(height: DhaagaSpacing.sm),
                DhaagaMoneyText(
                  amountMinorUnits: 250000,
                  currencyCode: 'INR',
                ),
                SizedBox(height: DhaagaSpacing.sm),
                DhaagaMoneyText(
                  amountMinorUnits: -45050,
                  currencyCode: 'INR',
                  emphasis: MoneyEmphasis.muted,
                ),
              ],
            ),
          ),
          GallerySection(
            title: l10n.gallerySectionStatus,
            child: Wrap(
              spacing: DhaagaSpacing.sm,
              runSpacing: DhaagaSpacing.sm,
              children: <Widget>[
                for (final entry in declaredStatusCodes.entries)
                  for (final code in entry.value)
                    DhaagaStatusChip(
                      statusCode: code,
                      vocabulary: entry.key,
                    ),
              ],
            ),
          ),
          // The measurement and reason fixtures below carry literal words with a
          // declared allowance. They stand in for rows the caller would resolve
          // from the `translation` table - a shop names its own measurements and
          // writes its own reason codes (0004:78, AP-1). Putting them in the
          // message catalogue would be the exact boundary violation this package
          // exists to prevent, so they are declared exceptions rather than keys.
          GallerySection(
            title: l10n.gallerySectionMeasurement,
            child: Column(
              children: <Widget>[
                DhaagaMeasurementField(
                  inputType: MeasurementInputType.fraction,
                  // A tenant-owned label, resolved by the caller. The gallery
                  // stands in for that caller; it is not a catalogue string.
                  fieldLabel: 'Chest', // dhaaga:allow-literal gallery fixture; a shop owns this word, not the product
                  valueThousandths: 41500,
                  onChanged: (_, _) {},
                ),
                const SizedBox(height: DhaagaSpacing.lg),
                DhaagaMeasurementField(
                  inputType: MeasurementInputType.decimal,
                  fieldLabel: 'Sleeve', // dhaaga:allow-literal gallery fixture; a shop owns this word, not the product
                  valueThousandths: 24250,
                  onChanged: (_, _) {},
                ),
                const SizedBox(height: DhaagaSpacing.lg),
                DhaagaMeasurementField(
                  inputType: MeasurementInputType.fraction,
                  fieldLabel: 'Waist', // dhaaga:allow-literal gallery fixture; a shop owns this word, not the product
                  errorMessage: AppLocalizations.of(context).measurementInvalid,
                  onChanged: (_, _) {},
                ),
                const SizedBox(height: DhaagaSpacing.lg),
                DhaagaMeasurementField(
                  inputType: MeasurementInputType.integer,
                  fieldLabel: 'Collar', // dhaaga:allow-literal gallery fixture; a shop owns this word, not the product
                  enabled: false,
                  valueThousandths: 16000,
                  onChanged: (_, _) {},
                ),
              ],
            ),
          ),
          GallerySection(
            title: l10n.gallerySectionReason,
            child: DhaagaReasonPrompt(
              domain: 'discount',
              freeTextRequired: true,
              showValidation: true,
              // Tenant-owned rows, resolved by the caller.
              reasons: const <({String code, String label})>[
                (code: 'regular', label: 'Regular customer'), // dhaaga:allow-literal gallery fixture; a shop owns this word, not the product
                (code: 'defect', label: 'Our mistake'), // dhaaga:allow-literal gallery fixture; a shop owns this word, not the product
                (code: 'bulk', label: 'Bulk order'), // dhaaga:allow-literal gallery fixture; a shop owns this word, not the product
              ],
              onChanged: (_, _) {},
            ),
          ),
          GallerySection(
            title: l10n.gallerySectionStates,
            child: Column(
              children: <Widget>[
                for (final state in ViewState.values) ...<Widget>[
                  DhaagaStateView(
                    state: state,
                    onRetry: () {},
                    ready: () => const DhaagaMoneyText(
                      amountMinorUnits: 999900,
                      currencyCode: 'INR',
                    ),
                  ),
                  const SizedBox(height: DhaagaSpacing.md),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled block. Public so golden tests can render one section at a time
/// rather than photographing the whole page, which would make every golden
/// fail whenever any component changed.
class GallerySection extends StatelessWidget {
  const GallerySection({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = DhaagaTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: DhaagaSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: DhaagaTypography.titleMedium.copyWith(color: colors.onSurface),
          ),
          const Divider(),
          const SizedBox(height: DhaagaSpacing.sm),
          child,
        ],
      ),
    );
  }
}
