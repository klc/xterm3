# Ablations of gen.py's `sgr` payload, one change per variant, ~SIZE MiB each.
# Same line shape as `sgr` (3-15 runs of SGR + 2-10 printable chars + space,
# ESC[0m only at line end) unless the variant says otherwise. Seed 42.
#   python3 gen_sgr_ablate.py 16 <out_dir> [real_dir]
# real_dir: realistic captures (gitlog, ls, clang) are repeated up to SIZE.
import random, sys, os
SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 16
N = SIZE * 1024 * 1024
out = sys.argv[2] if len(sys.argv) > 2 else '.'
PR = ''.join(chr(c) for c in range(0x20, 0x7f))

def emit(name, gen):
    r = random.Random(42); parts = []; n = 0
    while n < N:
        s = gen(r); parts.append(s); n += len(s.encode())
    with open(os.path.join(out, name), 'w') as f: f.write(''.join(parts))

def orig_sgr(r, fg=True, bg=True, c256=None, ctrue=None, attrs=(1, 3, 4, 7)):
    a = r.random()
    c256 = c256 or (lambda: r.randint(0, 255))
    ctrue = ctrue or (lambda: f'{r.randint(0,255)};{r.randint(0,255)};{r.randint(0,255)}')
    if a < .33: return f'\x1b[38;5;{c256()}m'
    if a < .66: return f'\x1b[38;2;{ctrue()}m\x1b[48;5;{c256()}m'
    return f'\x1b[{r.choice(attrs)}m'

def text(r, lo=2, hi=10): return ''.join(r.choices(PR, k=r.randint(lo, hi))) + ' '

def line(r, sgr=orig_sgr, txt=text, runs=None, reset=False):
    w = []
    for _ in range(runs or r.randint(3, 15)):
        if reset: w.append('\x1b[0m')
        w.append(sgr(r)); w.append(txt(r))
    return ''.join(w) + '\x1b[0m\n'

emit('ascii', lambda r: ''.join(r.choices(PR, k=r.randint(1, 200))) + '\n')
emit('sgr', line)
# 8 colours: 30-37 / 40-47 in place of 256 and truecolor; same branch split.
def fix8(r):
    a = r.random()
    if a < .33: return f'\x1b[3{r.randint(0,7)}m'
    if a < .66: return f'\x1b[3{r.randint(0,7)}m\x1b[4{r.randint(0,7)}m'
    return f'\x1b[{r.choice([1,3,4,7])}m'
emit('fix8', lambda r: line(r, fix8))
# Foreground only: the truecolor branch loses its 256-colour background.
def fgonly(r):
    a = r.random()
    if a < .33: return f'\x1b[38;5;{r.randint(0,255)}m'
    if a < .66: return f'\x1b[38;2;{r.randint(0,255)};{r.randint(0,255)};{r.randint(0,255)}m'
    return f'\x1b[{r.choice([1,3,4,7])}m'
emit('fgonly', lambda r: line(r, fgonly))
# Background only: both colour branches set a background, never a foreground.
def bgonly(r):
    a = r.random()
    if a < .33: return f'\x1b[48;5;{r.randint(0,255)}m'
    if a < .66: return f'\x1b[48;2;{r.randint(0,255)};{r.randint(0,255)};{r.randint(0,255)}m'
    return f'\x1b[{r.choice([1,3,4,7])}m'
emit('bgonly', lambda r: line(r, bgonly))
# 256-colour fg only (no truecolor, no bg): bounded key space 95*256*attrs.
def fg256(r):
    return f'\x1b[38;5;{r.randint(0,255)}m' if r.random() < .66 else f'\x1b[{r.choice([1,3,4,7])}m'
emit('fg256', lambda r: line(r, fg256))
emit('attrs', lambda r: line(r, lambda r: f'\x1b[{r.choice([1,3,4,7])}m'))
for name, code in (('bold', 1), ('italic', 3), ('underline', 4), ('inverse', 7)):
    emit(name, lambda r, code=code: line(r, lambda r: f'\x1b[{code}m'))
emit('reset', lambda r: line(r, reset=True))
# Identical line (SGR and text) every line: the cache-hit ceiling.
_same = line(random.Random(7))
emit('same', lambda r: _same)
# Crossed: the same SGR sequence every line with random text, and random SGR
# with the same text every run.
_r7 = random.Random(7); _seq = [orig_sgr(_r7) for _ in range(15)]
def samesgr(r):
    return ''.join(_seq[i] + text(r) for i in range(r.randint(3, 15))) + '\x1b[0m\n'
emit('samesgr', samesgr)
emit('sametext', lambda r: line(r, txt=lambda r: 'abcdef '))
# Style runs per line at ~80 cells per line: text length scaled to the run count.
for n in (1, 4, 15, 40):
    k = max(1, 80 // n - 1)
    emit(f'runs{n}', lambda r, n=n, k=k: line(r, runs=n, txt=lambda r: text(r, k, k)))

real = sys.argv[3] if len(sys.argv) > 3 else None
if real:
    for name in sorted(os.listdir(real)):
        data = open(os.path.join(real, name), 'rb').read()
        with open(os.path.join(out, name), 'wb') as f: f.write(data * (N // len(data) + 1))
