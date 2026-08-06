import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm3/src/ui/paragraph_cache.dart';
import 'package:xterm3/src/ui/render_stats.dart';

void main() {
  setUp(TerminalRenderStats.reset);
  tearDown(TerminalRenderStats.reset);

  test('reset zeroes every counter', () {
    TerminalRenderStats.paints = 3;
    TerminalRenderStats.paintedLines = 90;
    TerminalRenderStats.paragraphCacheHits = 5;
    TerminalRenderStats.paragraphCacheMisses = 1;
    TerminalRenderStats.glyphCacheHits = 2;
    TerminalRenderStats.glyphCacheMisses = 4;

    TerminalRenderStats.reset();

    expect(TerminalRenderStats.paints, 0);
    expect(TerminalRenderStats.paintedLines, 0);
    expect(TerminalRenderStats.paragraphCacheHits, 0);
    expect(TerminalRenderStats.paragraphCacheMisses, 0);
    expect(TerminalRenderStats.glyphCacheHits, 0);
    expect(TerminalRenderStats.glyphCacheMisses, 0);
  });

  test('derived ratios are null until something has been measured', () {
    expect(TerminalRenderStats.paragraphCacheHitRatio, isNull);
    expect(TerminalRenderStats.glyphCacheHitRatio, isNull);
    expect(TerminalRenderStats.linesPerPaint, isNull);
  });

  test('derived ratios divide by the totals they describe', () {
    TerminalRenderStats.paragraphCacheHits = 3;
    TerminalRenderStats.paragraphCacheMisses = 1;
    TerminalRenderStats.glyphCacheHits = 1;
    TerminalRenderStats.glyphCacheMisses = 3;
    TerminalRenderStats.paints = 4;
    TerminalRenderStats.paintedLines = 100;

    expect(TerminalRenderStats.paragraphCacheHitRatio, 0.75);
    expect(TerminalRenderStats.glyphCacheHitRatio, 0.25);
    expect(TerminalRenderStats.linesPerPaint, 25);
  });

  test('ParagraphCache lookups are counted as hits and misses', () {
    final cache = ParagraphCache(8);
    const style = TextStyle();

    expect(cache.getLayoutFromCache(1), isNull);
    expect(TerminalRenderStats.paragraphCacheMisses, 1);
    expect(TerminalRenderStats.paragraphCacheHits, 0);

    cache.performAndCacheLayout('a', style, TextScaler.noScaling, 1);
    expect(cache.getLayoutFromCache(1), isNotNull);
    expect(TerminalRenderStats.paragraphCacheHits, 1);
    expect(TerminalRenderStats.paragraphCacheMisses, 1);

    cache.dispose();
  });
}
