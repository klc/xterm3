# One payload per kind of emoji sequence, in gen.py's `emoji` line shape, so a
# change to the emoji path can be priced per grapheme rule.
#   python3 gen_emoji.py <MiB> <out_dir>
import random, sys, os
N = int(sys.argv[1]) * 1024 * 1024; out = sys.argv[2]
classes = {
    'e-simple': list('😀🚀🔥✅👍🎉💡📦'),                 # one code point each
    'e-mod': ['👍🏽', '👋🏻', '👍🏿', '✋🏼'],                # skin tones
    'e-zwj': ['👨‍👩‍👧‍👦', '👩‍💻', '🏳️‍🌈', '👨‍🚀'],          # ZWJ sequences
    'e-flag': ['🇺🇸', '🇯🇵', '🇩🇪', '🇹🇷'],              # regional indicator pairs
    'e-vs16': ['❤️', '☀️', '✔️', '✌️'],                  # text symbols with VS16
}
for name, toks in classes.items():
    r = random.Random(42); pool = toks + list('abcdef '); w = [45 / len(toks)] * len(toks) + [1] * 7
    parts = []; n = 0
    while n < N:
        s = ''.join(r.choices(pool, weights=w, k=r.randint(1, 80))) + '\n'; parts.append(s); n += len(s.encode())
    with open(os.path.join(out, name), 'w') as f: f.write(''.join(parts))
