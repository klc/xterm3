# README screenshots

Two steps, and both are reproducible — the images in `media/` are painted by
this package, not retouched.

```sh
python3 script/screenshots/record.py
cd example && flutter run --release -d macos -t lib/screenshot.dart
```

**`record.py`** runs each program in a real PTY pinned to 100x30, feeds it a
scripted sequence of keys, and saves every byte it printed to
`example/assets/screenshots/<scene>.raw`. That is the only step that needs the
programs installed, and the only step that touches the machine it runs on.

**`example/lib/screenshot.dart`** replays a recording into a `Terminal`, paints
one frame of a real `TerminalView` into a `RepaintBoundary`, and writes the
result to `media/`. No PTY, no keystroke injection, no window chrome — the same
recording produces the same image on any machine with the same font.

`preview.dart` dumps a recording as text without rendering it, which is how to
tell a scene that failed from one that merely looks odd in a diff:

```sh
dart run script/screenshots/preview.dart example/assets/screenshots/vim.raw
```

## Scenes

| recording | image | what it is there to show |
|---|---|---|
| `shell` | `demo-shell.png` | SGR colour, CJK, emoji, combining marks, Cyrillic |
| `htop` | `demo-htop.png` | block elements and meters on the procedural glyph path |
| `vim` | `demo-vim.png` | full-screen redraw on the alternate screen |
| — | `demo-search.png` | `Terminal.search` matches handed to the controller, over the `shell` recording |

`demo-search.png` has no recording of its own: the highlights are xterm3's, not
the recorded program's, so the scene replays `shell` and then searches it.

## Watch what you record

`record.py` captures whatever the program prints on **this** machine. The htop
scene is a real process list — usernames, home paths, and every application
that happened to be running. Check the recording before committing it:

```sh
dart run script/screenshots/preview.dart example/assets/screenshots/htop.raw
```
