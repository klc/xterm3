# Adversarial grapheme corpus for grid_oracle.sh. Deterministic (seed 2027).
# Section 6 slices 3 MiB off each gen.py / gen_synthetic.py payload, so those
# must be at least 3 MiB for the full 335 files.
#   python3 gen_corpus.py <gen.py dir> <gen_synthetic.py dir> <out_dir>
import os, random, sys

PAY, PAYC, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)
R = random.Random(2027)
C = chr
def rng(a, b): return [C(c) for c in range(a, b + 1)]

ASCII = list('abcdefghijklmnopqrstuvwxyzABCXYZ0123456789 .,;:!?-#*')
LATIN = list('éèñöüçğşıøőźßÆœαβγδжяфщљԱբ')
CJK = list('あいうえおアイウエオ漢字日本語中文ｱｲｳ　｡') + [C(0x20000), C(0x2A6D6), C(0x3000), C(0x30000), C(0xFF01)]
LV = [C(0xAC00 + 28 * i) for i in range(0, 399, 7)]
LVT = [C(0xAC00 + 28 * i + t) for i in range(0, 399, 11) for t in (1, 13, 27)]
L = rng(0x1100, 0x115F) + rng(0xA960, 0xA97F)
V = rng(0x1160, 0x11A7) + rng(0xD7B0, 0xD7C6) + rng(0xD7C7, 0xD7CA)
T = rng(0x11A8, 0x11FF) + rng(0xD7CB, 0xD7FF)
HCOMPAT = rng(0x3131, 0x318E) + [C(0x3164), C(0xFFA0), C(0x115F), C(0x1160)]
PREPEND = [C(c) for c in (0x600, 0x601, 0x602, 0x603, 0x604, 0x605, 0x6DD, 0x70F, 0x890, 0x891, 0x8E2,
                          0x110BD, 0x110CD, 0xD4E, 0x111C2, 0x111C3, 0x1193F, 0x11941, 0x11A3A,
                          0x11A84, 0x11A89, 0x11D46, 0x11F02)]
MARKS = rng(0x300, 0x36F) + rng(0x483, 0x489) + rng(0x1AB0, 0x1ABE) + rng(0x1DC0, 0x1DFF) + rng(0x20D0, 0x20F0) + \
        rng(0xFE20, 0xFE2F) + [C(0x3099), C(0x309A), C(0xFF9E), C(0xFF9F), C(0x302A), C(0x302E), C(0x302F),
                               C(0x16FF0), C(0x16FF1), C(0x1D165), C(0x1D16D), C(0xE0020), C(0xE007F), C(0xE0100)]
CONTROLISH = [C(c) for c in (0xAD, 0x61C, 0x180E, 0x200B, 0x200E, 0x2028, 0x2029, 0x2060, 0x2064, 0xFEFF,
                             0xFFF9, 0xFFFB, 0x13430, 0x1343F, 0x1BCA0, 0x1D173, 0xE0001, 0xE0FFF, 0x200C)]
ZWJ, ZWNJ, VS15, VS16, KEYCAP = '‍', '‌', '︎', '️', '⃣'
EMOJI = list('😀🚀🔥👍🎉💡📦👨👩👧👦💻🌈🏳🧑🦰❤☺✋👶🏃🤝⌚©®↔#*1') + ['☝', '⛹', '✌', '\U0001F9D1']
MODS = rng(0x1F3FB, 0x1F3FF)
RI = rng(0x1F1E6, 0x1F1FF)
ZWJSEQ = ['👨‍👩‍👧‍👦', '👩‍💻', '🏳️‍🌈', '🧑🏽‍🚀', '👨🏿‍🦰',
          '❤️‍🔥', '🏃‍♀️', 'a‍👍', '中‍🚀', '‍😀', '😀‍', '😀‍‍😀',
          '😀‍a', '😀́‍🚀', 'क‍👍', '👍‍́😀', '1️⃣', '#⃣', '*️⃣']
INDIC_BLOCKS = [0x900, 0x980, 0xA00, 0xA80, 0xB00, 0xB80, 0xC00, 0xC80, 0xD00, 0xD80]
VIRAMAS = [C(c) for c in (0x94D, 0x9CD, 0xA4D, 0xACD, 0xB4D, 0xBCD, 0xC4D, 0xCCD, 0xD4D, 0xDCA)]
INDIC = [C(b + o) for b in INDIC_BLOCKS for o in range(0x00, 0x80)]
CONS = [C(b + o) for b in INDIC_BLOCKS for o in range(0x15, 0x39)]
SPACING = [C(c) for c in (0x93E, 0x93F, 0x940, 0x949, 0x94C, 0x9BF, 0x9C0, 0x9CB, 0xA3E, 0xA3F, 0xABE, 0xB40,
                          0xBBF, 0xBC1, 0xC41, 0xC82, 0xCBE, 0xD3F, 0xD82, 0xDD0, 0x903, 0xE33, 0xEB3, 0x1031, 0x17B6)]
