// Dhaaga — application entry point.
//
// WP-9 delivers the client foundation, not the application. There are no
// business screens yet: "There are no screens; the rules are in the database
// and WP-11 onward will call them" (ADR-0012:209). So the only thing there is
// to run today is the component gallery, and running it is honest — it is the
// artefact WP-9 is accepted against.
//
// This file deliberately contains no user-visible string. The window title
// comes from the catalogue, resolved inside the widget tree where a
// Localizations ancestor exists. When WP-11 arrives it replaces the home
// widget; nothing else here should need to change.

import 'package:flutter/widgets.dart';

import 'gallery/gallery_app.dart';

void main() {
  runApp(const DhaagaGalleryApp());
}
