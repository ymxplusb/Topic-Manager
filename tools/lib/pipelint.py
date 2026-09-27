"""The parser behind tools/check-pipefail-consumers.sh (REG-0008, v1.2.0).

    python tools/lib/pipelint.py <file>...   -> "file:line: text" per finding; exit 1 if any

Under `set -o pipefail` a consumer that stops reading once it has its answer
lets the producer die of SIGPIPE, and the whole pipeline then reports failure
(or, in an `if`, a false result) depending on pipe timing. This finds every
such consumer at a pipe:

  grep (egrep, fgrep, command grep, \\grep, /usr/bin/grep) with -q/-m/-l/-L or
  --quiet/--silent/--max-count/--files-with(out)-match(es);
  head;  awk whose program calls exit;  sed whose script quits (q/Q).

It works on TOKENS, not on characters: shlex with the shell's quoting and
comment rules, so a "|" inside quotes or a comment is text, not a pipe; lines
joined on a trailing backslash; the inside of every $(...) and `...`
analysed as a command line of its own (even when quoted); heredoc bodies
skipped. The regex it replaces missed `sed -n 1q`, `command grep`, a pipe
continued onto the next line and a quoted "|" before the -q; and it flagged
pipe-shaped text in strings and comments.
"""
import re
import shlex
import sys

GREP = {'grep', 'egrep', 'fgrep', 'rg'}
GREP_LONG = {'--quiet', '--silent', '--max-count', '--files-with-matches', '--files-without-match'}
PREFIXES = {'command', 'builtin', 'exec', 'nice', 'nohup', 'time', 'stdbuf', 'env', 'sudo', 'timeout'}
SED_QUIT = re.compile(r'(^|[;{}\s0-9$/])[qQ](\s*[0-9]+)?\s*(;|}|$)')
AWK_EXIT = re.compile(r'(^|[^A-Za-z0-9_])exit([^A-Za-z0-9_]|$)')
HEREDOC = re.compile(r'(?<!<)<<(-?)\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\2')


def substitutions(text):
    """The bodies of every $( ... ) and ` ... ` in text (outermost first),
    found with a small scanner that respects single quotes. An unclosed
    $( runs to the end of the text."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "'" :
            # single quotes: nothing inside is special (only at top level of
            # the line; inside "$(...)" the scan below handles its own quotes)
            j = text.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '\\':
            i += 2
            continue
        if text.startswith('$(', i) and not text.startswith('$((', i):
            depth, j, q = 1, i + 2, None
            while j < n and depth:
                ch = text[j]
                if q:
                    if ch == q:
                        q = None
                    elif ch == '\\' and q == '"':
                        j += 1
                elif ch in ('"', "'"):
                    q = ch
                elif ch == '\\':
                    j += 1
                elif text.startswith('$(', j):
                    depth += 1
                    j += 1
                elif ch == ')':
                    depth -= 1
                j += 1
            body = text[i + 2:j - 1 if depth == 0 else j]
            out.append(body)
            out.extend(substitutions(body))
            i = j
            continue
        if c == '`':
            j = text.find('`', i + 1)
            body = text[i + 1:n if j < 0 else j]
            out.append(body)
            i = n if j < 0 else j + 1
            continue
        i += 1
    return out


def tokens(text):
    lex = shlex.shlex(text, posix=True, punctuation_chars='|&;()<>')
    lex.whitespace_split = True
    lex.commenters = '#'
    try:
        return list(lex)
    except ValueError:              # an unbalanced quote: take what parses
        return None


def program(cmd):
    """The command a word list runs: assignments and wrappers skipped, a
    leading backslash and a path removed. Returns (name, args)."""
    words = list(cmd)
    while words:
        w = words[0]
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', w):
            words.pop(0); continue
        name = w.lstrip('\\').rsplit('/', 1)[-1]
        if name in PREFIXES:
            words.pop(0)
            while words and words[0].startswith('-'):      # e.g. timeout 5, env -i
                words.pop(0)
            if name == 'timeout' and words and re.match(r'^[0-9.]+[smhd]?$', words[0]):
                words.pop(0)
            continue
        return name, words[1:]
    return None, []


def early_exit(name, args):
    if name in GREP:
        for a in args:
            if a == '--':
                break
            if a.startswith('--'):
                if a.split('=', 1)[0] in GREP_LONG:
                    return True
            elif a.startswith('-') and len(a) > 1 and re.match(r'^-[A-Za-z]*[qmlL]', a):
                return True
        return False
    if name == 'head':
        return True
    if name == 'awk' or name in ('gawk', 'mawk', 'nawk'):
        return any(AWK_EXIT.search(a) for a in args if not a.startswith('-'))
    if name == 'sed':
        scripts, i = [], 0
        while i < len(args):
            a = args[i]
            if a in ('-e', '--expression'):
                if i + 1 < len(args):
                    scripts.append(args[i + 1])
                i += 2; continue
            if a.startswith('-e') and len(a) > 2:
                scripts.append(a[2:])
            elif not a.startswith('-'):
                if not scripts:
                    scripts.append(a)          # the first operand is the script
                break
            i += 1
        return any(SED_QUIT.search(s) for s in scripts)
    return False


def check_command_line(text):
    """True when text holds a pipe into an early-exit consumer."""
    toks = tokens(text)
    if toks is None:
        return False
    cmds, cur, after_pipe = [], [], False
    for t in toks:
        if t in ('|', '|&'):
            cmds.append((cur, after_pipe)); cur, after_pipe = [], True
        elif t and set(t) <= set('|&;()<>') :
            cmds.append((cur, after_pipe)); cur, after_pipe = [], False
            if t in ('<', '>', '<<', '>>', '<<<', '>&', '<&', '&>'):
                cur = ['__redir__']            # the next word is a file, not a command
        else:
            cur.append(t)
    cmds.append((cur, after_pipe))
    for words, piped in cmds:
        if not piped:
            continue
        words = [w for w in words if w != '__redir__']
        name, args = program(words)
        if name and early_exit(name, args):
            return True
    return False


def logical_lines(src):
    """(first physical line number, text): backslash-newline joined, heredoc
    bodies left out."""
    lines = src.replace('\r\n', '\n').split('\n')
    out, i, n = [], 0, len(lines)
    pending = []
    while i < n:
        start = i
        buf = lines[i]
        while buf.endswith('\\') and not buf.endswith('\\\\') and i + 1 < n:
            i += 1
            buf = buf[:-1] + ' ' + lines[i].lstrip()
        out.append((start + 1, buf))
        # A heredoc started here: skip its body (it is data, not shell).
        for m in HEREDOC.finditer(buf):
            pending.append((m.group(3), m.group(1) == '-'))
        i += 1
        while pending and i < n:
            word, dash = pending[0]
            line = lines[i].lstrip('\t') if dash else lines[i]
            i += 1
            if line == word:
                pending.pop(0)
    return out


def check_file(path):
    src = open(path, encoding='utf-8', errors='replace').read()
    hits = []
    for num, text in logical_lines(src):
        if text.lstrip().startswith('#'):
            continue
        pieces = [text] + substitutions(text)
        if any(check_command_line(p) for p in pieces):
            hits.append('%s:%d: %s' % (path, num, text.strip()[:200]))
    return hits


def main(argv):
    hits = []
    for p in argv:
        hits.extend(check_file(p))
    for h in hits:
        print(h)
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
