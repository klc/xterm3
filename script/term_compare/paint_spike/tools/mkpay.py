# Repeat each capture to 16 MiB after removing sequences that make the terminal reply (they would end drive.py's
# sync() early and shift the measured window): DSR, DA, DECRQM, XTVERSION, OSC colour queries, DCS queries,
# focus reporting (1004h), kitty keyboard query, window-size reports.
import re, sys
N = 16*1024*1024
Q = re.compile(rb'\x1b\[[?>=]?[0-9;]*[nc]|\x1b\[\??[0-9;]*\$p|\x1b\[>[0-9;]*q|\x1b\][0-9]+;[^\x07\x1b]*\?(\x07|\x1b\\)|\x1bP[$+]q[^\x1b]*\x1b\\|\x1b\[(1[3489]|2[01])t|\x1b\[\?[0-9;]*u|\x1b\[\?1004h|\x1bZ')
src = {'vim_unokai':'cap/vim_unokai','vim_habamax256':'cap/vim_habamax256','vimcat_unokai':'cap/vimcat_unokai','vimcat_habamax256':'cap/vimcat_habamax256','htop':'cap/htop','rg_true':'cap/rg_true','git_true':'cap/git_true','cmatrix':'/Users/mkilic/www/klc/xterm3/script/cmatrix.txt','colors256':'/Users/mkilic/www/klc/xterm3/test/_fixture/colors.txt'}
for k, f in src.items():
    b = open(f, 'rb').read()
    if k == 'colors256': b = b.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    b2, n = Q.subn(b'', b); reps = max(1, -(-N // len(b2)))
    open('pay/' + k, 'wb').write(b2 * reps); print(k, len(b2), 'removed', n, 'reps', reps)
