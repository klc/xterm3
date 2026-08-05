## Unreleased

* Roughly double the throughput of non-ASCII text. Grapheme cluster detection had a
  fast path only for the case where both the previous cell and the incoming code
  point are ASCII, so a single accented letter — `ö` in Turkish, any Latin-1 word —
  dropped every following character into full grapheme segmentation, at two string
  allocations and two segmentation passes each. Nothing below U+0300 can continue a
  cluster, so that is now the cut, and `writeChar` skips both cluster checks for such
  code points. Measured with `bin/parse_bench.dart`: 15 MiB/s to 32 MiB/s on Turkish
  text, against a 35 MiB/s ceiling with grapheme clustering disabled entirely.
* Add `bin/parse_bench.dart`, which measures write-path throughput with no Flutter and
  no renderer, separating the parser from the buffer writes it drives.
* Stop the procedural glyph cache from making large terminals slower than no cache
  at all. Its keys are (codepoint, cell size, colour), so a screen drawing box lines
  in many colours can reference thousands of distinct keys, and at the old 512-entry
  capacity a full-screen grid thrashed it — a miss pays for the recording and the
  insert on top of the drawing, so the cache cost 1.9ms of UI time per frame *over*
  painting uncached. Capacity is now 4096. Block elements (`U+2580..U+259F`), which
  are one or two `drawRect` calls, now bypass the cache entirely: replaying a
  recorded picture per cell put a picture boundary in the raster command stream for
  every cell and cost 0.4ms of raster per frame at a 100% hit rate, for no saving on
  the UI thread.
* Fix wide characters corrupting the cell grid. `BufferLine.setCell` now repairs the
  width-2 lead / width-0 placeholder pairing itself, so no caller can leave half a
  wide character behind — a filler cell written when a wide character does not fit
  before the right margin used to overwrite an existing placeholder in place, and
  growing a previously shrunk line could resurrect a stale lead whose placeholder was
  cut off. Found by the new parser fuzz harness.
* Defer soft-keyboard input while an IME composition is open, in both `deleteDetection`
  modes, so Turkish and CJK text reaches the terminal only once the keyboard commits it.
  Previously an uncorrected preview (`gg` before `ğıİşçöü`, `ni` before `nihao`) was
  written to the terminal as literal text. Composition is now tracked by composing-range
  identity rather than length, which keeps single keypresses that Android keyboards wrap
  in a never-collapsing composing range landing exactly once.
* Recognise a backspace at offset 0 as a delete when `deleteDetection` is off. It
  previously produced an empty insert and no delete ever reached the terminal.
* Add an opt-in `Terminal.onUnknownSequence` diagnostic callback, reporting ESC, CSI, OSC
  and DCS sequences the parser does not recognise. It costs nothing when unset, and
  deliberately stays silent for sequences that are handled internally.
* **Behavior change:** `Observable.listeners` is now an `Iterable<void Function()>`
  view instead of a `Set<void Function()>`. Iterating, `length` and `contains`
  keep working; code that mutated the set directly must call `addListener` and
  `removeListener` instead. The backing storage is now an append-only list with
  tombstoned removals, so `notifyListeners` no longer allocates a defensive copy
  on every notification — it ran once per `Terminal.write`.
* Cache rasterised procedural glyphs (box drawing, block elements, Powerline,
  Braille) as `ui.Picture` keyed on code point, cell size and colour. They were
  re-tesselated as vector paths on every repaint, including on a static screen.
* Replace the paragraph cache's O(n log n) eviction with a lazily repaired
  binary min-heap. Eviction previously copied and sorted every entry once per
  batch; the cache-hit path stays allocation-free and untouched.
* Prune OSC 8 hyperlink URIs when scrollback lines are evicted, instead of only
  when the registry hits its ceiling. Eviction scans are batched so hyperlink
  heavy output does not pay a full buffer scan per evicted line.
* Assert that `Terminal.write` is not re-entered. Re-entering it from a listener
  or an `onOutput`/`onBell`/`onTitleChange` callback corrupts parser state.
* **Deprecated:** `EscapeHandler.unkownEscape` is superseded by the correctly
  spelled `unknownEscape`. The old name still works and forwards to the new one;
  it will be removed in the next major.
* **Deprecated:** `CellData.getHash` is unused inside the package and will be
  removed in the next major.
* `BufferLine.data` is deprecated and marked `@visibleForTesting`; it exposed raw
  cell storage for mutation. `BufferLine.anchors` now returns an unmodifiable
  live view.
