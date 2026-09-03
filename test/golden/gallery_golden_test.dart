// Golden images.
//
// One golden per component, never one for the whole gallery page: a single
// page-sized golden fails whenever anything changes, which is how a visual
// regression suite becomes noise and then becomes disabled.
//
// FIRST RUN: the goldens do not exist yet and must be created deliberately,
// after a human has looked at them:
//
//     flutter test --update-goldens test/golden
//
// Review the generated PNGs before committing them. A golden committed without
// being looked at records whatever was on screen, including the bug.
//
// Goldens are font-dependent, so they are generated and compared on the same
// platform. CI runs them on Linux; a mismatch on a developer's Windows machine
// is expected and is not a failure of the component.
@Tags(<String>['golden'])
library;

import 'package:dhaaga/components/money_text.dart';
import 'package:dhaaga/components/offline_banner.dart';
import 'package:dhaaga/components/state_view.dart';
import 'package:dhaaga/components/status_chip.dart';
import 'package:dhaaga/design/tokens/dimensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump.dart';

void main() {
  Future<void> golden(
    WidgetTester tester,
    String name,
    Widget child, {
    double textScale = 1.0,
  }) async {
    await pumpDhaaga(tester, child,
        textScale: textScale, surfaceSize: const Size(420, 400));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  group('money', () {
    testWidgets('strong', (t) => golden(t, 'money_strong',
        const DhaagaMoneyText(
            amountMinorUnits: 12345678,
            currencyCode: 'INR',
            emphasis: MoneyEmphasis.strong)));
    testWidgets('negative muted', (t) => golden(t, 'money_negative',
        const DhaagaMoneyText(
            amountMinorUnits: -45050,
            currencyCode: 'INR',
            emphasis: MoneyEmphasis.muted)));
    testWidgets('strong at 2x', (t) => golden(t, 'money_strong_2x',
        const DhaagaMoneyText(
            amountMinorUnits: 12345678,
            currencyCode: 'INR',
            emphasis: MoneyEmphasis.strong),
        textScale: DhaagaTargets.maximumTextScale));
  });

  group('status', () {
    for (final entry in declaredStatusCodes.entries) {
      testWidgets('${entry.key.name} chips', (t) => golden(
            t,
            'status_${entry.key.name}',
            Wrap(
              spacing: DhaagaSpacing.sm,
              runSpacing: DhaagaSpacing.sm,
              children: <Widget>[
                for (final code in entry.value)
                  DhaagaStatusChip(statusCode: code, vocabulary: entry.key),
              ],
            ),
          ));
    }
  });

  group('offline', () {
    testWidgets('within tolerance', (t) => golden(t, 'offline_within',
        const DhaagaOfflineBanner(
            status: OfflineStatus.offline, unsyncedFor: Duration(hours: 3))));
    testWidgets('escalated', (t) => golden(t, 'offline_escalated',
        const DhaagaOfflineBanner(
            status: OfflineStatus.staleBeyondThreshold,
            unsyncedFor: Duration(hours: 61))));
  });

  group('states', () {
    for (final state in ViewState.values) {
      testWidgets(state.name, (t) => golden(
            t,
            'state_${state.name}',
            DhaagaStateView(
              state: state,
              onRetry: () {},
              ready: () => const DhaagaMoneyText(
                  amountMinorUnits: 999900, currencyCode: 'INR'),
            ),
          ));
    }
  });
}
