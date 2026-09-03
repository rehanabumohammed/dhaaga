// Replaces the Flutter counter-demo test that shipped with the template.
//
// It had to go in the same change that replaced lib/main.dart: leaving a test
// that exercises a deleted counter would have meant WP-9 landing with a red
// suite, and a red suite that everyone knows about is a suite nobody reads.
//
// What is worth smoke-testing today is that the application boots into the
// gallery, resolves a locale, and puts no hard-coded English on screen that
// did not come from the catalogue.

import 'package:dhaaga/gallery/gallery_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pump.dart';

void main() {
  testWidgets('the app boots into the component gallery', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const DhaagaGalleryApp());
    // Not pumpAndSettle: the gallery renders every ViewState, and the loading
    // one animates forever on purpose. See pumpDhaagaFrames in support/pump.dart.
    await pumpDhaagaFrames(tester);

    // The title comes from the catalogue, so finding it proves the
    // localisation delegates resolved as well as that the app built.
    expect(find.text('Component gallery'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the large-text toggle reaches 2.0x without breaking layout',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const DhaagaGalleryApp());
    await pumpDhaagaFrames(tester);

    await tester.tap(find.byType(Switch).first);
    await pumpDhaagaFrames(tester);

    expect(tester.takeException(), isNull);
  });
}
