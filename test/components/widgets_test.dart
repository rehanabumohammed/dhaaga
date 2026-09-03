// The primitives, rendered.
//
// These check behaviour a pure-function test cannot: that a status code never
// reaches a user as a raw code, that nothing breaks at 2.0x text scale, that
// touch targets are big enough for a thumb, and that the RTL seam works before
// Urdu exists.

import 'package:dhaaga/components/measurement_field.dart';
import 'package:dhaaga/components/money_text.dart';
import 'package:dhaaga/components/offline_banner.dart';
import 'package:dhaaga/components/reason_prompt.dart';
import 'package:dhaaga/components/state_view.dart';
import 'package:dhaaga/components/status_chip.dart';
import 'package:dhaaga/design/tokens/dimensions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump.dart';

Widget _oneOfEach() => const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DhaagaOfflineBanner(
          status: OfflineStatus.staleBeyondThreshold,
          unsyncedFor: Duration(hours: 61),
        ),
        DhaagaMoneyText(
          amountMinorUnits: 12345678,
          currencyCode: 'INR',
          emphasis: MoneyEmphasis.strong,
        ),
        DhaagaStatusChip(
          statusCode: 'in_transit',
          vocabulary: StatusVocabulary.stockTransferStatus,
        ),
      ],
    );

