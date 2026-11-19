# Runs inside the terminal under test. For each payload: write it to the tty,
# then send DSR (ESC[6n) and wait for the cursor-position reply. The reply can
# only come after the terminal has parsed every byte before it, so the clock
# stops on "parsed", not on "the PTY accepted the bytes".
import os, sys, time, tty, termios, json
term, results, *payloads = sys.argv[1:]
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setcbreak(fd)
def sync():
    os.write(1, b'\x1b[6n'); buf = b''
    while not buf.endswith(b'R'): buf += os.read(fd, 1)
try:
    time.sleep(1); sync()  # let the window settle (Ghostty resizes after spawn)
    cols, rows = os.get_terminal_size()
    for p in payloads:
        data = open(p, 'rb').read()
        os.write(1, b'\x1b[H\x1b[2J'); sync()
        t0 = time.perf_counter()
        for i in range(0, len(data), 65536): os.write(1, data[i:i+65536])
        t1 = time.perf_counter(); sync(); t2 = time.perf_counter()
        with open(results, 'a') as f:
            f.write(json.dumps(dict(term=term, payload=os.path.basename(p), size=len(data), cols=cols, rows=rows,
                                    accepted=t1-t0, parsed=t2-t0, mibs=len(data)/2**20/(t2-t0))) + '\n')
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
