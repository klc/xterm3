import 'dart:math' show max, min;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';

/// Glyph sprites drawn once into an image and then stamped onto the canvas,
/// many cells to a call, tinted with each cell's colour.
///
/// The paragraph cache keys a laid-out glyph by its colour, among other
/// things, so output with many colours - a gradient, a heat map, `lolcat` -
/// misses it on most cells, and a miss is a paragraph layout, about 27 us. A
/// sprite here is keyed by the glyph and its styles only, so each glyph is
/// laid out once, whatever colours it is drawn in, and a line's sprites go to
/// the canvas in a few [Canvas.drawRawAtlas] calls - one per page, for each
/// run between cells drawn the normal way - instead of one
/// [Canvas.drawParagraph] per cell.
///
/// The glyph mask a text renderer produces depends on the colour it draws
/// in - its edge antialiasing is gamma-corrected for that colour - so a
/// sprite drawn in white and tinted dark has visibly different edges. A
/// sprite is therefore drawn in a grey of the same luminance bucket as the
/// colour it will be tinted with (the top three bits of an sRGB-encoded luma
/// byte), and the bucket is part of its key. That is what keeps the result
/// within a few levels of a directly drawn glyph: identical on plain text and
/// on themes, within 2 levels per channel on random 24-bit colour at a device
/// pixel ratio of 1 and 5-6 at 2, measured on macOS.
class GlyphAtlas {
  /// Sprites are laid out this many to a row.
  static const _columns = 64;

  /// Neither side of a page may exceed this many pixels: the smallest maximum
  /// texture size Flutter's backends are expected to support.
  static const _maxImageExtent = 8192;

  /// The most sprites kept; past it the atlas starts over. Real output uses a
  /// few hundred. Random colour and styles on every cell use about 6000, and
  /// a smaller atlas that starts over every few frames is no faster than the
  /// paragraph path; at a device pixel ratio of 2 these take some 50 MB of
  /// texture.
  static const _maxSprites = 8192;

  /// Each flush with new glyphs adds a page of them; past this many pages they
  /// are all merged into one, so that a line takes few atlas calls.
  static const _maxPages = 16;

  /// Sprite index by key, or -1 for a glyph that does not fit its cell and
  /// must be drawn the normal way.
  final _spriteByKey = <int, int>{};

  /// Glyphs waiting to be drawn into a page, with the sprite index each will
  /// have: the new glyphs of the line being painted. A glyph that is part of
  /// a shared paragraph has the shift that puts it at the origin; one with
  /// a paragraph of its own, which the atlas owns, has none.
  final _pendingIndex = <int>[];
  final _pendingParagraph = <ui.Paragraph>[];
  final _pendingShift = <Offset?>[];
  final _pendingDecorations = <ui.Paragraph?>[];

  /// Paragraphs of many glyphs, disposed of once their glyphs are drawn.
  final _sharedParagraphs = <ui.Paragraph>[];

  final _pages = <ui.Image>[];
  final _spritePage = <int>[];
  final _spriteX = <double>[];
  final _spriteY = <double>[];
  var _spriteCount = 0;

  /// Sprite cell size and padding in device pixels, the ratio they were
  /// computed for, sprites to a page row and the most sprites kept. Set by
  /// the first [add], fixed until [clear].
  var _spriteWidth = 0;
  var _spriteHeight = 0;
  var _padX = 0.0;
  var _padY = 0.0;
  var _ratio = 0.0;
  var _gridColumns = 0;
  var _capacity = 0;

  /// Sprites queued for the line being painted.
  final _queuedSprite = <int>[];
  final _queuedX = <double>[];
  final _queuedY = <double>[];
  final _queuedColor = <int>[];

  final _paint = Paint()..filterQuality = FilterQuality.none;

  static const _white = Color(0xFFFFFFFF);

  /// The luminance bucket a sprite tinted [color] is drawn in, 0-7.
  static int luminanceBucket(Color color) {
    final value = color.toARGB32();
    final luma = (((value >> 16) & 255) * 54 +
            ((value >> 8) & 255) * 183 +
            (value & 255) * 19) >>
        8;
    return luma >> 5;
  }