void main() {
  group('status chips never leak a raw code', () {
    testWidgets('every declared code resolves to a word', (tester) async {
      for (final entry in declaredStatusCodes.entries) {
        for (final code in entry.value) {
          await pumpDhaaga(
            tester,
            DhaagaStatusChip(statusCode: code, vocabulary: entry.key),
          );
          // The code itself must not be on screen.
          expect(
            find.text(code),
            findsNothing,
            reason: '${entry.key}/$code rendered as its raw code. A shop '
                'should never see "in_transit".',
          );
          // And "Unknown" means the catalogue lost a key.
          expect(
            find.text('Unknown'),
            findsNothing,
            reason: '${entry.key}/$code has no label. Either the catalogue key '
                'was removed or statusLabel lost a case.',
          );
        }
      }
    });

    testWidgets('an undeclared code shows the fallback, not the code',
        (tester) async {
      await pumpDhaaga(
        tester,
        const DhaagaStatusChip(
          statusCode: 'teleported',
          vocabulary: StatusVocabulary.salesOrderLifecycle,
        ),
      );
      expect(find.text('teleported'), findsNothing);
      expect(find.text('Unknown'), findsOneWidget);
    });
  });

  group('text scaling', () {
    testWidgets('primitives survive 2.0x without overflowing', (tester) async {
      await pumpDhaaga(
        tester,
        _oneOfEach(),
        textScale: DhaagaTargets.maximumTextScale,
      );
      expectNoLayoutOverflow(tester);
    });

    testWidgets('the measurement field survives 2.0x', (tester) async {
      await pumpDhaaga(
        tester,
        DhaagaMeasurementField(
          inputType: MeasurementInputType.fraction,
          fieldLabel: 'Chest', // dhaaga:allow-literal test fixture for a tenant-owned label
          valueThousandths: 41500,
          onChanged: (_, _) {},
        ),
        textScale: DhaagaTargets.maximumTextScale,
      );
      expectNoLayoutOverflow(tester);
    });

    testWidgets('the reason prompt survives 2.0x', (tester) async {
      await pumpDhaaga(
        tester,
        DhaagaReasonPrompt(
          domain: 'discount',
          freeTextRequired: true,
          showValidation: true,
          reasons: const <({String code, String label})>[
            (code: 'regular', label: 'Regular customer'), // dhaaga:allow-literal test fixture for a tenant-owned label
          ],
          onChanged: (_, _) {},
        ),
        textScale: DhaagaTargets.maximumTextScale,
      );
      expectNoLayoutOverflow(tester);
    });
  });

  group('touch targets', () {
    testWidgets('interactive elements clear 48dp', (tester) async {
      await pumpDhaaga(
        tester,
        DhaagaStateView(
          state: ViewState.error,
          onRetry: () {},
          ready: () => const SizedBox.shrink(),
        ),
      );
      final button = find.byType(OutlinedButton);
      expect(button, findsOneWidget);
      final size = tester.getSize(button);
      expect(
        size.height,
        greaterThanOrEqualTo(DhaagaTargets.minimumTouch),
        reason: 'a retry a staff member cannot reliably hit is not a retry',
      );
    });
  });

  group('the five states are distinguishable', () {
    testWidgets('empty and error do not render the same thing', (tester) async {
      await pumpDhaaga(
        tester,
        DhaagaStateView(state: ViewState.empty, ready: () => const SizedBox()),
      );
      expect(find.text('Nothing here yet'), findsOneWidget);

      await pumpDhaaga(
        tester,
        DhaagaStateView(state: ViewState.error, ready: () => const SizedBox()),
      );
      expect(find.text('That did not work'), findsOneWidget);
      expect(find.text('Nothing here yet'), findsNothing);
    });

    testWidgets('loading does not blank the surface', (tester) async {
      // Measured as a difference, not as an absolute count. The harness itself
      // contributes a barrier: MaterialApp's `home` is a MaterialPageRoute,
      // and ModalRoute._buildModalBarrier builds a ModalBarrier for every
      // route whether or not it has a barrierColor. A tree-wide count
      // therefore counts Flutter's barrier, not ours, and `findsNothing` could
      // never pass inside a MaterialApp however correct the component was.
      //
      // Scoping to the component's subtree would be the wrong repair here: a
      // real blocking barrier comes from showDialog and lives in the
      // Navigator's overlay, an ANCESTOR, so a descendant finder would be
      // vacuous — unable to catch the very thing this test exists to catch.
      // The difference between a ready surface and a loading one is the claim
      // the contract actually makes, so that is what is asserted.
      await pumpDhaaga(
        tester,
        DhaagaStateView(
          state: ViewState.ready,
          ready: () => const SizedBox.shrink(),
        ),
      );
      final barriersWhenReady = find.byType(ModalBarrier).evaluate().length;

      await pumpDhaaga(
        tester,
        DhaagaStateView(
          state: ViewState.loading,
          ready: () => const SizedBox.shrink(),
        ),
      );

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // Non-blocking: loading puts nothing over work already on screen.
      expect(
        find.byType(ModalBarrier).evaluate().length,
        barriersWhenReady,
        reason: 'the loading state added a modal barrier. Loading is in place '
            'and non-blocking: content already on screen stays readable and a '
            'counter under pressure keeps working.',
      );
    });

    testWidgets('disabled is inert but still rendered', (tester) async {
      await pumpDhaaga(
        tester,
        DhaagaStateView(
          state: ViewState.disabled,
          ready: () => const DhaagaMoneyText(
            amountMinorUnits: 100,
            currencyCode: 'INR',
          ),
        ),
      );
      expect(find.byType(DhaagaMoneyText), findsOneWidget);
      // Scoped to the component. A tree-wide count also picks up Flutter's
      // own: _ModalScopeState and ModalRoute._buildModalBarrier each add one,
      // Scrollable.build adds one unconditionally (the harness wraps children
      // in a SingleChildScrollView), and the page transition adds another —
      // four that have nothing to do with this widget. Ours is a DESCENDANT of
      // DhaagaStateView; every framework one is an ancestor, so this finder
      // asserts exactly what the original meant.
      expect(
        find.descendant(
          of: find.byType(DhaagaStateView),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
        reason: 'disabled must wrap its content in exactly one IgnorePointer: '
            'visibly inert, still rendered, and still readable.',
      );
    });
  });

  group('the RTL seam', () {
    // Urdu is not added (README: "Urdu addable later"). The seam is, because
    // locale.direction has carried ltr/rtl since P0 so that the layout work is
    // "a rendering concern later, not a schema change" (0004:27).
    testWidgets('primitives render right-to-left without overflowing',
        (tester) async {
      await pumpDhaaga(
        tester,
        _oneOfEach(),
        textDirection: TextDirection.rtl,
      );
      expectNoLayoutOverflow(tester);
      expect(find.byType(DhaagaStatusChip), findsOneWidget);
    });

    testWidgets('and still at 2.0x', (tester) async {
      await pumpDhaaga(
        tester,
        _oneOfEach(),
        textDirection: TextDirection.rtl,
        textScale: DhaagaTargets.maximumTextScale,
      );
      expectNoLayoutOverflow(tester);
    });
  });

  group('Devanagari renders', () {
    // locale.native_name holds 'हिन्दी' and a locale picker displays it, so
    // Devanagari must render in V1 even though Hindi is not activated. A
    // widget test cannot see tofu; what it can prove is that the glyphs lay
    // out and take space rather than collapsing.
    testWidgets('a Devanagari string lays out with non-zero width',
        (tester) async {
      await pumpDhaaga(
        tester,
        const Text('हिन्दी'), // dhaaga:allow-literal the seeded locale.native_name, under test
      );
      final size = tester.getSize(find.text('हिन्दी'));
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0));
      expectNoLayoutOverflow(tester);
    });
  });
}