* Add a seeded parser fuzz harness and assert real invariants in the stress test,
  which previously only checked that nothing threw. Two pre-existing bugs the
  harness uncovered — a `RangeError` in resize reflow and a wide character left
  in a line's last column without room for its placeholder — are recorded as
  skipped regression tests pending a fix.
* **Behavior change:** `TerminalController` now defaults to `PointerInputs.all()`,
  so pointer motion and drag events reach the terminal. Applications that enable
  DEC private modes 1002 (button-event tracking) and 1003 (any-event tracking)
  now receive mouse reports out of the box, matching xterm, iTerm2 and Kitty.
  Reports are still gated on the mouse mode the application requests, so a
  terminal with mouse reporting disabled emits nothing. To restore the previous
  default, pass
  `TerminalController(pointerInputs: PointerInputs({PointerInput.tap, PointerInput.scroll}))`.
* Render font ligatures when `TerminalStyle.enableLigatures` is set, keeping
  the cell grid intact by falling back to per-cell painting whenever a shaped
  run would not fill exactly the cells it covers. Requires a font that ships
  ligatures, such as Fira Code, JetBrains Mono or Iosevka.

## [5.3.0] - 2026-07-28

* Render bounded search matches with a distinct active result.
* Auto-scroll scrollback while extending a selection beyond the viewport.
* Add Shift+Home/End/PageUp/PageDown scrollback navigation.
* Track primary OSC 133/633 prompts across scrollback and reflow.
* Navigate semantic prompts with native platform shortcuts.
* Correct modified arrow-key sequences across main and alternate screens.
* Encode modified F1–F4 keys with xterm-compatible CSI sequences.
* Preserve Shift+wheel scrollback while applications report mouse input.
* Report horizontal wheel gestures and simulate them in alternate screens.
* Keep application scrolling active when Flutter replaces its scroll position.
* Preserve active and saved cursor positions through resize reflow.
* Leave double- and triple-click handling to applications using mouse tracking.
* Complete application mouse drags with release events without host selection.
* Report mouse buttons immediately without gesture-recognizer delays.
* Report back and forward mouse buttons through extended mouse protocols.
* Ignore unsupported highlight tracking without disrupting active mouse input.
* Respond to legacy DECID terminal identification requests.
* Report the current xterm2 version to terminal applications.
* Preserve complete semicolon-rich OSC titles, paths, and cursor names.
* Render the British national replacement character set.
* Render text decorations consistently across blank cells.
* Ignore orphaned zero-width marks instead of altering existing cells.
* Preserve combining marks after changing grapheme-cluster mode.
* Let wide symbol glyphs use adjacent blank cells instead of clipping.
* Keep IME composition text on the active row near the right edge.
* Preserve Ctrl+A and Ctrl+V input with standard terminal clipboard shortcuts.
* Preserve AltGr-composed text on Windows and Linux keyboards.
* Encode modified Enter keys distinctly for modern interactive CLIs.
* Preserve distinct Ctrl+Shift letter chords with fixterms encoding.
* Add standard Ctrl+Insert copy and Shift+Insert paste shortcuts.
* Correct Ctrl+Alt+Backspace and DEC backarrow modifier handling.
* Encode modified Escape keys distinctly for interactive applications.
* Preserve legacy Ctrl+number-row control chords.
* Bound streaming clipboard capture memory and recover after overflow.
* Reduce allocation overhead for non-ASCII terminal output.
* Avoid duplicate Unicode width lookups while processing terminal output.
* Preserve supplementary Unicode glyphs split across output chunks.
* Reduce memory overhead when sanitizing unsafe paste payloads.
* Release consumed terminal input buffers without waiting for more output.
* Ignore unsupported control bytes instead of rendering them as glyphs.
* Harden hyperlink hit testing during concurrent resize and reflow.
* Update hovered OSC 8 links immediately when the platform modifier changes.

## [5.2.0] - 2026-07-25

* Harden resize behavior for synchronized output, tab stops, and size reports.
* Reduce parser, allocation, and cell-copy overhead during dense TUI output.
* Allocate scrollback cell metadata lazily to reduce idle memory use.
* Match modern terminal handling for Alt-modified text input.
* Expose complete OSC 3008 hierarchical context metadata.
* Add bounded Unicode-aware scrollback search across soft wraps.

## [5.1.0] - 2026-07-19

