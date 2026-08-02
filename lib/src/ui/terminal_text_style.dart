import 'package:flutter/widgets.dart';

const _kDefaultFontSize = 13.0;

const _kDefaultHeight = 1.2;

const _kDefaultFontFamily = 'monospace';

const _kDefaultFontFamilyFallback = [
  'SF Mono',
  'Menlo',
  'Monaco',
  'Cascadia Mono',
  'Consolas',
  'Liberation Mono',
  'DejaVu Sans Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'Apple Color Emoji',
  'Segoe UI Emoji',
  'Noto Color Emoji',
  'Segoe UI Symbol',
  'Symbols Nerd Font Mono',
  'Symbols Nerd Font',
  'Noto Sans Symbols 2',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];

const _kTerminalFontFeatures = [
  FontFeature.disable('calt'),
  FontFeature.disable('clig'),
  FontFeature.disable('dlig'),
  FontFeature.disable('hlig'),
  FontFeature.disable('kern'),
  FontFeature.disable('liga'),
];

/// Feature set used when [TerminalStyle.enableLigatures] is set.
///
/// Only the features that merge glyphs while preserving the total advance are
/// turned on. `calt` carries most programming ligatures in fonts such as Fira
/// Code, which route them through contextual alternates rather than `liga`.
/// `kern` stays disabled in both modes because kerning shifts advances without
/// merging anything, which only misaligns the cell grid. `dlig` and `hlig` are
/// discretionary and historical ligatures, neither of which a terminal wants.
const _kTerminalLigatureFontFeatures = [
  FontFeature.enable('calt'),
  FontFeature.enable('clig'),
  FontFeature.disable('dlig'),
  FontFeature.disable('hlig'),
  FontFeature.disable('kern'),
  FontFeature.enable('liga'),
];

class TerminalStyle {
  const TerminalStyle({
    this.fontSize = _kDefaultFontSize,
    this.height = _kDefaultHeight,
    this.fontFamily = _kDefaultFontFamily,
    this.fontFamilyFallback = _kDefaultFontFamilyFallback,
    this.drawBoldTextWithBrightColors = true,
    this.enableLigatures = false,
  });

  factory TerminalStyle.fromTextStyle(TextStyle textStyle) {
    return TerminalStyle(
      fontSize: textStyle.fontSize ?? _kDefaultFontSize,
      height: textStyle.height ?? _kDefaultHeight,
      fontFamily: textStyle.fontFamily ??
          textStyle.fontFamilyFallback?.first ??
          _kDefaultFontFamily,
      fontFamilyFallback:
          textStyle.fontFamilyFallback ?? _kDefaultFontFamilyFallback,
      drawBoldTextWithBrightColors: true,
      enableLigatures: _requestsLigatures(textStyle.fontFeatures),
    );
  }

  static bool _requestsLigatures(List<FontFeature>? features) {
    if (features == null) return false;
    for (final feature in features) {
      if (feature.value == 0) continue;
      switch (feature.feature) {
        case 'calt':
        case 'clig':
        case 'liga':
          return true;
      }
    }
    return false;
  }

  final double fontSize;

  final double height;

  final String fontFamily;

  final List<String> fontFamilyFallback;

  final bool drawBoldTextWithBrightColors;

  /// Whether glyph-merging font features are enabled.
  ///
  /// This only permits the font to produce ligature glyphs; the painter still
  /// decides where merging is safe. A ligature is drawn only when its advance
  /// matches the cells it covers, so the cell grid never shifts. Enabling this
  /// has no visible effect unless the resolved font actually ships the
  /// features, which none of the default fallback families do.
  final bool enableLigatures;

  TextStyle toTextStyle({
    Color? color,
    Color? backgroundColor,
    Color? decorationColor,
    bool bold = false,
    bool italic = false,
    bool underline = false,
    bool doubleUnderline = false,
    TextDecorationStyle decorationStyle = TextDecorationStyle.solid,
    bool strikethrough = false,
    bool overline = false,
  }) {
    final decorations = [
      if (underline || doubleUnderline) TextDecoration.underline,
      if (strikethrough) TextDecoration.lineThrough,
      if (overline) TextDecoration.overline,
    ];
    final decoration = switch (decorations.isEmpty) {
      true => TextDecoration.none,
      false => TextDecoration.combine(decorations),
    };
    final effectiveDecorationStyle = switch (doubleUnderline) {
      true => TextDecorationStyle.double,
      false => decorationStyle,
    };

    return TextStyle(
      fontSize: fontSize,
      height: height,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      color: color,
      backgroundColor: backgroundColor,
      fontWeight: switch (bold) {
        true => FontWeight.bold,
        false => FontWeight.normal,
      },
      fontStyle: switch (italic) {
        true => FontStyle.italic,
        false => FontStyle.normal,
      },
      decoration: decoration,
      decorationStyle: effectiveDecorationStyle,
      decorationColor: decorationColor,
      fontFeatures: switch (enableLigatures) {
        true => _kTerminalLigatureFontFeatures,
        false => _kTerminalFontFeatures,
      },
    );
  }

  TerminalStyle copyWith({
    double? fontSize,
    double? height,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    bool? drawBoldTextWithBrightColors,
    bool? enableLigatures,
  }) {
    return TerminalStyle(
      fontSize: fontSize ?? this.fontSize,
      height: height ?? this.height,
      fontFamily: fontFamily ?? this.fontFamily,
      fontFamilyFallback: fontFamilyFallback ?? this.fontFamilyFallback,
      drawBoldTextWithBrightColors:
          drawBoldTextWithBrightColors ?? this.drawBoldTextWithBrightColors,
      enableLigatures: enableLigatures ?? this.enableLigatures,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TerminalStyle) return false;
    if (fontSize != other.fontSize ||
        height != other.height ||
        fontFamily != other.fontFamily ||
        drawBoldTextWithBrightColors != other.drawBoldTextWithBrightColors ||
        enableLigatures != other.enableLigatures ||
        fontFamilyFallback.length != other.fontFamilyFallback.length) {
      return false;
    }
    for (var index = 0; index < fontFamilyFallback.length; index++) {
      if (fontFamilyFallback[index] != other.fontFamilyFallback[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        fontSize,
        height,
        fontFamily,
        drawBoldTextWithBrightColors,
        enableLigatures,
        Object.hashAll(fontFamilyFallback),
      );
}
