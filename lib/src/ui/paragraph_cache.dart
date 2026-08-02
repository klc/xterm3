import 'dart:ui';

import 'package:flutter/widgets.dart';

/// A cache of laid out [Paragraph]s. This is used to avoid laying out the same
/// text multiple times, which is expensive.
class ParagraphCache {
  ParagraphCache(this.maximumSize) {
    if (maximumSize <= 0) {
      throw ArgumentError.value(maximumSize, 'maximumSize');
    }
  }

  final int maximumSize;

  final _cache = <Object, _CachedParagraph>{};

  /// Monotonic counter used to order entries by recency of use. Reading an
  /// entry only bumps this counter and writes it into the entry, so cache hits
  /// never mutate [_cache] itself.
  var _clock = 0;

  /// Number of entries dropped in one eviction pass. Evicting in batches keeps
  /// the amortized cost of the linear recency scan at O(1) per insertion.
  int get _evictionBatchSize {
    final batchSize = maximumSize >> 4;
    return batchSize < 1 ? 1 : batchSize;
  }

  /// Returns a [Paragraph] for the given [key]. [key] is the same as the
  /// key argument to [performAndCacheLayout].
  Paragraph? getLayoutFromCache(Object key) {
    final entry = _cache[key];
    if (entry == null) return null;
    entry.lastUsed = ++_clock;
    return entry.paragraph;
  }

  /// Applies [style] and [textScaler] to [text] and lays it out to create
  /// a [Paragraph]. The [Paragraph] is cached and can be retrieved with the
  /// same [key] by calling [getLayoutFromCache].
  Paragraph performAndCacheLayout(
    String text,
    TextStyle style,
    TextScaler textScaler,
    Object key,
  ) {
    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.pushStyle(style.getTextStyle(textScaler: textScaler));
    builder.addText(text);

    final paragraph = builder.build();
    paragraph.layout(ParagraphConstraints(width: double.infinity));

    _cache.remove(key)?.paragraph.dispose();
    if (_cache.length >= maximumSize) {
      _evictLeastRecentlyUsed();
    }
    _cache[key] = _CachedParagraph(paragraph, ++_clock);
    return paragraph;
  }

  void _evictLeastRecentlyUsed() {
    final batchSize = _evictionBatchSize;
    final count = batchSize > _cache.length ? _cache.length : batchSize;
    if (count <= 0) return;

    final entries = _cache.entries.toList(growable: false)
      ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));
    for (var i = 0; i < count; i++) {
      _cache.remove(entries[i].key)?.paragraph.dispose();
    }
  }

  /// Clears the cache. This should be called when the same text and style
  /// pair no longer produces the same layout. For example, when a font is
  /// loaded.
  void clear() {
    for (final entry in _cache.values) {
      entry.paragraph.dispose();
    }
    _cache.clear();
  }

  void dispose() {
    clear();
  }

  /// Returns the number of [Paragraph]s in the cache.
  int get length {
    return _cache.length;
  }
}

class _CachedParagraph {
  _CachedParagraph(this.paragraph, this.lastUsed);

  final Paragraph paragraph;

  int lastUsed;
}