  /// The grey a sprite of luminance [bucket] is drawn in: the middle of the
  /// bucket.
  static Color bucketGrey(int bucket) {
    final value = bucket * 32 + 16;
    return Color.fromARGB(255, value, value, value);
  }

  /// The sprite for [key]: its index, -1 for a glyph that does not fit its
  /// cell and is drawn the normal way, or null for one not seen yet - lay it
  /// out in [bucketGrey] of the key's bucket and [add] it.
  int? sprite(int key) => _spriteByKey[key];

  /// Adds the glyph [paragraph], laid out for [key], and returns its sprite,
  /// or -1 if it does not fit [cellSize] or the atlas is full until the next
  /// line. Takes ownership of [paragraph].
  int add(
    int key,
    ui.Paragraph paragraph,
    Size cellSize,
    double devicePixelRatio,
  ) {
    final sprite = _add(
      key,
      paragraph,
      null,
      Size(paragraph.maxIntrinsicWidth, paragraph.height),
      cellSize,
      devicePixelRatio,
    );
    if (sprite < 0) paragraph.dispose();
    return sprite;
  }

  /// Hands the atlas a paragraph of many glyphs, to dispose of once the
  /// glyphs [addPart] adds from it are drawn.
  void adopt(ui.Paragraph paragraph) => _sharedParagraphs.add(paragraph);

  /// Like [add], for one glyph of an [adopt]ed [paragraph]: [shift] moves
  /// the glyph to where it would be in a paragraph of its own, and [size] is
  /// its box. The paragraph's other glyphs have to be further away than a
  /// sprite's padding: the sprite is cut out of it. [decorations], an
  /// [adopt]ed paragraph, is drawn over the glyph where a paragraph of its
  /// own starts.
  int addPart(
    int key,
    ui.Paragraph paragraph,
    Offset shift,
    Size size,
    Size cellSize,
    double devicePixelRatio, {
    ui.Paragraph? decorations,
  }) {
    _partCount++;
    final sprite =
        _add(key, paragraph, shift, size, cellSize, devicePixelRatio);
    if (sprite >= 0) {
      _pendingDecorations[_pendingDecorations.length - 1] = decorations;
    }
    return sprite;
  }

  int _add(
    int key,
    ui.Paragraph paragraph,
    Offset? shift,
    Size size,
    Size cellSize,
    double devicePixelRatio,
  ) {
    if (_spriteWidth == 0) _setGeometry(cellSize, devicePixelRatio);
    if (_capacity == 0 ||
        size.width > cellSize.width ||
        size.height > cellSize.height) {
      _spriteByKey[key] = -1;
      return -1;
    }
    if (_spriteCount >= _capacity) return -1;
    final index = _spriteCount++;
    _spriteByKey[key] = index;
    _pendingIndex.add(index);
    _pendingParagraph.add(paragraph);
    _pendingShift.add(shift);
    _pendingDecorations.add(null);
    return index;
  }

  void _disposePending() {
    for (var k = 0; k < _pendingParagraph.length; k++) {
      if (_pendingShift[k] == null) _pendingParagraph[k].dispose();
    }
    _pendingIndex.clear();
    _pendingParagraph.clear();
    _pendingShift.clear();
    _pendingDecorations.clear();
    for (final paragraph in _sharedParagraphs) {
      paragraph.dispose();
    }
    _sharedParagraphs.clear();
  }

  /// Queues [sprite] to be drawn at [offset], tinted [color], when the line
  /// is flushed.
  void queue(int sprite, Offset offset, Color color) {
    _queuedSprite.add(sprite);
    _queuedX.add(offset.dx);
    _queuedY.add(offset.dy);
    _queuedColor.add(color.toARGB32());
  }

  @visibleForTesting
  List<ui.Image> get pages => _pages;

  /// [addPart] calls since the atlas was made.
  int get partCount => _partCount;
  var _partCount = 0;