ARABIC = rng(0x627, 0x64A) + rng(0x64B, 0x652) + [C(0x670), C(0x6D6), C(0x640), C(0x6F0)]
HEBREW = rng(0x5D0, 0x5EA) + rng(0x5B0, 0x5BD) + [C(0x5C1), C(0x5C2), C(0x5C7)]
THAI = rng(0xE01, 0xE2E) + [C(0xE31), C(0xE33)] + rng(0xE34, 0xE3A) + rng(0xE47, 0xE4E)
LAO = rng(0xE81, 0xEAE) + [C(0xEB1), C(0xEB3)] + rng(0xEB4, 0xEBC) + rng(0xEC8, 0xECD)
OTHER_SCRIPTS = rng(0x1000, 0x109F) + rng(0x1780, 0x17FF) + rng(0xF00, 0xFFF) + rng(0x1B00, 0x1B7F) + \
                rng(0xA980, 0xA9DF) + rng(0x11000, 0x1107F) + rng(0x11180, 0x111DF) + rng(0x1E900, 0x1E95F)

POOLS = dict(ascii=ASCII, latin=LATIN, cjk=CJK, lv=LV, lvt=LVT, l=L, v=V, t=T, hcompat=HCOMPAT, prepend=PREPEND,
             marks=MARKS, control=CONTROLISH, emoji=EMOJI, mods=MODS, ri=RI, indic=INDIC, cons=CONS,
             spacing=SPACING, arabic=ARABIC, hebrew=HEBREW, thai=THAI, lao=LAO, other=OTHER_SCRIPTS,
             vs=[VS15, VS16, KEYCAP], zw=[ZWJ, ZWNJ])

def ln(r, n=None):
    return '\r\n' if r.random() < 0.9 else '\n'

def write(name, s):
    with open(os.path.join(OUT, name), 'w', encoding='utf-8') as f:
        f.write(s)

# 1. each class in isolation: random runs from one pool, varied line lengths
for name, pool in POOLS.items():
    parts = []
    for _ in range(1500):
        parts.append(''.join(R.choice(pool) for _ in range(R.randint(1, 30))))
        parts.append(ln(R) if R.random() < 0.3 else '')
    write(f'iso-{name}', ''.join(parts))

# 2. targeted sequences
seq = []
for _ in range(400):
    l, v, t = R.choice(L), R.choice(V), R.choice(T)
    lv, lvt = R.choice(LV), R.choice(LVT)
    seq += [l + lv, l + lvt, l + l + v, l + v + t, lv + v, lv + t, lv + v + t, lvt + t, lvt + v, lvt + t + t,
            v + v, t + t, v, t, l, l + R.choice(ASCII), R.choice(ASCII) + v, R.choice(CJK) + t, lv + l, lvt + l,
            R.choice(HCOMPAT) + v, l + '́' + v, lv + '́' + t]
    p = R.choice(PREPEND)
    seq += [p + R.choice(ASCII), 'a' + p + 'b', p + R.choice(CJK), p + R.choice(INDIC), p + p + 'x',
            p + R.choice(EMOJI), p + '́', p + R.choice(L), R.choice(CONS) + p + R.choice(CONS), p + ln(R)]
    seq += [R.choice(ZWJSEQ), ZWJ + R.choice(EMOJI), R.choice(ASCII) + ZWJ + R.choice(ASCII),
            R.choice(EMOJI) + ZWJ + R.choice(CJK), R.choice(EMOJI) + R.choice(MODS) + ZWJ + R.choice(EMOJI)]
    seq += [''.join(R.choice(RI) for _ in range(R.randint(1, 5))), 'a' + R.choice(RI) + R.choice(RI),
            R.choice(RI) + '́' + R.choice(RI), R.choice(CJK) + R.choice(RI), R.choice(RI) + ZWJ + R.choice(RI)]
    seq += [R.choice(EMOJI) + R.choice([VS15, VS16]), R.choice(ASCII + CJK + LATIN) + R.choice([VS15, VS16]),
            R.choice('0123456789#*') + R.choice(['', VS16]) + KEYCAP, R.choice(EMOJI) + VS16 + VS15,
            R.choice(EMOJI) + '́' + VS16]
    seq += [R.choice(EMOJI) + R.choice(MODS), R.choice(ASCII + CJK) + R.choice(MODS), R.choice(MODS),
            R.choice(MODS) + R.choice(MODS), R.choice(EMOJI) + VS16 + R.choice(MODS),
            R.choice(EMOJI) + ZWJ + R.choice(MODS), R.choice(INDIC) + R.choice(MODS)]
    b = R.choice(range(len(INDIC_BLOCKS)))
    cons = [C(INDIC_BLOCKS[b] + o) for o in range(0x15, 0x39)]
    vir = VIRAMAS[b]
    seq += [R.choice(cons) + vir + R.choice(cons), R.choice(cons) + vir + ZWJ + R.choice(cons),
            R.choice(cons) + vir + ZWNJ + R.choice(cons), R.choice(cons) + ZWJ + vir + R.choice(cons),
            R.choice(cons) + vir + R.choice(cons) + vir + R.choice(cons), R.choice(cons) + R.choice(SPACING),
            R.choice(cons) + vir + R.choice(SPACING), R.choice(cons) + '़' + vir + R.choice(cons),
            vir + R.choice(cons), R.choice(cons) + vir + 'a', R.choice(cons) + vir + R.choice(CJK)]
    seq += [R.choice(ARABIC[:36]) + ''.join(R.choice(ARABIC[36:]) for _ in range(R.randint(0, 3))),
            R.choice(HEBREW[:27]) + ''.join(R.choice(HEBREW[27:]) for _ in range(R.randint(0, 3))),
            R.choice(THAI[:46]) + ''.join(R.choice(THAI[46:]) for _ in range(R.randint(0, 3))),
            R.choice(LAO) + R.choice(LAO) + R.choice(LAO)]
    seq += [R.choice(ASCII + LATIN + CJK + EMOJI) + ''.join(R.choice(MARKS) for _ in range(R.randint(1, 40))),
            ln(R) + R.choice(MARKS) + 'x', R.choice(CJK) + R.choice(MARKS), R.choice(MARKS) + R.choice(MARKS),
            R.choice(CONTROLISH) + R.choice(MARKS), 'a' + R.choice(CONTROLISH) + R.choice(MARKS) + R.choice(CJK)]
    seq += [R.choice(ASCII) + R.choice(CJK), R.choice(CJK) + R.choice(ASCII), R.choice(LATIN) + R.choice(EMOJI),
            R.choice(THAI) + R.choice(CJK), R.choice(ARABIC) + R.choice(EMOJI), R.choice(INDIC) + R.choice(LV)]
    seq.append(ln(R))
