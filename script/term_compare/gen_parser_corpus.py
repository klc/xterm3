#!/usr/bin/env python3
"""Builds the input corpus for script/terminal_state_dump.dart.

    python3 script/term_compare/gen_parser_corpus.py <out-dir> [--payloads DIR]
        [--payload-mib N]

Deterministic: the same arguments give byte-identical files. Three kinds of
input:

  cap_*      real captures copied as they are: script/term_compare/paint_spike/
             captures/* if present, script/cmatrix.txt, test/_fixture/*.txt
  pay_*      the first N MiB (default 2, cut at a line end or an ESC) of each
             payload in --payloads (as written by gen.py: sgr, cursor, unicode, ...)
  gen_*      generated escape-sequence coverage, one theme per file, and
             mix_* files interleaving all of it with text at random

Files that must end inside a sequence are separate (trunc_*), and lone
surrogates, which UTF-8 cannot carry, go into a raw UTF-16LE file
(gen_lone_surrogates.u16le).
"""

import os
import random
import shutil
import struct
import sys

ESC = '\x1b'
CSI = ESC + '['
OSC = ESC + ']'
ST = ESC + '\\'
BEL = '\x07'


def csi(body):
    return CSI + body


def text_bits(r):
    pool = ['abc', 'Hello, World', 'é', 'ñandú', 'Привет', '中文字', '日本',
            '😀', '👍🏽', '🇹🇷', 'é', 'ạ̈', '─│┌┐',
            '⠿⠿', 'x' * 120, '\t', '\r\n', '\n', ' ', '‍', '👨‍👩‍👧',
            'क्षि', '\U0001f680x']
    return r.choice(pool)


def gen_csi_finals(r):
    out = []
    counts = [0, 1, 2, 3, 5, 8, 16, 31, 32, 33, 40]
    for final in range(0x40, 0x7f):
        f = chr(final)
        for n in counts:
            params = ';'.join(str(r.choice([0, 1, 2, 5, 7, 24, 80, 255]))
                              for _ in range(n))
            out.append(csi(params + f) + 'T%02x' % final)
        for prefix in '?>=<':
            out.append(csi(prefix + '1;2' + f) + 'P')
            out.append(csi(prefix + f) + 'P')
        for inter in [' ', '!', '"', '$', "'", '#', '*', '+', '&', ',']:
            out.append(csi('1' + inter + f) + 'I')
            out.append(csi('2;3' + inter + f) + 'I')
            out.append(csi('?1' + inter + f) + 'I')
        out.append(csi(';;' + f) + 'E')
        out.append(csi(';1' + f) + 'E')
        out.append(csi('1;' + f) + 'E')
        out.append(csi('1:2:3' + f) + 'S')
        out.append(csi('1;2:3;;4:' + f) + 'S')
        out.append('\r\n')
    return ''.join(out)


def gen_csi_params(r):
    out = []
    big = ['999999999', '1234567890', '12345678901234567890', '65535',
           '65536', '99999', '4294967296', '18446744073709551617',
           '0' * 30 + '5']
    finals = 'ABCDEFGHJKLMPSTXZ@`abdefghilmnqrstx'
    for f in finals:
        for b in big:
            out.append(csi(b + f) + '.')
            out.append(csi('1;' + b + f) + '.')
            out.append(csi(b + ';' + b + f) + '.')
            out.append(csi('?' + b + f) + '.')
        out.append('\r\n')
    # Around the 32-parameter cap and the 256-code-unit raw-length cap.
    for n in [31, 32, 33, 34, 50, 100, 127, 128, 129, 200]:
        for val in ['1', '22', '333', '9999', '']:
            for sep in [';', ':']:
                body = sep.join([val] * n)
                out.append(csi(body + 'm') + 'n%d' % n)
                out.append(csi('?' + body + 'h') + 'n')
                out.append(csi(body + 'H') + 'n')
        out.append('\r\n')
    # A long, colon-heavy CSI right before short ones: stale slots must not
    # leak into the next sequence's parameters or separators.
    for _ in range(200):
        n = r.choice([30, 31, 32, 33, 40])
        body = ''.join(str(r.randrange(0, 300)) + r.choice(':;')
                       for _ in range(n))
        out.append(csi(body + 'm') + 'L')
        out.append(r.choice([
            csi('38:5m'), csi('38;2;1m'), csi('4m'), csi('58:2::1:2m'),
            csi('m'), csi('38:2m'), csi('48;5m'), csi(';m'), csi('1;m'),
            csi('H'), csi('5;5H'), csi('?25h'), csi('r'), csi('3;10r'),
        ]) + 'S')
    # Raw-length overflow with every kind of terminator.
    for tail in ['m', '\x18', '\x1a', ESC + '[1m', '\x9b1m', '\n', '\x07',
                 '\x01', '!m', 'x']:
        out.append(csi('1;' * 140 + tail) + 'O')
        out.append(csi('?' + '9' * 300 + tail) + 'O')
    return ''.join(out)


