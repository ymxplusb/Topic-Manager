"""Parse a pip requirements/lock file the way pip reads it, for the gates.

    python tools/lib/lockparse.py <file>     -> "name<TAB>version<TAB>spec" per requirement

REG-0005/0011 (v1.2.0): the gates matched `^name==version` line by line, so an
INDENTED requirement, a last line without a newline, or a requirement split
over a backslash continuation was silently dropped from the scan. This does
what pip does: joins a line ending in a backslash with the next, drops a
comment that starts a line or follows whitespace, strips surrounding
whitespace and ignores option lines. A requirement that is not an exact
`name==version` is printed with spec set to its operator (the caller refuses
it); exit 3 on a line that is not a requirement at all.
"""
import re
import sys

REQ = re.compile(r'^([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)(\[[^\]]*\])?\s*'
                 r'(===|==|~=|!=|<=|>=|<|>)?\s*([^\s;,]*)\s*(.*)$')


def parse(text):
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    text = re.sub(r'\\\n', ' ', text)           # pip: a trailing backslash joins lines
    out, bad = [], []
    for raw in text.split('\n'):
        line = re.split(r'(?:^|\s)#', raw, 1)[0].strip()
        if not line or line.startswith('-'):
            continue
        m = REQ.match(line)
        if not m:
            bad.append(line)
            continue
        name, _extra, op, ver, rest = m.groups()
        rest = re.sub(r'--hash=\S+', '', rest).strip()
        exact = op == '==' and ver and not any(c in ver for c in '*,') and not rest.startswith((',', '<', '>', '!', '='))
        out.append((name, ver or '', 'exact' if exact else (op or 'unpinned') + (ver or '') + (' ' + rest if rest else '')))
    return out, bad


def main():
    data = open(sys.argv[1], encoding='utf-8').read()
    pins, bad = parse(data)
    for n, v, s in pins:
        print('%s\t%s\t%s' % (n, v, s))
    for b in bad:
        print('BAD\t%s' % b[:120], file=sys.stderr)
    return 3 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