R.shuffle(seq)
write('seq-shuffled', ''.join(seq))
write('seq-joined', ''.join(s + (ln(R) if R.random() < 0.05 else '') for s in seq))

# 3. edges: fill a line to width-k for the two grid widths, then the probe
edge = []
for width in (100, 7):
    for _ in range(600):
        k = R.randint(0, 3)
        probe = R.choice(seq).replace('\r', '').replace('\n', '')
        edge.append('\r' + 'x' * max(0, width - k - 1) + R.choice(['x', 'é', '中', '가', 'ᄀ', '😀', 'क्', 'á']) +
                    probe + ln(R))
write('edges', ''.join(edge))

# 4. mixed: all pools and sequences, random
allpool = [x for p in POOLS.values() for x in p]
for i in range(3):
    parts = []
    for _ in range(40000):
        x = R.random()
        if x < 0.5:
            parts.append(R.choice(allpool))
        elif x < 0.8:
            parts.append(R.choice(R.choice(list(POOLS.values()))))
        elif x < 0.97:
            parts.append(R.choice(seq))
        else:
            parts.append(R.choice(['\r\n', '\n', '\x1b[3D', '\b', '\x1b[2C', '\t', '\x1b[?2027l', '\x1b[?2027h']))
    write(f'mix-{i}', ''.join(parts))

# 5. every code point X after a set of bases ("B X " triples), split by plane
cps = [c for c in range(0x20, 0x110000) if not (0x7F <= c < 0xA0 or 0xD800 <= c < 0xE000)
       and (c < 0x20000 or 0xE0000 <= c < 0xE1000 or c % 97 == 0)]
bases = ['a', 'é', '中', '😀', '가', '각', 'ᄀ', 'ꥠ', '\u06dd', '\U00011A3A', '\U00016D63', 'ᄀ\u1161', '가\u11a8',
         '🇦🇧', '☺\ufe0f', '\x1b[?2027la\u200b\u0600\x1b[?2027h', 'क्', 'क', 'a\u0301', 'ि', '🇦', '👍',
         '😀\u200d', 'ส', 'ب', 'ა', '\u2028']
for bi, b in enumerate(bases):
    for part in range(0, len(cps), 40000):
        write(f'all-{bi:02d}-{part // 40000:02d}', ''.join(b + C(c) + ' ' + ('\r\n' if j % 30 == 29 else '')
                                                           for j, c in enumerate(cps[part:part + 40000])))

# 6. slices of the benchmark payloads (cut at a line start), 3 MiB each in 256 KiB files
for d, names in ((PAY, ['ascii', 'sgr', 'unicode', 'latin-ext', 'cyrillic', 'cjk', 'emoji', 'combining', 'box', 'cursor']),
                 (PAYC, ['c-wide-only', 'c-wide-narrow', 'c-hangul-only', 'c-emoji-only', 'c-emoji-narrow',
                         'c-latin-combining'])):
    for n in names:
        data = open(os.path.join(d, n), 'rb').read(3 * 2 ** 20 + 4096)
        data = data[:data.rfind(b'\n', 0, 3 * 2 ** 20) + 1]
        lines, cur, k = data.splitlines(keepends=True), [], 0
        for line in lines + [None]:
            if line is None or sum(map(len, cur)) + len(line) > 256 * 1024:
                open(os.path.join(OUT, f'pay-{n}-{k:02d}'), 'wb').write(b''.join(cur))
                cur, k = [], k + 1
            if line is not None:
                cur.append(line)
