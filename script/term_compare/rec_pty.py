# Records what a real program writes to a 100x37 terminal, for use as a
# drive.py payload.
#   python3 rec_pty.py OUT KEYS -- cmd args...
# KEYS is a comma list: 'w0.5' waits 0.5 s, 'x30*\x06' sends ctrl-F 30 times,
# anything else is sent once (python escapes allowed). Each key is followed by
# 80 ms of reading, so a TUI redraws between keys. Sequences that make a
# terminal reply (DSR, DA, DECRQM, XTVERSION, OSC/DCS queries, focus
# reporting, window reports) are removed from the saved bytes: a reply would
# end drive.py's sync() early and shift the measured window.
#   e.g. vim with a truecolor scheme:
#   python3 rec_pty.py /tmp/vim 'x60*\x06,:qa!\r' -- vim -u NONE -N -i NONE \
#     -c 'syntax on' -c 'set tgc nu' -c 'colo unokai' lib/src/ui/painter.dart
import codecs, fcntl, os, pty, re, select, struct, sys, termios, time

QUERIES = re.compile(rb'\x1b\[[?>=]?[0-9;]*[nc]|\x1b\[\??[0-9;]*\$p|\x1b\[>[0-9;]*q'
                     rb'|\x1b\][0-9]+;[^\x07\x1b]*\?(\x07|\x1b\\)|\x1bP[$+]q[^\x1b]*\x1b\\'
                     rb'|\x1b\[(1[3489]|2[01])t|\x1b\[\?[0-9;]*u|\x1b\[\?1004h|\x1bZ')

out, spec, *cmd = sys.argv[1:]
if cmd and cmd[0] == '--': cmd = cmd[1:]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM='xterm-256color', COLORTERM='truecolor', LINES='37', COLUMNS='100')
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 37, 100, 0, 0))
buf = bytearray()

def pump(t):
    end = time.time() + t
    while True:
        r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not r: return
        try: d = os.read(fd, 65536)
        except OSError: return
        if not d: return
        buf.extend(d)

pump(1.5)
for tok in spec.split(','):
    if tok.startswith('w'): pump(float(tok[1:])); continue
    n, key = 1, tok
    if tok.startswith('x') and '*' in tok: n, key = int(tok[1:tok.index('*')]), tok[tok.index('*') + 1:]
    for _ in range(n):
        try: os.write(fd, codecs.decode(key, 'unicode_escape').encode())
        except OSError: break
        pump(0.08)
pump(1.0)
try: os.kill(pid, 9)
except OSError: pass
data, n = QUERIES.subn(b'', bytes(buf))
open(out, 'wb').write(data)
print(out, len(data), 'bytes,', n, 'reply-triggering sequences removed')
