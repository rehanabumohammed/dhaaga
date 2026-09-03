// The catalogues, and the rule that keeps Hindi a data change.
//
// Two guards live here, and the locked contract is explicit that neither is
// sufficient alone:
//
//   * gen-l10n reports a key present in the template and missing from a locale.
//     It cannot see a string that was never added to a catalogue at all.
//   * scan_hardcoded.py's user-visible-string pass catches strings that never
//     entered a catalogue. It cannot see a key added and left untranslated.
//
// This file is the hard gate for the first: it reads the .arb files directly,
// so deleting a key fails the suite rather than printing a note somebody may
// not read.

import 'dart:convert';
import 'dart:io';

import 'package:dhaaga/l10n/locale_resolution.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

File _arbFile(String name) => File('lib/l10n/$name');

/// Reads a catalogue, asserting it is there first.
///
/// Called from inside each test rather than once in the group body. `expect`
/// outside a test runs at collection time, where there is no test for it to
/// fail: flutter_test raises OutsideTestException and the whole file is
/// reported as a load error, so a missing catalogue took the locale-resolution
/// tests down with it and none of them said why. The assertion is unchanged —
/// only where it runs is.
Map<String, dynamic> _readArb(String name) {
  final file = _arbFile(name);
  expect(file.existsSync(), isTrue, reason: 'missing catalogue: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Set<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

void main() {
  group('message catalogues', () {
    test('both catalogues are present', () {
      // Named on its own so that a deleted or renamed .arb reports as exactly
      // that, rather than as five unrelated failures.
      for (final name in <String>['app_en.arb', 'app_hi.arb']) {
        expect(
          _arbFile(name).existsSync(),
          isTrue,
          reason: 'missing catalogue: ${_arbFile(name).path}',
        );
      }
    });

    test('en-IN is the template and is not empty', () {
      final en = _readArb('app_en.arb');
      expect(en['@@locale'], 'en');
      expect(_messageKeys(en), isNotEmpty);
    });

    test('hi-IN carries every en-IN key', () {
      final en = _readArb('app_en.arb');
      final hi = _readArb('app_hi.arb');
      final missing = _messageKeys(en).difference(_messageKeys(hi));
      expect(
        missing,
        isEmpty,
        reason: 'hi-IN is missing ${missing.length} key(s): $missing\n'
            'Hindi is architecturally present from P0 (0004:45). A key that '
            'exists in one catalogue and not the other is the defect this '
            'test exists to catch.',
      );
    });

    test('hi-IN carries no key en-IN does not', () {
      final en = _readArb('app_en.arb');
      final hi = _readArb('app_hi.arb');
      final extra = _messageKeys(hi).difference(_messageKeys(en));
      expect(extra, isEmpty, reason: 'orphan key(s) in hi-IN: $extra');
    });

    test('no message is empty in either catalogue', () {
      final en = _readArb('app_en.arb');
      final hi = _readArb('app_hi.arb');
      for (final entry in <String, Map<String, dynamic>>{'en': en, 'hi': hi}.entries) {
        for (final key in _messageKeys(entry.value)) {
          final value = entry.value[key];
          expect(
            value is String && value.trim().isNotEmpty,
            isTrue,
            reason: '${entry.key}: "$key" is empty. An empty string is not a '
                'translation, it is a hole that renders as nothing.',
          );
        }
      }
    });

    test('every message carries a description for whoever translates it', () {
      final en = _readArb('app_en.arb');
      final undocumented = _messageKeys(en)
          .where((k) => en['@$k'] == null)
          .toList()
        ..sort();
      expect(
        undocumented,
        isEmpty,
        reason: 'no description for: $undocumented. A translator working '
            'without context guesses, and a guessed label is worse than an '
            'English one.',
      );
    });
  });

  group('locale resolution', () {
    // Precedence is the database's: app_user.locale overrides
    // business.default_locale, and en-IN is the seeded fallback.
    test('a user override wins', () {
      expect(
        resolveLocale(userLocale: 'hi-IN', businessDefaultLocale: 'en-IN'),
        const Locale('hi', 'IN'),
      );
    });

    test('the business default applies when the user has no override', () {
      expect(
        resolveLocale(businessDefaultLocale: 'hi-IN'),
        const Locale('hi', 'IN'),
      );
    });

    test('nothing set falls back to the seeded en-IN', () {
      expect(resolveLocale(), const Locale('en', 'IN'));
    });

    test('an unsupported locale falls through rather than throwing', () {
      // A bad row must not stop a counter from working.
      expect(
        resolveLocale(userLocale: 'fr-FR', businessDefaultLocale: 'hi-IN'),
        const Locale('hi', 'IN'),
      );
      expect(resolveLocale(userLocale: 'not a locale'), const Locale('en', 'IN'));
      expect(resolveLocale(userLocale: ''), const Locale('en', 'IN'));
    });

    test('a language match without the region still lands on the language', () {
      expect(resolveLocale(userLocale: 'hi'), const Locale('hi', 'IN'));
      expect(resolveLocale(userLocale: 'en-GB'), const Locale('en', 'IN'));
    });

    test('underscored tags parse, because that is how they are stored', () {
      expect(parseLocaleTag('hi_IN'), const Locale('hi', 'IN'));
    });

    test('direction is carried, and every shipped locale is ltr today', () {
      for (final locale in dhaagaSupportedLocales) {
        expect(directionFor(locale), TextDirection.ltr);
      }
      // The seam, ahead of Urdu. locale.direction exists in the schema from P0
      // so that "the layout work is a rendering concern later" (0004:27).
      expect(directionFor(const Locale('ur', 'IN')), TextDirection.rtl);
    });
  });
}
