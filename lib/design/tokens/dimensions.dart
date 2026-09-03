// Dhaaga design tokens · spacing, radius, elevation, breakpoints, targets
//
// A 4dp base grid. Not because 4 is magic, but because a single base means two
// components written months apart still line up, and WP-11 inherits the rhythm
// instead of re-deciding it per screen.

import 'package:flutter/widgets.dart';

abstract final class DhaagaSpacing {
  static const double base = 4;

  static const double xs = base; // 4  · inside a chip
  static const double sm = base * 2; // 8  · label to field
  static const double md = base * 3; // 12 · between fields
  static const double lg = base * 4; // 16 · section padding
  static const double xl = base * 6; // 24 · between sections
  static const double xxl = base * 8; // 32 · page margins on a large screen

  static const List<double> all = <double>[xs, sm, md, lg, xl, xxl];
}

abstract final class DhaagaRadius {
  static const Radius sm = Radius.circular(4);
  static const Radius md = Radius.circular(8);
  static const Radius lg = Radius.circular(12);
  static const Radius pill = Radius.circular(999);

  static const BorderRadius allSm = BorderRadius.all(sm);
  static const BorderRadius allMd = BorderRadius.all(md);
  static const BorderRadius allLg = BorderRadius.all(lg);
  static const BorderRadius allPill = BorderRadius.all(pill);
}

abstract final class DhaagaElevation {
  /// Flat. The default, and it should stay the default: shadow is a scarce
  /// signal and a shop-floor screen in daylight shows very little of it.
  static const double flat = 0;

  /// Something that floats over content it does not belong to.
  static const double raised = 2;

  /// Something that has taken over: a sheet, a dialog.
  static const double overlay = 8;
}

abstract final class DhaagaBreakpoints {
  /// A phone at the counter. The design target.
  static const double compact = 0;

  /// A large phone in landscape, or a small tablet.
  static const double medium = 600;

  /// A tablet or a desktop in the back office.
  static const double expanded = 1024;

  static DhaagaWidthClass classify(double width) {
    if (width >= expanded) return DhaagaWidthClass.expanded;
    if (width >= medium) return DhaagaWidthClass.medium;
    return DhaagaWidthClass.compact;
  }
}

enum DhaagaWidthClass { compact, medium, expanded }

abstract final class DhaagaTargets {
  /// WCAG 2.2 AA target size, and independently the size of a thumb on a
  /// counter. Every interactive primitive enforces this as a minimum, which
  /// test/components/ checks rather than trusts.
  static const double minimumTouch = 48;

  /// Focus indicator thickness. Paired with the 3:1 `focus` token so the ring
  /// is perceivable rather than merely present.
  static const double focusRingWidth = 2;

  /// Control boundary thickness.
  static const double borderWidth = 1;

  /// The largest text scale every component must survive intact.
  static const double maximumTextScale = 2.0;
}
