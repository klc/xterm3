# Synthetic payloads that separate the grapheme-join cases: wide only, wide
# then narrow, Hangul syllables, emoji, emoji then narrow, Latin + combining
# mark (decomposed). Same line shape and seed as gen.py; ~SIZE MiB each.
#   python3 gen_synthetic.py <SIZE> <dir>
import random, sys, os
N = int(sys.argv[1]) * 2**20; out = sys.argv[2]
def emit(name, line):
    r = random.Random(42); parts = []; n = 0
    while n < N:
        s = line(r); parts.append(s); n += len(s.encode())
    open(os.path.join(out, name), 'w').write(''.join(parts))
KK = 'あいうえお漢字日本語中文'
HG = '한국어가나다라마바사아자차카타파하'
emit('c-wide-only', lambda r: ''.join(r.choices(KK, k=r.randint(1, 80))) + '\n')
emit('c-wide-narrow', lambda r: ''.join(c + 'a' for c in r.choices(KK, k=r.randint(1, 40))) + '\n')
emit('c-hangul-only', lambda r: ''.join(r.choices(HG, k=r.randint(1, 80))) + '\n')
emit('c-emoji-only', lambda r: ''.join(r.choices('😀🚀🔥👍🎉💡📦', k=r.randint(1, 80))) + '\n')
emit('c-emoji-narrow', lambda r: ''.join(c + 'a' for c in r.choices('😀🚀🔥👍🎉💡📦', k=r.randint(1, 40))) + '\n')
emit('c-latin-combining', lambda r: ''.join(r.choices(['é', 'à', 'ñ', 'ö'], k=r.randint(1, 40))) + '\n')
