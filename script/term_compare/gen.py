# Deterministic payloads, ~SIZE MiB each.
import random, sys, os
SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 64
N = SIZE * 1024 * 1024
out = sys.argv[2] if len(sys.argv) > 2 else '.'
PR = ''.join(chr(c) for c in range(0x20, 0x7f))

def emit(name, gen):
    r = random.Random(42); parts = []; n = 0
    while n < N:
        s = gen(r); parts.append(s); n += len(s.encode())
    with open(os.path.join(out, name), 'w') as f: f.write(''.join(parts))

emit('ascii', lambda r: ''.join(r.choices(PR, k=r.randint(1, 200))) + '\n')
def sgr(r):
    w = []
    for _ in range(r.randint(3, 15)):
        a = r.random()
        if a < .33: w.append(f'\x1b[38;5;{r.randint(0,255)}m')
        elif a < .66: w.append(f'\x1b[38;2;{r.randint(0,255)};{r.randint(0,255)};{r.randint(0,255)}m\x1b[48;5;{r.randint(0,255)}m')
        else: w.append(f'\x1b[{r.choice([1,3,4,7])}m')
        w.append(''.join(r.choices(PR, k=r.randint(2, 10))) + ' ')
    return ''.join(w) + '\x1b[0m\n'
emit('sgr', sgr)
CJK = 'あいうえお漢字日本語中文한국어'; BOX = '─│┌┐└┘├┤█▓▒░⠿'
UNI = 'çğıöşüÇĞİÖŞÜ' + CJK + '😀🚀🔥✅👍' + BOX
emit('unicode', lambda r: ''.join(r.choices(UNI + 'abcdef ', k=r.randint(1, 80))) + '\n')
# One script class per payload, same line shape; tokens may be multi-code-point.
# Filler weighted to 7/52 of tokens, the share 'abcdef ' has in `unicode`.
def per_script(name, toks):
    toks = list(toks); pool = toks + list('abcdef '); w = [45 / len(toks)] * len(toks) + [1] * 7
    emit(name, lambda r: ''.join(r.choices(pool, weights=w, k=r.randint(1, 80))) + '\n')
per_script('latin-ext', 'éèêëàâäáãåæçñüöóòôõøœßłžšćčďěřůźżğşıİÉÀÑÜÖØÅŁŽŠČ')
per_script('cyrillic', 'абвгдежзийклмнопрстуфхцчшщъыьэюяАБВГДЕЖЗИКЛМНОПРСТУФХЦЧШЩЭЮЯ')
per_script('cjk', CJK)
per_script('emoji', list('😀🚀🔥✅👍🎉💡📦') + ['👍🏽', '👋🏻', '👨‍👩‍👧‍👦', '👩‍💻', '🇺🇸', '🇯🇵', '🇩🇪', '❤️', '☀️', '✔️'])
per_script('combining', list('कखगनमसतरिीाुे्ं') + list('البعرينكةَُِّْ') + ['é', 'à', 'ñ', 'ö', 'ụ̂'])
per_script('box', BOX)
# Alt screen, random cursor motion + short writes; grid assumed 100x37.
def motion(r):
    return ''.join(f'\x1b[{r.randint(1,37)};{r.randint(1,100)}H' + ''.join(r.choices(PR, k=r.randint(1, 8))) for _ in range(50))
emit('cursor', motion)
with open(os.path.join(out, 'cursor'), 'r+') as f:
    body = f.read(); f.seek(0); f.write('\x1b[?1049h' + body + '\x1b[?1049l')