  /// How many more sprites fit before the atlas starts over.
  int get room => _spriteWidth == 0 ? _maxSprites : _capacity - _spriteCount;

  /// Keys whose glyphs are to be laid out alone, until the atlas starts over.
  final _solo = <int>{};

  void markSolo(Iterable<int> keys) => _solo.addAll(keys);

  bool isSolo(int key) => _solo.contains(key);

  /// Keys a search for company has already seen, until the atlas starts
  /// over.
  final _scanned = <int>{};

  void markScanned(int key) => _scanned.add(key);

  bool isScanned(int key) => _scanned.contains(key);

  /// Whether sprites are queued and not yet flushed.
  bool get hasQueued => _queuedSprite.isNotEmpty;

  /// Called before each line: starts over once the atlas is full, so that
  /// nothing queued refers to a page that is gone.
  void beginLine() {
    if (_spriteCount > 0 && _spriteCount >= _capacity) clear();
  }

  /// Draws the line's new glyphs into a page and every queued sprite onto
  /// [canvas].
  void flush(Canvas canvas) {
    if (_pendingIndex.isNotEmpty) _addPage();
    if (_sharedParagraphs.isNotEmpty) _disposePending();
    final count = _queuedSprite.length;
    if (count == 0) return;
    final scale = 1 / _ratio;
    for (var page = 0; page < _pages.length; page++) {
      var inPage = 0;
      for (var k = 0; k < count; k++) {
        if (_spritePage[_queuedSprite[k]] == page) inPage++;
      }
      if (inPage == 0) continue;
      final transforms = Float32List(inPage * 4);
      final rects = Float32List(inPage * 4);
      final colors = Int32List(inPage);
      var j = 0;
      for (var k = 0; k < count; k++) {
        final sprite = _queuedSprite[k];
        if (_spritePage[sprite] != page) continue;
        final x = _spriteX[sprite], y = _spriteY[sprite];
        transforms[4 * j] = scale;
        transforms[4 * j + 1] = 0;
        transforms[4 * j + 2] = _queuedX[k] - _padX;
        transforms[4 * j + 3] = _queuedY[k] - _padY;
        rects[4 * j] = x;
        rects[4 * j + 1] = y;
        rects[4 * j + 2] = x + _spriteWidth;
        rects[4 * j + 3] = y + _spriteHeight;
        colors[j] = _queuedColor[k];
        j++;
      }
      canvas.drawRawAtlas(_pages[page], transforms, rects, colors,
          BlendMode.modulate, null, _paint);
    }
    _queuedSprite.clear();
    _queuedX.clear();
    _queuedY.clear();
    _queuedColor.clear();
  }

  void _setGeometry(Size cellSize, double devicePixelRatio) {
    _ratio = devicePixelRatio;
    // Room around the cell for glyph overhang and decorations, snapped to
    // device pixels so that sprites land on the pixel grid.
    _padX = (cellSize.width / 2 * _ratio).roundToDouble() / _ratio;
    _padY = (cellSize.height / 4 * _ratio).roundToDouble() / _ratio;
    _spriteWidth = max(1, ((cellSize.width + 2 * _padX) * _ratio).round());
    _spriteHeight = max(1, ((cellSize.height + 2 * _padY) * _ratio).round());
    _gridColumns = min(_columns, _maxImageExtent ~/ _spriteWidth);
    // No sprite at all for a cell too large for a page, so that nothing
    // divides by zero columns.
    _capacity =
        min(_maxSprites, (_maxImageExtent ~/ _spriteHeight) * _gridColumns);
  }

