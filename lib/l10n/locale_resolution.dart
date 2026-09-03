// Which language this session speaks.
//
// The precedence is the database's, not the client's (decision 3):
//
//   app_user.locale            per-person override   (0003_tenancy.sql:114-115)
//     -> business.default_locale                     (0003_tenancy.sql:37-39)
//       -> en-IN                                     (the seeded default)
//
// Both inputs are supplied by the caller from rows the server returned. This
// function reads nothing and decides no policy; it applies the precedence the
// schema already defines. A client-chosen language is not a concept here.

import 'package:flutter/widgets.dart';

/// The locales this build ships.
///
/// `hi-IN` is present and `is_active = false` in the seed: Hindi is
/// architecturally supported from P0 and not activated in V1 (0004:45,
/// README:92-93). Its catalogue carries every key, untranslated.
const List<Locale> dhaagaSupportedLocales = <Locale>[
  Locale('en', 'IN'),
  Locale('hi', 'IN'),
];

/// The seeded fallback. Used when neither input names a supported locale.
const Locale dhaagaFallbackLocale = Locale('en', 'IN');

/// Resolves the locale for a session.
///
/// [userLocale] is `app_user.locale` and [businessDefaultLocale] is
/// `business.default_locale`; both are the stored strings, e.g. `en-IN`, and
/// both may be null. An unrecognised or malformed value is skipped rather than
/// throwing: a bad row should not stop a counter from working.
Locale resolveLocale({
  String? userLocale,
  String? businessDefaultLocale,
  List<Locale> supported = dhaagaSupportedLocales,
}) {
  for (final candidate in <String?>[userLocale, businessDefaultLocale]) {
    final parsed = parseLocaleTag(candidate);
    if (parsed == null) continue;
    final match = _bestMatch(parsed, supported);
    if (match != null) return match;
  }
  return supported.contains(dhaagaFallbackLocale)
      ? dhaagaFallbackLocale
      : supported.first;
}

/// Parses a stored tag such as `en-IN`, `hi_IN` or `en`. Returns null for
/// anything that is not a usable language tag.
Locale? parseLocaleTag(String? tag) {
  if (tag == null) return null;
  final trimmed = tag.trim();
  if (trimmed.isEmpty) return null;

  final parts = trimmed.split(RegExp('[-_]'));
  final language = parts.first.toLowerCase();
  if (language.length < 2 || language.length > 3) return null;
  if (!RegExp(r'^[a-z]+$').hasMatch(language)) return null;

  if (parts.length == 1) return Locale(language);

  final region = parts[1].toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(region)) return Locale(language);
  return Locale(language, region);
}

/// Exact language+region first, then language alone. A stored `en-GB` should
/// land on `en-IN` rather than falling through to the business default, because
/// the language is what the reader actually needs.
Locale? _bestMatch(Locale wanted, List<Locale> supported) {
  for (final s in supported) {
    if (s.languageCode == wanted.languageCode &&
        s.countryCode == wanted.countryCode) {
      return s;
    }
  }
  for (final s in supported) {
    if (s.languageCode == wanted.languageCode) return s;
  }
  return null;
}

/// Text direction for a resolved locale.
///
/// Every supported locale is left-to-right today. This exists because
/// `locale.direction` is a column with an `ltr`/`rtl` constraint carried from
/// P0 so that "the layout work is a rendering concern later, not a schema
/// change" (0004:27-29). Urdu is not added here; the seam is, and
/// test/components/rtl_test.dart exercises it.
TextDirection directionFor(Locale locale) =>
    _rightToLeftLanguages.contains(locale.languageCode)
        ? TextDirection.rtl
        : TextDirection.ltr;

const Set<String> _rightToLeftLanguages = <String>{
  'ar', 'fa', 'he', 'ur',
};
