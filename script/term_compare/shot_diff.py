# Pixel oracle for paint-path changes, through e2e_bench.dart's XB_SHOT mode.
#   python3 shot_diff.py shot APP SCREENS_DIR OUT_DIR [ENV=VAL ...]
#     every screen file (raw terminal bytes) at DPR 1 and 2, plus a selection
#     (XB_SEL) on the first three, saved as OUT_DIR/<screen>[_sel]_<dpr>.png
#   python3 shot_diff.py diff REF_DIR DIR...
#     per image: '=' when identical, else differing pixels / max channel diff /
#     pixels differing by more than 16
# APP is a release build of example/ with -t lib/e2e_bench.dart (the .app dir).
import os, subprocess, sys, glob

def shot(app, screens, out, env):
    os.makedirs(out, exist_ok=True)
    names = sorted(os.listdir(screens))
    exe = os.path.join(app, 'Contents/MacOS/example')
    for dpr in (1, 2):
        for i, s in enumerate(names):
            for sel in ([None, '5,2,60,14'] if i < 3 else [None]):
                tag = f"{s}{'_sel' if sel else ''}_{dpr}"
                e = dict(os.environ, XB_W='800', XB_H='600', XB_SHOT=os.path.join(screens, s),
                         XB_SHOT_OUT=os.path.join(out, tag + '.png'), XB_DPR=str(dpr), **env)
                if sel: e['XB_SEL'] = sel
                subprocess.run([exe], env=e, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def diff(ref, dirs):
    import numpy as np
    from PIL import Image
    for d in dirs:
        out = []
        for f in sorted(glob.glob(f'{ref}/*.png')):
            n = os.path.basename(f)[:-4]
            a = np.asarray(Image.open(f).convert('RGBA')).astype(int)
            b = np.asarray(Image.open(f'{d}/{n}.png').convert('RGBA')).astype(int)
            if a.shape != b.shape: out.append(f'{n}:SHAPE'); continue
            m = np.abs(a - b).max(axis=2)
            k = int((m > 0).sum())
            out.append(f'{n}:=' if k == 0 else f'{n}:{k}px/max{m.max()}/>16:{int((m > 16).sum())}')
        print(os.path.basename(d.rstrip('/')), ' '.join(out))

if __name__ == '__main__':
    if sys.argv[1] == 'shot':
        shot(*sys.argv[2:5], dict(a.split('=', 1) for a in sys.argv[5:]))
    else:
        diff(sys.argv[2], sys.argv[3:])