def gen_sgr(r):
    out = []
    for code in range(0, 110):
        out.append(csi('%dm' % code) + 'c%d' % code + csi('m'))
    for lead in ['38', '48', '58']:
        for form in [
            ';5;%d', ';2;%d;%d;%d', ':5:%d', ':2::%d:%d:%d', ':2:%d:%d:%d',
            ':2:0:%d:%d:%d', ';2;%d;%d', ';2;%d', ';2', ';5', ':5', ':2',
            ':2::%d:%d', ':2:::', ';2;;;', ':2:%d:%d:%d:%d:%d',
            ';5;%d;1;3', ':3:1:2:3', ':4:1:2:3:4', ';9', ':2::%d:%d:%d;1',
            ';2;300;300;300', ';5;256', ';5;999999',
        ]:
            k = form.count('%d')
            vals = tuple(r.randrange(0, 256) for _ in range(k))
            out.append(csi(lead + (form % vals) + 'm') + 'x' + csi('m'))
    for sub in ['4:0', '4:1', '4:2', '4:3', '4:4', '4:5', '4:6', '4:', '21',
                '4:3;24', '1:2', '3:1', '58:5:12', '59', '>4;2', '>4', '>0']:
        out.append(csi(sub + 'm') + 'u' + csi('m'))
    for _ in range(300):
        n = r.choice([2, 5, 10, 30, 31, 32, 33, 35, 60, 100])
        parts = []
        for _ in range(n):
            c = r.random()
            if c < 0.6:
                parts.append(str(r.choice(
                    list(range(0, 10)) + list(range(21, 30)) +
                    list(range(30, 50)) + list(range(90, 108)) + [53, 55])))
            elif c < 0.8:
                parts.append('%s;5;%d' % (r.choice(['38', '48', '58']),
                                          r.randrange(256)))
            else:
                parts.append('%s:2::%d:%d:%d' % (
                    r.choice(['38', '48', '58']), r.randrange(256),
                    r.randrange(256), r.randrange(256)))
        out.append(csi(';'.join(parts) + 'm') + text_bits(r))
    out.append(csi('m'))
    return ''.join(out)


def gen_malformed(r):
    out = []
    inner = ['\x18', '\x1a', ESC, ESC + '[', '\x9b', '\x9d', '\x90', '\x9c',
             '\x84', '\x85', '\x88', '\x8d', '\x8e', '\x8f', '\x98', '\x9e',
             '\x9f', '\x80', '\x99', '\n', '\r', BEL, '\b', '\t', '\x0b',
             '\x0c', '\x0e', '\x0f', '\x00', '\x05', '\x10', '\x1f', '\x7f',
             '😀', 'é', '中']
    for c in inner:
        for pre in ['', '?', '1;', '38;2;1', '1:']:
            out.append(csi(pre + c + '2m') + 'A' + csi('m'))
            out.append(csi(pre + c + 'H') + 'B')
        out.append(ESC + c + 'C')
        out.append(OSC + '0;ti' + c + 'tle' + BEL + 'D')
        out.append(ESC + 'P$q' + c + 'm' + ST + 'E')
        out.append(ESC + '(' + c + '0F')
        out.append('\r\n')
    # 8-bit introducers.
    out.append('\x9b1;31mR\x9bm\x9d0;c1title\x07\x9d2;t2\x9c\x90$qm\x9c'
               '\x9b6n\x9b?6n\x84\x85\x88\x8d\x8e\x8f')
    out.append('\x7f\x7f' + csi('1\x7f;2\x7fH') + 'Q')
    out.append(ESC + ESC + ESC + '[1m' + ESC + '\x18' + ESC + '\x1a' + 'z')
    return ''.join(out)


