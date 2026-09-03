#!/usr/bin/env python3
"""Records raw PTY output for the README screenshots.

The screenshot harness (`example/lib/screenshot.dart`) replays these bytes into
a `Terminal` and paints one frame, so the images show real program output
rather than a mock - but reproducibly, with no PTY and no keystroke injection
at capture time.

    python3 script/screenshots/record.py

Writes `example/assets/screenshots/<scene>.raw`. Re-record when the scenes
should change; the harness does not need the tools installed.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

COLUMNS = 100
ROWS = 30

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.path.join(REPO, "example", "assets", "screenshots")


def record(name, argv, script, settle=0.6, cwd=None):
    """Runs `argv`, feeds it `script`, and saves everything it printed.

    `script` is a list of (delay_seconds, bytes) - the delay is waited *before*
    the bytes are written, which is how a TUI is given time to draw before the
    next key arrives.
    """
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd or REPO)
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = str(COLUMNS)
        env["LINES"] = str(ROWS)
        env["COLORTERM"] = "truecolor"
        env.pop("CLICOLOR_FORCE", None)
        os.execvpe(argv[0], argv, env)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))

    captured = bytearray()

    def drain(seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            remaining = deadline - time.time()
            ready, _, _ = select.select([fd], [], [], max(remaining, 0))
            if not ready:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            captured.extend(chunk)
        return True

    for delay, data in script:
        if not drain(delay):
            break
        try:
            os.write(fd, data)
        except OSError:
            break

    drain(settle)

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    os.close(fd)

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name + ".raw")
    with open(path, "wb") as handle:
        handle.write(bytes(captured))
    print("%-10s %7d bytes  %s" % (name, len(captured), path))


def main():
    # A shell session: colour, a graph, and text no ASCII-only fast path can
    # take - all of it output this repository produces.
    record(
        "shell",
        ["/bin/zsh", "-f"],
        [
            (0.4, b"export PS1='%F{cyan}xterm3%f %F{242}~/xterm3%f $ '\n"),
            (0.3, b"clear\n"),
            # --no-pager, or git hands the graph to less and the recording is
            # a screenful of less rather than of git.
            (0.4, b"git --no-pager log --oneline --graph --decorate -9 --color=always\n"),
            (1.0, b"printf 'wide \\u65e5\\u672c\\u8a9e   emoji \\U0001F680 \\U0001F9EA   combining e\\u0301   cyrillic \\u043f\\u0440\\u0438\\u0432\\u0435\\u0442\\n'\n"),
            (0.8, b"grep --color=always -n 'born\\|store' lib/src/core/buffer/line.dart | head -6\n"),
            (0.8, b"ls -lG lib/src/core/buffer | head -8\n"),
            (0.8, b""),
        ],
        settle=1.5,
    )

    # Box drawing, block elements and 256-colour bars: the procedural glyph
    # path, which is drawn rather than looked up in a font.
    record(
        "htop",
        ["htop"],
        [(3.0, b"")],
        settle=1.5,
    )

    # A real editor on a real file from this package.
    record(
        "vim",
        [
            "vim",
            "-u", "NONE",
            "-c", "syntax on",
            "-c", "set number nocompatible background=dark laststatus=2 "
                  "statusline=%f\\ %m%=%l:%c\\ \\ %P",
            "-c", "normal 1G",
            "lib/src/core/buffer/line.dart",
        ],
        [(2.0, b"")],
        settle=1.0,
    )


if __name__ == "__main__":
    main()
