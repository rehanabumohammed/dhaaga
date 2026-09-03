// Dhaaga theme.
//
// Assembled entirely from tokens. There is no colour, size or spacing literal
// in this file and there must not be one: the tokens are the contract, and a
// literal here would be invisible to the contrast test.
//
// One theme ships in WP-9 (ADR-0017). The shape is built so a second is a new
// DhaagaColors instance handed to `dhaagaTheme` — not a refactor.

import 'package:flutter/material.dart';

import 'tokens/dimensions.dart';
import 'tokens/palette.dart';
import 'tokens/typography.dart';

/// Semantic tokens reachable from a BuildContext.
///
/// Components read colours through `DhaagaTheme.of(context)` rather than
/// importing [DhaagaColors] directly, so that a second theme is picked up
/// without touching a component.
class DhaagaTheme extends InheritedWidget {
  const DhaagaTheme({
    required this.colors,
    required super.child,
    super.key,
  });

  final DhaagaColors colors;

  static DhaagaColors of(BuildContext context) {
    final inherited =
        context.dependOnInheritedWidgetOfExactType<DhaagaTheme>();
    // Falling back rather than throwing keeps a golden test or a widget
    // preview usable without a wrapper, and light is the only theme WP-9 ships.
    return inherited?.colors ?? DhaagaColors.light;
  }

  @override
  bool updateShouldNotify(DhaagaTheme oldWidget) => colors != oldWidget.colors;
}

/// Material theme built from the token set. Material components are themed
/// here; WP-9 does not rebuild them.
ThemeData dhaagaTheme(DhaagaColors c) {
  final textTheme = TextTheme(
    titleLarge: DhaagaTypography.titleLarge.copyWith(color: c.onSurface),
    titleMedium: DhaagaTypography.titleMedium.copyWith(color: c.onSurface),
    bodyLarge: DhaagaTypography.body.copyWith(color: c.onSurface),
    bodyMedium: DhaagaTypography.body.copyWith(color: c.onSurface),
    labelLarge: DhaagaTypography.label.copyWith(color: c.onSurface),
    bodySmall: DhaagaTypography.caption.copyWith(color: c.onSurfaceMuted),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: c.surface,
    canvasColor: c.surface,
    colorScheme: ColorScheme(
      brightness: Brightness.light,
      primary: c.primary,
      onPrimary: c.onPrimary,
      secondary: c.primary,
      onSecondary: c.onPrimary,
      error: c.danger,
      onError: c.onDanger,
      surface: c.surface,
      onSurface: c.onSurface,
      surfaceContainerHighest: c.surfaceMuted,
      outline: c.border,
      outlineVariant: c.borderSubtle,
    ),
    textTheme: textTheme,
    dividerTheme: DividerThemeData(
      color: c.borderSubtle,
      thickness: DhaagaTargets.borderWidth,
      space: DhaagaSpacing.lg,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll<Size>(
          Size(DhaagaTargets.minimumTouch, DhaagaTargets.minimumTouch),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.pressed) ? c.primaryPressed : c.primary),
        foregroundColor: WidgetStatePropertyAll<Color>(c.onPrimary),
        textStyle: WidgetStatePropertyAll<TextStyle>(DhaagaTypography.bodyStrong),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: DhaagaRadius.allMd),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll<Size>(
          Size(DhaagaTargets.minimumTouch, DhaagaTargets.minimumTouch),
        ),
        foregroundColor: WidgetStatePropertyAll<Color>(c.primary),
        side: WidgetStatePropertyAll<BorderSide>(
          BorderSide(color: c.border, width: DhaagaTargets.borderWidth),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle>(DhaagaTypography.bodyStrong),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: DhaagaRadius.allMd),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceMuted,
      labelStyle: DhaagaTypography.label.copyWith(color: c.onSurfaceMuted),
      helperStyle: DhaagaTypography.caption.copyWith(color: c.onSurfaceMuted),
      errorStyle: DhaagaTypography.caption.copyWith(color: c.danger),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: DhaagaSpacing.md,
        vertical: DhaagaSpacing.md,
      ),
      border: OutlineInputBorder(
        borderRadius: DhaagaRadius.allMd,
        borderSide: BorderSide(color: c.border, width: DhaagaTargets.borderWidth),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: DhaagaRadius.allMd,
        borderSide: BorderSide(color: c.border, width: DhaagaTargets.borderWidth),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: DhaagaRadius.allMd,
        borderSide:
            BorderSide(color: c.focus, width: DhaagaTargets.focusRingWidth),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: DhaagaRadius.allMd,
        borderSide: BorderSide(color: c.danger, width: DhaagaTargets.borderWidth),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: DhaagaRadius.allMd,
        borderSide:
            BorderSide(color: c.danger, width: DhaagaTargets.focusRingWidth),
      ),
    ),
  );
}
