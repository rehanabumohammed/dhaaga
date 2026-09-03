// Shared harness for widget tests.
//
// Every WP-9 widget needs a Localizations ancestor (its words come from the
// catalogue, never from a literal) and a DhaagaTheme ancestor (its colours come
// from tokens, never from a literal). Building both by hand in each test is how
// a suite ends up with twelve slightly different harnesses and a bug that only
// reproduces under one of them.

import 'package:dhaaga/design/theme.dart';
import 'package:dhaaga/design/tokens/palette.dart';
import 'package:dhaaga/l10n/app_localizations.dart';
import 'package:dhaaga/l10n/locale_resolution.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [child] inside the same ancestors the application provides.
///
/// [textScale] defaults to 1.0; pass DhaagaTargets.maximumTextScale to check
/// that a component survives the largest size it must support.
/// [textDirection] exists so the RTL seam can be exercised before Urdu is added.
Future<void> pumpDhaaga(
  WidgetTester tester,
  Widget child, {
  double textScale = 1.0,
  TextDirection textDirection = TextDirection.ltr,
  Locale locale = const Locale('en', 'IN'),
  Size surfaceSize = const Size(420, 900),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: dhaagaSupportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: dhaagaTheme(DhaagaColors.light),
      home: Builder(
        builder: (context) => MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: Directionality(
            textDirection: textDirection,
            child: DhaagaTheme(
              colors: DhaagaColors.light,
              child: Scaffold(body: SingleChildScrollView(child: child)),
            ),
          ),
        ),
      ),
    ),
  );
  await pumpDhaagaFrames(tester);
}

/// One frame, at a plausible refresh rate.
const Duration _frameInterval = Duration(milliseconds: 16);

/// How many of those [pumpDhaagaFrames] advances: a little under a second.
///
/// The longest transition anything in WP-9 draws is a Material Switch at
/// 200ms. A fixed count generous enough to cover it is a bound, not a timeout;
/// nothing here waits on a clock hoping something finishes.
const int _framesToPump = 60;

/// Advances a bounded slice of animation time.
///
/// Deliberately not `pumpAndSettle`. DhaagaStateView's loading state draws an
/// indeterminate LinearProgressIndicator, which by design never stops
/// animating, so settling waits for a steady state that never arrives: the
/// test fails on a ten-minute timeout rather than on the thing it was
/// checking. It did that for every test that rendered a loading state,
/// including the whole gallery, which meant one harness choice was hiding
/// whatever those tests were meant to prove.
///
/// Bounded pumping is the right instrument here. Every transition WP-9 owns is
/// either instantaneous or a short Material animation and completes inside the
/// window; an intentionally continuous animation is left mid-flight, which is
/// exactly where a test should find it. The test clock is fake and the frame
/// count fixed, so the phase reached is identical on every run — bounded
/// pumping is reproducible in a way that waiting-until-quiet is not.
Future<void> pumpDhaagaFrames(WidgetTester tester) async {
  for (var i = 0; i < _framesToPump; i++) {
    await tester.pump(_frameInterval);
  }
}

/// Fails the calling test if layout reported an overflow.
///
/// Flutter surfaces overflow as an error during layout rather than as a
/// visible failure, so a component that breaks at 2.0x text scale will
/// otherwise pass quietly. Call this after pumping.
void expectNoLayoutOverflow(WidgetTester tester) {
  final exception = tester.takeException();
  expect(
    exception,
    isNull,
    reason: 'layout overflowed: $exception\n'
        'Every component must survive the largest text scale the contract '
        'supports without clipping or truncating.',
  );
}
