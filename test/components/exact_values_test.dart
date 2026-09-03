// Money and measurements, exact.
//
// BR-04 is enforced in the database by there being no float column anywhere.
// It can still be broken on the way to a screen, by a display routine that
// divides paise by 100 or parses "41.5" with double.parse. These tests are the
// client-side half of that guarantee, and they are pure-function tests on
// purpose: a golden image would not notice a rounding error, and a widget test
// would bury it.

import 'package:dhaaga/components/measurement_field.dart';
import 'package:dhaaga/components/money_text.dart';
import 'package:dhaaga/components/offline_banner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('money formatting is exact', () {
    String fmt(int paise) => formatMinorUnits(
          amountMinorUnits: paise,
          currencyCode: 'INR',
          locale: 'en_IN',
        );

    test('whole rupees keep two decimal places', () {
      expect(fmt(250000), endsWith('2,500.00'));
    });

    test('paise are never lost', () {
      expect(fmt(1), endsWith('0.01'));
      expect(fmt(99), endsWith('0.99'));
      expect(fmt(100), endsWith('1.00'));
      expect(fmt(101), endsWith('1.01'));
    });

    test('en-IN grouping is lakh-style, not thousand-style', () {
      // 1,00,000.00 rather than 100,000.00. Getting this wrong in a tool whose
      // job is cash visibility is a defect, not a cosmetic slip.
      expect(fmt(10000000), contains('1,00,000.00'));
    });

    test('a value that a double would round is exact here', () {
      // 0.1 + 0.2 != 0.3 in binary floating point. In paise it is 10 + 20 = 30.
      expect(fmt(10 + 20), endsWith('0.30'));
      // 8,80,000.07 has no exact double representation.
      expect(fmt(88000007), contains('8,80,000.07'));
    });

    test('negatives carry the sign in front', () {
      expect(fmt(-45050), startsWith('-'));
      expect(fmt(-45050), endsWith('450.50'));
    });

    test('an explicit plus is opt-in', () {
      expect(
        formatMinorUnits(
          amountMinorUnits: 100,
          currencyCode: 'INR',
          locale: 'en_IN',
          showSign: true,
        ),
        startsWith('+'),
      );
    });

    test('the largest amount numeric(14,2) can hold survives', () {
      // 999,999,999,999.99 -> 99,999,999,999,999 paise.
      expect(fmt(99999999999999), endsWith('999.99'));
    });

    test('an unknown currency shows its code rather than a wrong symbol', () {
      final out = formatMinorUnits(
        amountMinorUnits: 100,
        currencyCode: 'ZZZ',
        locale: 'en_IN',
      );
      expect(out, contains('ZZZ'));
    });
  });

  group('measurement parsing is exact', () {
    test('a whole number becomes thousandths', () {
      expect(parseThousandths('41'), 41000);
    });

    test('one decimal place', () {
      expect(parseThousandths('41.5'), 41500);
    });

    test('three decimal places, the limit of numeric(8,3)', () {
      expect(parseThousandths('41.375'), 41375);
    });

    test('a fourth decimal place is truncated, never rounded up', () {
      // numeric(8,3) cannot hold it, and silently rounding a measurement up is
      // not a display routine's decision to make.
      expect(parseThousandths('41.3759'), 41375);
    });

    test('short fractions are padded, not misread', () {
      expect(parseThousandths('41.5'), 41500);
      expect(parseThousandths('41.05'), 41050);
      expect(parseThousandths('41.005'), 41005);
    });

    test('rubbish returns null rather than a plausible number', () {
      expect(parseThousandths(''), isNull);
      expect(parseThousandths('   '), isNull);
      expect(parseThousandths('abc'), isNull);
      expect(parseThousandths('41.5.2'), isNull);
      expect(parseThousandths('4a'), isNull);
    });

    test('formatting trims trailing zeros', () {
      expect(formatThousandths(41500), '41.5');
      expect(formatThousandths(41000), '41');
      expect(formatThousandths(41375), '41.375');
      expect(formatThousandths(null), '');
    });

    test('a parse-format round trip is lossless', () {
      for (final text in <String>['41', '41.5', '41.375', '0.125', '99999.999']) {
        expect(formatThousandths(parseThousandths(text)), text);
      }
    });

    test('the tailoring fractions are exact eighths', () {
      // A tape measure works in eighths; 1/8 is 125 thousandths exactly, not
      // whatever 0.125 happens to round to.
      final eighths = tailoringFractions.map((f) => f.thousandths).toList();
      expect(eighths, <int>[0, 125, 250, 375, 500, 625, 750, 875]);
      for (var i = 1; i < eighths.length; i++) {
        expect(eighths[i] - eighths[i - 1], 125);
      }
    });
  });

  group('offline escalation', () {
    // The threshold is a parameter because it is offline.warn_after_hours, a
    // config.manage setting the owner can change without a release (AP-1).
    const warnAfter = Duration(hours: 48);

    test('connected is online whatever the duration says', () {
      expect(
        DhaagaOfflineBanner.classify(
          connected: true,
          unsyncedFor: const Duration(days: 9),
          warnAfter: warnAfter,
        ),
        OfflineStatus.online,
      );
    });

    test('offline but within tolerance is informative, not escalated', () {
      expect(
        DhaagaOfflineBanner.classify(
          connected: false,
          unsyncedFor: const Duration(hours: 47, minutes: 59),
          warnAfter: warnAfter,
        ),
        OfflineStatus.offline,
      );
    });

    test('at the threshold it escalates', () {
      expect(
        DhaagaOfflineBanner.classify(
          connected: false,
          unsyncedFor: warnAfter,
          warnAfter: warnAfter,
        ),
        OfflineStatus.staleBeyondThreshold,
      );
    });

    test('a different threshold changes the answer, proving it is not baked in', () {
      const shopWithTighterTolerance = Duration(hours: 4);
      expect(
        DhaagaOfflineBanner.classify(
          connected: false,
          unsyncedFor: const Duration(hours: 5),
          warnAfter: shopWithTighterTolerance,
        ),
        OfflineStatus.staleBeyondThreshold,
      );
    });

    test('never synced is offline, not escalated', () {
      expect(
        DhaagaOfflineBanner.classify(
          connected: false,
          unsyncedFor: null,
          warnAfter: warnAfter,
        ),
        OfflineStatus.offline,
      );
    });
  });
}
