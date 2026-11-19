# A "terminal" that discards everything and only answers DSR: the PTY + driver ceiling.
# Usage: python3 ceiling.py <payload dir>
import os, pty, sys, struct, fcntl, termios
d = os.path.dirname(os.path.abspath(__file__))
pid, fd = pty.fork()
if pid == 0:
    os.execv('/usr/bin/python3', ['python3', f'{d}/drive.py', 'null', f'{sys.argv[1]}/ceiling.jsonl'] + [f'{sys.argv[1]}/{p}' for p in ('ascii','sgr','unicode','cursor')])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 37, 100, 0, 0))
tail = b''
while True:
    try: b = os.read(fd, 1 << 16)
    except OSError: break
    if not b: break
    n = (tail + b).count(b'\x1b[6n'); tail = b[-3:]
    for _ in range(n): os.write(fd, b'\x1b[1;1R')