def gen_esc(r):
    seqs = ['(0', '(B', ')0', ')B', '*0', '+0', '(A', '(<', '(%5', '-A', '.A',
            '/A', '7', '8', 'D', 'M', 'E', 'H', '=', '>', '#8', '#3', '#4',
            '#5', '#6', '%G', '%@', 'N', 'O', 'n', 'o', '|', '}', '~', ' F',
            ' G', ' L', '6', '9', 'Z', 'l', 'm', 'V', 'W', '\\', '1', 'k']
    out = []
    for s in seqs:
        out.append(ESC + s + 'lqkx' + '\x0e' + 'lq' + '\x0f' + 'jm\r\n')
    out.append(csi('5;5H') + ESC + '7' + csi('31m') + csi('10;10H') + 'a' +
               ESC + '8' + 'b')
    out.append(ESC + 'c' + 'after-RIS')
    out.append(csi('3;6r') + csi('4;1H') + (ESC + 'M') * 5 + (ESC + 'D') * 7)
    out.append(csi('r'))
    return ''.join(out)


def gen_strings(r):
    out = []
    for term in [BEL, ST]:
        for ps in ['0', '1', '2', '4;1;rgb:12/34/56', '4;1;?', '4;300;?',
                   '10;?', '11;?', '12;?', '10;#123456', '11;rgb:ff/00/00',
                   '104;1', '104', '110', '111', '112', '5;0;?', '105;0',
                   '52;c;aGVsbG8=', '52;c;?', '52;p;?', '52;;Zm9v', '52;c;!!',
                   '7;file://host/tmp/x', '133;A', '133;B', '133;C',
                   '133;D;0', '133;A;aid=1;k=s', '633;A', '633;E;ls',
                   '1337;SetUserVar=a=YmM=', '1337;RemoteHost=u@h',
                   '1337;CurrentDir=/x', '1337;SetBadgeFormat=YQ==',
                   '1337;ReportVariable=Zm9v', '1337;SetMark',
                   '1337;StealFocus', '1337;ShellIntegrationVersion=1',
                   '1337;SetProfile=p', '1337;RequestAttention=yes',
                   '9;hello', '9;4;1;50', '9;4;0', '9;4;3', '777;notify;t;b',
                   '22;pointer', '3008;start=abc;user=u;hostname=h',
                   '3008;end=abc;exit=success', '8;;http://x', '8;id=1;u',
                   '99;?', '1;' + 'L' * 9000, '2;' + 'é' * 100,
                   '0;😀emoji', '9999', ';x', '']:
            out.append(OSC + ps + term + 'o')
        out.append(OSC + '8;id=a;http://e.com/' + term + 'link' + OSC + '8;;' +
                   term + 'nolink')
        out.append(ESC + 'P$qm' + term + ESC + 'P$qr' + term +
                   ESC + 'P+q544e;636f6c73' + term + ESC + 'P=1s' + term +
                   ESC + 'Pq#0;2;0;0;0~~$-' + term + ESC + 'P1;2|x' + term +
                   ESC + 'P' + 'D' * 10000 + term + ESC + '_apc' + term +
                   ESC + '^pm' + term + ESC + 'Xsos' + term + 'S')
        out.append('\r\n')
    out.append(OSC + '0;' + 'T' * 20000 + BEL + 'long')
    return ''.join(out)


