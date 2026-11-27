#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Every deletion in the shipped shell scripts names a target a static reader can verify.

A deletion is an rm, rmdir or mv command - plain, sudo'ed, alias-bypassed (\rm) or by path (/bin/rm, /usr/bin/rm) -
a find with -delete or -exec rm, or an `xargs rm` whose input is the pipe before it; a command continued over lines
(a trailing backslash) is read whole. Its arguments may use a variable only in the guarded form ${VAR:?} (an empty
variable then aborts the script instead of widening the target). ${VAR}, $VAR, ${VAR:-default}, $1 and "$@" in a
deletion's arguments - for xargs rm, in the pipe that feeds it - are findings. Container commands (docker ... rm,
sbx ... rm) and text inside echo/printf/fail/err messages are not deletions.

    tools/check-deletions.py                 # the harness scripts: *.sh here, Container-Root/ (not opt/, the vendored
                                             # trees), tools/; the sandbox kit under to/ has its own tests
    tools/check-deletions.py FILE|DIR ...    # these paths only
    tools/check-deletions.py --self-test     # plants an unguarded rm and a guarded one; exactly the first is a finding

Exit 0 when nothing is found, 1 with one line per finding (file:line: the text).
"""
import os, re, sys, tempfile

CMD = r'(?:\\|/(?:usr/)?(?:local/)?bin/)?'   # the alias-bypassing backslash or a path to the binary
DELETION = re.compile(r'(?:^|(?<=[\s;{(\'"])|(?<=&&)|(?<=\|\|))(?:sudo\s+(?:-n\s+)?)?' + CMD + r'(rm|rmdir|mv)\s+([^;&|\n]*)')
XARGS = re.compile(r'(?:^|(?<=[\s;{(\'"]))xargs\s+((?:-\S+\s+)*)' + CMD + r'(rm|rmdir)\b\s*([^;&|\n]*)')
FIND = re.compile(r'(?:^|(?<=[\s;{(\'"])|(?<=&&)|(?<=\|\|))find\s+([^;&|\n]*?(?:-delete|-exec\s+rm)[^;&|\n]*)')
UNGUARDED = re.compile(r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])(?!:\?)[^}]*\}|([A-Za-z_][A-Za-z0-9_]*)|([0-9@*]))')
NOT_A_DELETION = re.compile(r'(docker|sbx\w*|SBXC|secret|buildx|stack|echo|printf|fail|err|layer|CMD=|BLOCKERS|grep|"[^"]*$|\'[^\']*$)')
SKIP_DIRS = {'.git', 'scratch', 'wd', 'node_modules', 'opt', 'to'}

def segments_before(line, pos):
    # the text of the same shell command that precedes pos (back to the last ; && || or |); a trap body and an
    # inline shell (bash -c '...') are commands, not messages, so their opening quote is not message context
    seg = re.split(r';|&&|\|\||\|', line[:pos])[-1]
    return '' if re.search(r'(^|\s)(trap|-c)\s+[\'"]\s*$', seg) else seg

def logical_lines(text):
    # (first line number, the command) with continued lines - a trailing backslash - joined, as the shell reads them
    out, buf, start = [], '', 0
    for n, line in enumerate(text.split('\n'), 1):
        if not buf:
            start = n
        if line.rstrip().endswith('\\') and not line.lstrip().startswith('#'):
            buf += line.rstrip()[:-1] + ' '
            continue
        out.append((start, buf + line))
        buf = ''
    if buf:
        out.append((start, buf))
    return out


def findings_in(text):
    out = []
    for n, line in logical_lines(text):
        if line.lstrip().startswith('#'):
            continue
        hits = []
        for m in DELETION.finditer(line):
            if NOT_A_DELETION.search(segments_before(line, m.start())):
                continue
            hits.append(m.group(2))
        for m in FIND.finditer(line):
            if NOT_A_DELETION.search(segments_before(line, m.start())):
                continue
            hits.append(m.group(1))
        for m in XARGS.finditer(line):
            # what xargs deletes comes down the pipe: the command feeding it (back to the last ; && or ||, pipes
            # included) is the deletion's argument text, and its message context (an echo of the form) is judged there
            feed = re.split(r';|&&|\|\|', line[:m.start()])[-1]
            if NOT_A_DELETION.search(feed):
                continue
            hits.append(feed + ' ' + m.group(1) + m.group(3))
        for args in hits:
            if UNGUARDED.search(args):
                out.append((n, line.strip()))
                break
    return out

def scan_paths(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                files += [os.path.join(root, f) for f in names if f.endswith('.sh')]
        elif os.path.isfile(p):
            files.append(p)
    found = 0
    for f in sorted(set(files)):
        try:
            text = open(f, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for n, line in findings_in(text):
            print(f'{f}:{n}: {line}')
            found += 1
    return found

PLANTED = 'D=/tmp/x\nrm -rf ${D}/sub\nrm -rf "${D:?}/sub"\nmv "$1" "$1.bak"\nmv "${A:?}" "${B:?}"\n' \
          'docker rm -f ${CONTAINER}\necho "remove it with: rm -rf ${DIR}"\nfind "${DST}.new" -name x -delete\n' \
          'find "${DST:?}.new" -name x -delete\ntrap \'rm -f "${T}"\' EXIT\ntrap \'rm -f "${T:?}"\' EXIT\n' \
          'rm -rf "${D:-/tmp/x}/sub"\n[ -e "$b" ] && mv "${b:?}" "${b:?}.hidden" && H="${H} $b"\nsudo -n rm -rf ${R}/clone\n' \
          'layer secret PASS "secret of ${NAME} removed (rm exit ${src})"\nSBX_T=300 sbx_run ${CLOUD} rm --force "${NAME}"\n' \
          'bash -c \'rm -rf "$1"\' _ x\n{ rm -f "${T}"; echo "cannot install ${X}" >&2; exit 1; }\n' \
          '\\rm -rf ${D}/sub\n\\rm -rf "${D:?}/sub"\n/bin/rm -rf ${D}/sub\n/usr/bin/rm -rf "${D:?}/sub"\n' \
          'rm -rf \\\n\t${D}/sub\nrm -rf \\\n\t"${D:?}/sub"\n' \
          'ls ${D} | xargs rm -rf\nfind "${D:?}" -name x -print0 | xargs -0 rm -f\nls ${D} | xargs -n1 /bin/rm -f\n' \
          'echo "clean with: ls ${D} | xargs rm"\n'
# line numbers of PLANTED: 19 \\rm unguarded, 20 guarded, 21 /bin/rm unguarded, 22 /usr/bin/rm guarded, 23-24 a continued rm
# unguarded (reported at its first line), 25-26 continued guarded, 27 xargs rm fed by an unguarded ls, 28 fed by a guarded
# find, 29 xargs /bin/rm fed unguarded, 30 the form inside a message


def self_test():
    got = [n for n, _ in findings_in(PLANTED)]
    want = [2, 4, 8, 10, 12, 14, 17, 18, 19, 21, 23, 27, 29]
    if got != want:
        print(f'check-deletions self-test FAILED: findings on lines {got}, expected {want}')
        return 1
    print('check-deletions self-test ok: the unguarded rm, mv, find, \\rm, /bin/rm, continued rm and xargs rm are findings; the guarded ones, the container rm and the messages are not')
    return 0

if __name__ == '__main__':
    args = sys.argv[1:]
    if args == ['--self-test']:
        sys.exit(self_test())
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if not args:
        os.chdir(here)
        args = [f for f in os.listdir('.') if f.endswith('.sh')] + ['Container-Root', 'tools']
    n = scan_paths(args)
    if n:
        print(f'check-deletions: {n} deletion(s) use an unguarded variable - write the target literally or guard every variable as ${{VAR:?}}')
        sys.exit(1)
    print('check-deletions: every deletion in the scanned scripts names a literal path or guards its variables')