* Add Unicode 17 width handling and broader emoji grapheme support.
* Add Kitty keyboard modifiers and expanded VT/xterm protocol compatibility.
* Improve OSC 8 hyperlinks, selection isolation, clear behavior, and inline TUI scrolling.
* Expand procedural rendering for box drawing, blocks, mosaics, branch graphs, and legacy symbols.
* Improve glyph fallback, wide-character rendering, contrast, and decoration accuracy.
* Reduce parser, resize, repaint, and paragraph-cache overhead under sustained output.
* Harden resize reflow and buffer editing across wrapped and wide lines.

## [5.0.0] - 2026-07-11

* Rename package to `xterm2` for the maintained fork.
* Support DEC synchronized updates with Alacritty-compatible timeout recovery.
* Report terminal view focus changes for DEC focus tracking mode.
* Render application-selected DECSCUSR cursor shapes.
* Animate blinking cursors with Alacritty-compatible interval and timeout.
* Bound OSC payload memory and safely discard oversized fragmented sequences.
* Bound CSI payload and parameter memory across fragmented sequences.
* Expose authoritative current-directory updates from OSC 7.
* Parse, render, hit-test, and activate bounded OSC 8 hyperlinks.
* Render common block and box-drawing glyphs procedurally without font seams.
* Reuse cell paints to reduce per-frame rendering allocations.
* Keep the full viewport available when `maxLines` is smaller than its height.
* Improve terminal glyph rendering, prompt symbols, OSC hyperlinks, cursor visibility, and scroll behavior.

