
## xterm3

<p>
    <a href="https://pub.dev/packages/xterm3">
      <img alt="Package version" src="https://img.shields.io/pub/v/xterm3?color=blue&include_prereleases">
    </a>
</p>

`xterm3` continues the line that started with
[`xterm`](https://pub.dev/packages/xterm) from
[`TerminalStudio/xterm.dart`](https://github.com/TerminalStudio/xterm.dart) and
was kept alive as [`xterm2`](https://pub.dev/packages/xterm2). The original
package is unmaintained, and `xterm2` has since diverged far enough — rewritten
renderer, reworked buffer and reflow, new input and search paths — that it
continues here under its own name. `xterm2` users migrate by changing the
dependency and the package in imports; the public API is unchanged.

**xterm3** is a fast and fully-featured terminal emulator for Flutter applications, with support for mobile and desktop platforms.

> This package requires Flutter version >=3.19.0

## Screenshots

<table>
  <tr>
    <td>
		<img width="200px" src="https://raw.githubusercontent.com/klc/xterm3/master/media/demo-shell.png">
    </td>
    <td>
       <img width="200px" src="https://raw.githubusercontent.com/klc/xterm3/master/media/demo-vim.png">
    </td>
  <tr>
  </tr>
    <td>
       <img width="200px" src="https://raw.githubusercontent.com/klc/xterm3/master/media/demo-htop.png">
    </td>
    <td>
       <img width="200px" src="https://raw.githubusercontent.com/klc/xterm3/master/media/demo-dialog.png">
    </td>
  </tr>
</table>

## Features

- 📦 **Works out of the box** No special configuration required.
- 🚀 **Fast** Renders at 60fps.
- 😀 **Wide character support** Supports CJK and emojis.
- ✂️ **Customizable** 
- 🔗 **Ligatures** Opt-in via `TerminalStyle(enableLigatures: true)`, with a
  ligature-capable font such as Fira Code, JetBrains Mono or Iosevka. Ligatures
  are drawn only where they fill exactly the cells they cover, so the grid never
  shifts; anything else falls back to per-cell painting.
- ✔ **Frontend independent**: The terminal core can work without flutter frontend.

**What's new in 3.0.0:**

- 📱 Enhanced support for **mobile** platforms.
- ⌨️ Integrates with Flutter's **shortcut** system.
- 🎨 Allows changing **theme** at runtime.
- 💪 Better **performance**. No tree rebuilds anymore.
- 🈂️ Works with **IMEs**.

## Getting Started

**1.** Add this to your package's pubspec.yaml file:

```yml
dependencies:
  ...
  xterm3: ^5.1.0
```

**2.** Create the terminal:

```dart
import 'package:xterm3/xterm.dart';
...
terminal = Terminal();
```

Listen to user interaction with the terminal by simply adding a `onOutput` callback:

```dart
terminal = Terminal();

terminal.onOutput = (output) {
  print('output: $output');
}
```

**3.** Create the view, attach the terminal to the view:

```dart
import 'package:xterm3/flutter.dart';
...
child: TerminalView(terminal),
```

**4.** Write something to the terminal:

```dart
terminal.write('Hello, world!');
```

**Done!**

## More examples

- Write a simple terminal in ~100 lines of code:
  https://github.com/klc/xterm3/blob/master/example/lib/main.dart

- Write a SSH client in ~100 lines of code with [dartssh2]:
  https://github.com/klc/xterm3/blob/master/example/lib/ssh.dart
  
  <img width="400px" src="https://raw.githubusercontent.com/klc/xterm3/master/media/example-ssh.png">

For the original package history, see [TerminalStudio/xterm.dart].

## Features and bugs

Please file feature requests and bugs at the [issue tracker](https://github.com/klc/xterm3/issues).

Contributions are always welcome!

## License

`xterm3` is licensed under the [GNU Affero General Public License v3.0 or
later](LICENSE) (AGPL-3.0-or-later). Linking it into an application makes that
application a work covered by the AGPL: if you distribute it, or let users
interact with it over a network, you must offer them its complete corresponding
source under the same license.

The `xterm` and `xterm2` work this package is derived from is MIT licensed and
stays available under those terms; that notice is kept in [LICENSE.MIT](LICENSE.MIT)
and [NOTICE](NOTICE). Versions up to `xterm2` 5.3.0 are unaffected by this
change — the AGPL applies from `xterm3` 6.0.0 onward.

[dartssh2]: https://pub.dev/packages/dartssh2
[TerminalStudio/xterm.dart]: https://github.com/TerminalStudio/xterm.dart
