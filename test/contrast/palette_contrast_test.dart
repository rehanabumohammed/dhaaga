// The accessibility floor, as a build gate.
//
// The locked contract sets WCAG 2.2 AA as a universal minimum and 7:1 on the
// surfaces staff actually read. A number in a document is a good intention; a
// number in a failing test is a floor. Every semantic pair in DhaagaColors is
// listed here, so a palette change cannot quietly drop one below its threshold.
//
// The same nineteen pairs were computed independently in Python before any
// value was written into palette.dart. Two implementations agreeing is worth
// more than one asserting.
//
// The first run of that Python check failed one pair: a hairline border at
// 1.46:1 against a 3:1 requirement. That is why `border` and `borderSubtle`
// are separate tokens — see the note at the bottom of this file.

import 'dart:ui' show Color;

import 'package:dhaaga/design/contrast.dart';
import 'package:dhaaga/design/tokens/palette.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const c = DhaagaColors.light;

  final checks = <ContrastCheck>[
    // --- primary reading surfaces: 7:1 --------------------------------------
    ContrastCheck(
      label: 'body text on surface',
      foreground: c.onSurface,
      background: c.surface,
      threshold: ContrastThreshold.readingSurface,
      rationale: 'read standing, in daylight, often in uncontrolled lighting',
    ),
    ContrastCheck(
      label: 'body text on muted surface',
      foreground: c.onSurface,
      background: c.surfaceMuted,
      threshold: ContrastThreshold.readingSurface,
      rationale: 'grouped rows and input wells are read the same way',
    ),

    // --- body text: AA 4.5:1 ------------------------------------------------
    ContrastCheck(
      label: 'secondary text on surface',
      foreground: c.onSurfaceMuted,
      background: c.surface,
      threshold: ContrastThreshold.bodyText,
      rationale: 'AA body; never used for a figure a decision rests on',
    ),
    ContrastCheck(
      label: 'secondary text on muted surface',
      foreground: c.onSurfaceMuted,
      background: c.surfaceMuted,
      threshold: ContrastThreshold.bodyText,
      rationale: 'AA body',
    ),
    ContrastCheck(
      label: 'text on primary',
      foreground: c.onPrimary,
      background: c.primary,
      threshold: ContrastThreshold.bodyText,
      rationale: 'the label on the one action a surface is asking for',
    ),
    ContrastCheck(
      label: 'text on pressed primary',
      foreground: c.onPrimary,
      background: c.primaryPressed,
      threshold: ContrastThreshold.bodyText,
      rationale: 'the pressed state must not become the unreadable state',
    ),
    ContrastCheck(
      label: 'primary as text',
      foreground: c.primary,
      background: c.surface,
      threshold: ContrastThreshold.bodyText,
      rationale: 'primary used as a link or an emphasised label',
    ),
    ContrastCheck(
      label: 'text on danger',
      foreground: c.onDanger,
      background: c.danger,
      threshold: ContrastThreshold.bodyText,
      rationale: 'a destructive action must be legible, not merely alarming',
    ),
    ContrastCheck(
      label: 'danger as text on surface',
      foreground: c.danger,
      background: c.surface,
      threshold: ContrastThreshold.bodyText,
      rationale: 'error messages, stated where the problem is',
    ),
    ContrastCheck(
      label: 'danger on danger surface',
      foreground: c.danger,
      background: c.dangerSurface,
      threshold: ContrastThreshold.bodyText,
      rationale: 'the error block in DhaagaStateView',
    ),
    ContrastCheck(
      label: 'warning as text on surface',
      foreground: c.warning,
      background: c.surface,
      threshold: ContrastThreshold.bodyText,
      rationale: 'warning wording outside its own block',
    ),
    ContrastCheck(
      label: 'warning on warning surface',
      foreground: c.warning,
      background: c.warningSurface,
      threshold: ContrastThreshold.bodyText,
      rationale: 'the offline banner before it escalates',
    ),
    ContrastCheck(
      label: 'success as text on surface',
      foreground: c.success,
      background: c.surface,
      threshold: ContrastThreshold.bodyText,
      rationale: 'confirmation wording',
    ),
    ContrastCheck(
      label: 'success on success surface',
      foreground: c.success,
      background: c.successSurface,
      threshold: ContrastThreshold.bodyText,
      rationale: 'a positive status chip',
    ),

    // --- non-text: AA 1.4.11, 3:1 -------------------------------------------
    ContrastCheck(
      label: 'control border on surface',
      foreground: c.border,
      background: c.surface,
      threshold: ContrastThreshold.largeTextAndNonText,
      rationale: 'a boundary that tells someone where a control begins',
    ),
    ContrastCheck(
      label: 'control border on muted surface',
      foreground: c.border,
      background: c.surfaceMuted,
      threshold: ContrastThreshold.largeTextAndNonText,
      rationale: 'the same boundary against a filled field',
    ),
    ContrastCheck(
      label: 'focus ring on surface',
      foreground: c.focus,
      background: c.surface,
      threshold: ContrastThreshold.largeTextAndNonText,
      rationale: 'keyboard focus must be findable, not merely present',
    ),
    ContrastCheck(
      label: 'disabled foreground on muted surface',
      foreground: c.disabledForeground,
      background: c.surfaceMuted,
      threshold: ContrastThreshold.largeTextAndNonText,
      rationale: 'inert should read as deliberate, not as broken rendering',
    ),

    // --- money, called out separately because it is the highest-stakes text --
    ContrastCheck(
      label: 'money at strong emphasis',
      foreground: c.onSurface,
      background: c.surface,
      threshold: ContrastThreshold.readingSurface,
      rationale: 'a total or a balance owed; misreading it costs money',
    ),
  ];

  group('palette contrast', () {
    for (final check in checks) {
      test('${check.label} meets ${check.threshold.toStringAsFixed(1)}:1', () {
        expect(
          check.passes,
          isTrue,
          reason: 'FAILS: $check\n'
              'Do not lower the threshold. Darken the foreground or lighten '
              'the ground until the pair clears it.',
        );
      });
    }

    test('every pair is covered by a check', () {
      // A pair added to DhaagaColors and not added here would be unguarded,
      // which is how an accessibility floor quietly stops being one. This is a
      // reminder rather than reflection: Dart cannot enumerate fields, so the
      // count is asserted by hand and moves deliberately.
      expect(
        checks.length,
        19,
        reason: 'A semantic token was added or removed. Add or remove its '
            'contrast check here, then update this count.',
      );
    });
  });

  group('contrast maths', () {
    test('identical colours are 1:1', () {
      expect(contrastRatio(c.surface, c.surface), closeTo(1.0, 0.001));
    });

    test('black on white is 21:1', () {
      expect(
        contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21.0, 0.01),
      );
    });

    test('order does not matter', () {
      expect(
        contrastRatio(c.onSurface, c.surface),
        closeTo(contrastRatio(c.surface, c.onSurface), 0.0001),
      );
    });

    test('borderSubtle is BELOW the non-text threshold, deliberately', () {
      // Documented rather than fixed. borderSubtle draws dividers that carry no
      // meaning and delineate no control, which WCAG 1.4.11 exempts. If a
      // future change makes it clear a control boundary, the fix is to use
      // `border`, not to relax this expectation.
      expect(
        contrastRatio(c.borderSubtle, c.surface),
        lessThan(ContrastThreshold.largeTextAndNonText),
        reason: 'If borderSubtle now clears 3:1 the tokens may have been '
            'merged. Check that no control is outlined with it.',
      );
    });
  });
}