## [4.0.0] - 2024-02-27
* Update for Flutter 3.19 [#190]. Thanks [@domesticmouse].
* Fix designate charset logic [#186]. Thanks [@djnalluri].

## [3.6.1-pre] - 2023-04-28
* Add Termianl.onPrivateOSC callback
* Copy shortcut on Windows default to Ctrl+Shift+V (#173)

## [3.6.0-pre] - 2023-04-27
* Basic ZMODEM support

## [3.5.0] - 2023-04-20
* Support customizing word separators for selection [#160]. Thanks [@itzhoujun].
* Fix incorrect tab stop handling [#161]. Thanks [@itzhoujun].
* Added support for Ctrl+Home, Ctrl+End etc [#169]. Thanks [@nuc134r].

## [3.4.1] - 2023-01-27
* Fix Flutter 3.7 incompatibilities [#151], thanks [@jpnurmi].

## [3.4.0] - 2022-11-4
* Mouse input is enabled by default.
* Support scrolling in alternate buffer.
* Fix `deleteLines` behavior.
* Fix `eraseDisplayFromCursor` removes characters before the cursor.

## [3.3.0] - 2022-10-30
* Sync ShortcutManager's shortcuts in didUpdateWidget [#140], thanks [@jpnurmi].
* fix: terminal font size not respecting system level font scale [#138], thanks [@LucasAschenbach].
* Fix selection color [#135], thanks [@jpnurmi].
* fix: dispose controllers of TerminalView [#132], thanks [@tauu].
* feat: add hardwareKeyboardOnly flag to TerminalView [#131], thanks [@tauu].
* feat: initial mouse support [#130], thanks [@tauu].
* feat: limited window manipulation support [#129], thanks [@tauu].
* fix: workaround to draw underlined spaces [#128], thanks [@tauu].
* feat: block selection [#127], thanks [@tauu].
* feat: enable changing the inputHandler of a terminal [#126], thanks [@tauu].
* fix: export TerminalTargetPlatform [#125], thanks [@tauu].
* fix: only dispose the FocusNodes which TerminalView creates [#124], thanks [@tauu].
* feat: expose readOnly flag of CustomTextEdit in TerminalView [#123], thanks [@tauu].
* fix: supports numpad enter key [#137].
* feat: expose `reflowEnabled` flag [#104].
* docs: add virtual keyboard example [#141].

## [3.2.7] - 2022-9-13
* Fix lint issues.

## [3.2.6] - 2022-9-13
* First stable release of xterm.dart v3.

## [3.2.6-alpha] - 2022-9-13
* Fix new line width in reflow.

## [3.2.5-alpha] - 2022-9-12
* Fix intent related issue.

## [3.2.4-alpha] - 2022-9-12
* Use flutter native shortcut intents.

## [3.2.3-alpha] - 2022-9-12
* Export shortcut related classes.

## [3.2.2-alpha] - 2022-9-12
* Implement default keyboard shortcuts.

## [3.2.1-alpha] - 2022-9-12
* Disable optional line scroll mode that is under development.

## [3.2.0-alpha] - 2022-9-12
* Enhanced selection handing.
* More tests.

## [3.1.0-alpha] - 2022-9-4
* Update dependencies & merge into master

## [3.0.6-alpha] - 2022-4-4
* Export `TerminalViewState`
* Added `onTap` callback to `TerminalView`

## [3.0.5-alpha] - 2022-4-4
* Avoid resize when `RenderBox.size` is zero.
* Added `charInput` and `textInput`method.
* Added `requestKeyboard`, `closeKeyboard` and `hasInputConnection`method.
* Export `KeyboardVisibilty`

## [3.0.4-alpha] - 2022-4-1
* Improved text editing
* Added composing state painting
* Adapt to `MediaQuery.padding`

## [3.0.3-alpha] - 2022-3-28
* Improved scroll handing
* Improved resize handing
* Fix focus repaint
* Fix OSC title update

## [3.0.2-alpha] - 2022-3-28
* Re-design `KeyboardVisibilty`

## [3.0.1-alpha] - 2022-3-27
* Add `KeyboardVisibilty`

## [3.0.0-alpha] - 2022-3-26
* Initial release of v3.

## [2.6.0] - 2021-12-28
* Add scrollBehavior field to the TerminalView class [#55].
* Feature: Search [#60]. Thanks [@devmil].
* Fixes for occasional unintended multi character input [#61]. Thanks [@devmil].
* Fixes ALT + L for a Mac (German Layout) [#62]. Thanks [@devmil].
* Fixes example build problem of flutter-windows for new version of flutter [#63]. Thanks [@linhanyu].
* Fixes inverse color text (when background == 0) [#66]. Thanks [@devmil].
* Fixes assert of scrollController.position [#67]. Thanks [@linhanyu].
* Change interface of ssh.dart example to satisfied new dartssh [#69]. Thanks [@linhanyu].
* add configuration options for keyboard [#74]. Thanks [@jda258].
* Adds check if the TerminalIsolate has already been started  [#77]. Thanks [@devmil].

## [2.5.0-pre] - 2021-8-4
* Support select word / whole row via double tap [#40]. Thanks [@devmil].
* Adds "selectAll" to TerminalUiInteraction [#43]. Thanks [@devmil].
* Fixes sgr processing [#44],[#45]. Thanks [@devmil].
* Adds blinking Cursor support [#46]. Thanks [@devmil].
* Fixes Zoom adaptions on non active buffer [#47]. Thanks [@devmil].
* Adds Padding option to TerminalView  [#48]. Thanks [@devmil].
* Removes no longer supported LogicalKeyboardKey  [#49]. Thanks [@devmil].
* Adds the composing state [#50]. Thanks [@devmil].
* Fix scroll problem in mobile device [#51]. Thanks [@linhanyu].

## [2.4.0-pre] - 2021-6-13
* Update the signature of TerminalBackend.resize() to also receive dimensions in
 pixels[(#39)](https://github.com/TerminalStudio/xterm.dart/pull/39). Thanks [@michaellee8](https://github.com/michaellee8).

## [2.3.1-pre] - 2021-6-1
* Export `theme/terminal_style.dart`

## [2.3.0-pre] - 2021-6-1
* Add `import 'package:xterm/isolate.dart';`

## [2.2.1-pre] - 2021-6-1
* Make BufferLine work on web.

## [2.2.0-pre] - 2021-4-12

## [2.1.0-pre] - 2021-3-20
* Better support for resizing and scrolling.
* Reflow support (in progress [#13](https://github.com/TerminalStudio/xterm.dart/pull/13)), thanks [@devmil](https://github.com/devmil).

## [2.0.0] - 2021-3-7
* Clean up for release

## [2.0.0-pre] - 2021-3-7
* Migrate to nnbd

## [1.3.0] - 2021-2-24
* Performance improvement.

## [1.2.0] - 2021-2-15

* Pass TerminalView's autofocus to the InputListener that it creates. [#10](https://github.com/TerminalStudio/xterm.dart/pull/10), thanks [@timburks](https://github.com/timburks)

## [1.2.0-pre] - 2021-1-20

* add the ability to use fonts from the google_fonts package [#9](https://github.com/TerminalStudio/xterm.dart/pull/9)

## [1.1.1+1] - 2020-10-4

* Update readme


## [1.1.1] - 2020-10-4

* Add brightWhite to TerminalTheme

## [1.1.0] - 2020-9-29

* Fix web support.

## [1.0.2] - 2020-9-29

* Update link.

## [1.0.1] - 2020-9-29

* Disable debug print.

## [1.0.0] - 2020-9-28

* Update readme.

## [1.0.0-dev] - 2020-9-28

* Major issues are fixed.

## [0.1.0] - 2020-8-9

* Bug fixes

## [0.0.4] - 2020-8-1

* Revert version constrain

## [0.0.3] - 2020-8-1

* Update version constrain


## [0.0.2] - 2020-8-1

* Update readme


## [0.0.1] - 2020-8-1

* First version


[@devmil]: https://github.com/devmil
[@michaellee8]: https://github.com/michaellee8
[@linhanyu]: https://github.com/linhanyu
[@jda258]: https://github.com/jda258
[@jpnurmi]: https://github.com/jpnurmi
[@LucasAschenbach]: https://github.com/LucasAschenbach
[@tauu]: https://github.com/tauu
[@itzhoujun]: https://github.com/itzhoujun
[@nuc134r]: https://github.com/nuc134r
[@djnalluri]: https://github.com/djnalluri
[@domesticmouse]: https://github.com/domesticmouse


[#40]: https://github.com/TerminalStudio/xterm.dart/pull/40
[#43]: https://github.com/TerminalStudio/xterm.dart/pull/43
[#44]: https://github.com/TerminalStudio/xterm.dart/pull/44
[#45]: https://github.com/TerminalStudio/xterm.dart/pull/45
[#46]: https://github.com/TerminalStudio/xterm.dart/pull/46
[#47]: https://github.com/TerminalStudio/xterm.dart/pull/47
[#48]: https://github.com/TerminalStudio/xterm.dart/pull/48
[#49]: https://github.com/TerminalStudio/xterm.dart/pull/49
[#50]: https://github.com/TerminalStudio/xterm.dart/pull/50
[#51]: https://github.com/TerminalStudio/xterm.dart/pull/51


[#55]: https://github.com/TerminalStudio/xterm.dart/pull/55
[#60]: https://github.com/TerminalStudio/xterm.dart/pull/60
[#61]: https://github.com/TerminalStudio/xterm.dart/pull/61
[#62]: https://github.com/TerminalStudio/xterm.dart/pull/62
[#63]: https://github.com/TerminalStudio/xterm.dart/pull/63
[#66]: https://github.com/TerminalStudio/xterm.dart/pull/66
[#67]: https://github.com/TerminalStudio/xterm.dart/pull/67
[#69]: https://github.com/TerminalStudio/xterm.dart/pull/69
[#74]: https://github.com/TerminalStudio/xterm.dart/pull/74
[#77]: https://github.com/TerminalStudio/xterm.dart/pull/77

[#104]: https://github.com/TerminalStudio/xterm.dart/issues/104
[#123]: https://github.com/TerminalStudio/xterm.dart/pull/123
[#124]: https://github.com/TerminalStudio/xterm.dart/pull/124
[#125]: https://github.com/TerminalStudio/xterm.dart/pull/125
[#126]: https://github.com/TerminalStudio/xterm.dart/pull/126
[#127]: https://github.com/TerminalStudio/xterm.dart/pull/127
[#128]: https://github.com/TerminalStudio/xterm.dart/pull/128
[#129]: https://github.com/TerminalStudio/xterm.dart/pull/129
[#130]: https://github.com/TerminalStudio/xterm.dart/pull/130
[#131]: https://github.com/TerminalStudio/xterm.dart/pull/131
[#132]: https://github.com/TerminalStudio/xterm.dart/pull/132
[#135]: https://github.com/TerminalStudio/xterm.dart/pull/135
[#137]: https://github.com/TerminalStudio/xterm.dart/issues/137
[#138]: https://github.com/TerminalStudio/xterm.dart/pull/138
[#140]: https://github.com/TerminalStudio/xterm.dart/pull/140
[#141]: https://github.com/TerminalStudio/xterm.dart/pull/141

[#151]: https://github.com/TerminalStudio/xterm.dart/pull/151

[#160]: https://github.com/TerminalStudio/xterm.dart/pull/160
[#161]: https://github.com/TerminalStudio/xterm.dart/pull/161
[#169]: https://github.com/TerminalStudio/xterm.dart/pull/169

[#186]: https://github.com/TerminalStudio/xterm.dart/pull/186
[#190]: https://github.com/TerminalStudio/xterm.dart/pull/190
 