  void _addPage() {
    if (_pages.length >= _maxPages) _mergePages();

    final count = _pendingIndex.length;
    final cols = min(_gridColumns, count);
    final rows = (count + cols - 1) ~/ cols;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Drawn in grey for the edges, then made white: the tint supplies the
    // colour.
    canvas.saveLayer(
      null,
      Paint()..colorFilter = const ColorFilter.mode(_white, BlendMode.srcIn),
    );
    canvas.scale(_ratio);
    final page = _pages.length;
    for (var k = 0; k < count; k++) {
      final sprite = _pendingIndex[k];
      final x = (k % cols) * _spriteWidth, y = (k ~/ cols) * _spriteHeight;
      final origin = Offset(x / _ratio + _padX, y / _ratio + _padY);
      final shift = _pendingShift[k];
      if (shift == null) {
        canvas.drawParagraph(_pendingParagraph[k], origin);
      } else {
        // The paragraph's other glyphs lie outside the sprite.
        canvas
          ..save()
          ..clipRect(Rect.fromLTWH(x / _ratio, y / _ratio,
              _spriteWidth / _ratio, _spriteHeight / _ratio))
          ..drawParagraph(_pendingParagraph[k], origin + shift)
          ..restore();
        final decorations = _pendingDecorations[k];
        if (decorations != null) canvas.drawParagraph(decorations, origin);
      }
      while (_spritePage.length <= sprite) {
        _spritePage.add(0);
        _spriteX.add(0);
        _spriteY.add(0);
      }
      _spritePage[sprite] = page;
      _spriteX[sprite] = x.toDouble();
      _spriteY[sprite] = y.toDouble();
    }
    canvas.restore();
    final picture = recorder.endRecording();
    _pages.add(picture.toImageSync(cols * _spriteWidth, rows * _spriteHeight));
    picture.dispose();
    _disposePending();
  }

  /// Copies every placed sprite into one image, so that a line takes one atlas
  /// call. Sprite `n` goes to cell `n` of a dense grid, so the image is never
  /// taller than [_capacity] sprites need, however small the pages were.
  void _mergePages() {
    final count = _spritePage.length;
    final cols = min(_gridColumns, count);
    final rows = (count + cols - 1) ~/ cols;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (var page = 0; page < _pages.length; page++) {
      var inPage = 0;
      for (var sprite = 0; sprite < count; sprite++) {
        if (_spritePage[sprite] == page) inPage++;
      }
      final transforms = Float32List(inPage * 4);
      final rects = Float32List(inPage * 4);
      var j = 0;
      for (var sprite = 0; sprite < count; sprite++) {
        if (_spritePage[sprite] != page) continue;
        final x = _spriteX[sprite], y = _spriteY[sprite];
        transforms[4 * j] = 1;
        transforms[4 * j + 2] = (sprite % cols) * _spriteWidth.toDouble();
        transforms[4 * j + 3] = (sprite ~/ cols) * _spriteHeight.toDouble();
        rects[4 * j] = x;
        rects[4 * j + 1] = y;
        rects[4 * j + 2] = x + _spriteWidth;
        rects[4 * j + 3] = y + _spriteHeight;
        j++;
      }
      canvas.drawRawAtlas(
          _pages[page], transforms, rects, null, null, null, _paint);
    }
    final picture = recorder.endRecording();
    final merged =
        picture.toImageSync(cols * _spriteWidth, rows * _spriteHeight);
    picture.dispose();
    for (final image in _pages) {
      image.dispose();
    }
    _pages
      ..clear()
      ..add(merged);
    for (var sprite = 0; sprite < count; sprite++) {
      _spritePage[sprite] = 0;
      _spriteX[sprite] = (sprite % cols) * _spriteWidth.toDouble();
      _spriteY[sprite] = (sprite ~/ cols) * _spriteHeight.toDouble();
    }
  }

  /// Drops every sprite and page: the font, the text scale or the device
  /// pixel ratio changed, or the atlas is full.
  void clear() {
    _spriteByKey.clear();
    _solo.clear();
    _scanned.clear();
    _disposePending();
    for (final image in _pages) {
      image.dispose();
    }
    _pages.clear();
    _spritePage.clear();
    _spriteX.clear();
    _spriteY.clear();
    _spriteCount = 0;
    _spriteWidth = 0;
    _queuedSprite.clear();
    _queuedX.clear();
    _queuedY.clear();
    _queuedColor.clear();
  }

  /// Sprites held, for tests and render statistics.
  int get spriteCount => _spriteCount;

  void dispose() => clear();
}