def gen_modes(r):
    out = []
    out.append(csi('?1049h') + 'alt' + csi('5;5H') + 'screen' +
               csi('?1049l') + 'main')
    out.append(csi('?47h') + 'a47' + csi('?47l') + csi('?1047h') + 'x' +
               csi('?1047l') + csi('?1048h') + csi('?1048l'))
    out.append(csi('5;20r') + csi('20;1H') + ('line\n' * 30) + csi('r'))
    out.append(csi('?69h') + csi('10;50s') + csi('5;5H') + ('W' * 120) +
               csi('?69l'))
    out.append(csi('?6h') + csi('3;10r') + csi('1;1H') + 'origin' +
               csi('?6l') + csi('r'))
    out.append(csi('4h') + csi('1;1H') + 'insert' + csi('1;1H') + 'II' +
               csi('4l'))
    out.append(csi('?7l') + ('N' * 250) + csi('?7h') + ('Y' * 250))
    out.append(csi('?2026h') + 'sync' + csi('?2026l'))
    out.append(csi('?2004h') + csi('?2004l'))
    for m in [9, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2027,
              12, 25, 1, 5, 66, 67, 1007, 1036, 1039, 2031, 3, 8, 1034, 45]:
        out.append(csi('?%dh' % m) + 'm' + csi('?%dl' % m))
    out.append(csi('?2027l') + '👨‍👩‍👧 é' + csi('?2027h') +
               '👨‍👩‍👧 é')
    out.append(csi('?3h') + csi('?3l') + csi('?1;25;2004s') + csi('?1;25r'))
    out.append(csi('20h') + 'lnm\n' + csi('20l'))
    out.append(csi('2 q') + csi('5 q') + csi('?12h') + csi('>1u') +
               csi('<u') + csi('=5;1u'))
    return ''.join(out)


def gen_replies(r):
    qs = ['5n', '6n', '?6n', '?15n', '?25n', '?26n', '?53n', '?55n', '?56n',
          '?62n', '?63;1n', '?75n', '?85n', '?996n', 'c', '0c', '>c', '>0c',
          '=c', '?25$p', '?1049$p', '?2026$p', '?9999$p', '4$p', '20$p',
          '>q', '>0q', '14t', '16t', '18t', '19t', '11t', '13t', '20t', '21t',
          '22;0t', '22;1t', '22;2t', '23;0t', '23;1t', '8;30;90t', '8;37;100t',
          '4;300;600t', '?u', '>4;1m', '>4m', '?4m', 'x', '1x', '0x', '1$w',
          '2$w', '&w', '"v', '?1$p', '1;1;1;1$y', '3g', '0g', '?5W', 'W',
          '2W', '4i', '5i', '?10n', '?6;2n', '1;5;10;20$x']
    out = []
    for q in qs:
        out.append(csi(q) + 'q')
    out.append('\x05')
    for q in ['m', 'r', 's', ' q', '"q', '"p', 't', '$|', '*|', 'x']:
        out.append(ESC + 'P$q' + q + ST)
    out.append(OSC + '4;1;?' + BEL + OSC + '10;?' + ST + OSC + '11;?' + BEL)
    out.append(csi('10;20H') + csi('6n') + csi('?6h') + csi('5;10r') +
               csi('6n') + csi('?6l') + csi('r'))
    return ''.join(out)


def gen_surrogates(r):
    out = []
    emoji = ['😀', '🚀', '👍🏽', '🇹🇷', '👨‍👩‍👧', '𝐀', '🀄', '\U00010000',
             '\U0010fffd']
    for e in emoji:
        out.append(e + csi('1m') + e + csi('m') + e + ESC + e + csi(e + 'm') +
                   OSC + '0;' + e + BEL + e + ESC + 'P$q' + e + ST + e +
                   csi('3' + e + '1m') + e + '\r\n')
    return ''.join(out)


def gen_lone_surrogates(r):
    units = []

    def add(s):
        units.extend(struct.unpack('<%dH' % (len(s.encode('utf-16-le')) // 2),
                                   s.encode('utf-16-le')))
    for _ in range(200):
        add('ab')
        units.append(r.choice([0xd800, 0xdbff, 0xdc00, 0xdfff, 0xd83d]))
        add(r.choice([csi('1m'), 'x', '😀', ESC, '\n', csi('31'), '']))
        if r.random() < 0.3:
            units.append(0xd83d)
            units.append(0xde00)
        if r.random() < 0.2:
            units.append(0xde00)
            units.append(0xd83d)
    return struct.pack('<%dH' % len(units), *units)


THEMES = [gen_csi_finals, gen_csi_params, gen_sgr, gen_malformed, gen_esc,
          gen_strings, gen_modes, gen_replies, gen_surrogates]


def tokens(r, n):
    """Small tokens from every theme, for the mixed files."""
    sources = [t(random.Random(r.random())) for t in THEMES]
    out = []
    for _ in range(n):
        src = r.choice(sources)
        i = r.randrange(len(src))
        # Cut at an ESC so that most tokens start a sequence.
        j = src.find(ESC, i)
        if j < 0:
            j = i
        out.append(src[j:j + r.randrange(1, 64)])
        if r.random() < 0.5:
            out.append(text_bits(r))
    return ''.join(out)


TRUNC = ['\x1b', '\x1b[', '\x1b[1;2', '\x1b[?', '\x1b[38:2::1', '\x1b]0;tit',
         '\x1b]8;;http', '\x1bP$q', '\x1bPq#0', '\x1b(', '\x1b#', '\x1b ',
         '\x9b', '\x9b12', '\x9d0;x', '\x90', '\x1b_ap', '\x1b[' + '1;' * 200,
         'text\x1b]0;' + 'x' * 9000, '\x1bP' + 'y' * 9000]


def write(path, data):
    mode = 'wb'
    if isinstance(data, str):
        data = data.encode('utf-8', 'surrogatepass')
    with open(path, mode) as f:
        f.write(data)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    out = args[0]
    payloads = None
    mib = 2
    i = 1
    while i < len(args):
        if args[i] == '--payloads':
            payloads = args[i + 1]
            i += 2
        elif args[i] == '--payload-mib':
            mib = float(args[i + 1])
            i += 2
        else:
            sys.exit('unknown argument ' + args[i])
    os.makedirs(out, exist_ok=True)
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))

    caps = os.path.join(repo, 'script/term_compare/paint_spike/captures')
    if os.path.isdir(caps):
        for name in sorted(os.listdir(caps)):
            shutil.copyfile(os.path.join(caps, name),
                            os.path.join(out, 'cap_' + name))
    shutil.copyfile(os.path.join(repo, 'script/cmatrix.txt'),
                    os.path.join(out, 'cap_cmatrix.txt'))
    fixture = os.path.join(repo, 'test/_fixture')
    for name in sorted(os.listdir(fixture)):
        if name.endswith('.txt'):
            shutil.copyfile(os.path.join(fixture, name),
                            os.path.join(out, 'cap_fixture_' + name))

    if payloads:
        for name in ['ascii', 'sgr', 'cursor', 'unicode', 'cjk']:
            with open(os.path.join(payloads, name), 'rb') as f:
                data = f.read(int(mib * 1024 * 1024))
            # End at a line, or before an ESC when there are no lines.
            cut = data.rfind(b'\n') + 1 or data.rfind(b'\x1b')
            data = data[:cut]
            write(os.path.join(out, 'pay_' + name), data)

    for theme in THEMES:
        write(os.path.join(out, theme.__name__ + '.txt'),
              theme(random.Random(theme.__name__)))
    write(os.path.join(out, 'gen_lone_surrogates.u16le'),
          gen_lone_surrogates(random.Random('lone')))
    for k in range(6):
        write(os.path.join(out, 'mix_%d.txt' % k),
              tokens(random.Random('mix%d' % k), 6000))
    for k, t in enumerate(TRUNC):
        write(os.path.join(out, 'trunc_%02d.txt' % k),
              tokens(random.Random('trunc%d' % k), 50) + t)


if __name__ == '__main__':
    main()
