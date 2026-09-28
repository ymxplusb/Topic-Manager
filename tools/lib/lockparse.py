#!/usr/bin/env python3
"""
lockparse.py — THE reader of requirements.lock. Every tool that asks "what
does the lock pin?" asks this module, never a regex of its own.

Round 11 (gatekeeper N1): the lock was read by three sets of rules. The gate
joined backslash continuations and stripped comments the way pip does;
gen-requirements-lock.py --check-set and sca-check.sh matched raw column-0
lines. A comment ending in a backslash hid an entry from pip and the gate
while --check-set still saw it (X20: cffi dropped, gate "PASS"), and an
indented entry pip installs was invisible to --check-set and to SCA (X21:
pip installs pyasn1 0.4.8, SCA reported 0.6.4 CLEAN). There is now one
parser, and it is pip's.

The rules are pip's own (pip._internal.req.req_file, stable since pip 10):
  * text.splitlines(); a line ending in "\\" continues onto the next unless
    it is a comment line; the "\\" characters are stripped and the pieces
    joined with nothing between them; a trailing "\\" on the last line still
    ends the entry;
  * then "#" at the start of a line or after whitespace starts a comment to
    the end of the JOINED line; a "#" glued to a token is not a comment;
  * the line is split on the SPACE character only: the leading tokens up to
    the first one starting with "-" are the requirement, the rest are the
    options. A TAB is not a separator there, so "pkg==1.0<TAB>--hash=..." is
    one malformed requirement to pip, and to this parser.

Accepted: exactly `name==version` followed only by `--hash=sha256:<hex>`
options. Anything else (an option line such as -r or --index-url, extras,
markers, a URL) is an error, never skipped.

Round 12 (gatekeeper B1): pip does not read the lock as UTF-8. It decodes it
by a byte-order mark if there is one, else by a PEP 263-style coding line
("# -*- coding: latin-1 -*-") in the first two lines, else by the locale
(pip._internal.utils.encoding.auto_decode). A latin-1 coding line turns the
UTF-8 bytes of N-cedilla (C5 85) into a NEL line break, and a utf-7 one turns
the ASCII "+AAo-" into a newline: either way pip read an entry this parser saw
inside a comment (N01/N02: pip installed pyasn1 0.4.8, every gate said 0.6.4).
So read() accepts only the one encoding every reader agrees on: pure ASCII
(every byte < 0x80), no byte-order mark, no coding declaration in the first
two lines, no line break but LF (CRLF tolerated) and no control character but
TAB. Anything else is refused before a line is parsed (byte_problems(),
LockEncodingError). Pure ASCII with no coding line is the same text to pip,
to this parser and to grep.

layout_problems() is stricter than pip, on purpose: it refuses a lock whose
physical layout would mislead a reader that looks at column 0
(install/upgrade-full.sh's pin grep, a human): an entry-shaped line pip does
not read as an entry, an indented entry, or an entry whose name==version is
not written whole on its first line (round 12, N04: "pyasn1==0.6\\" then
".4 \\" is 0.6.4 to pip and 0.6 to a column-0 reader). The generator never
writes any of these, and refuses to write a lock that trips them.

    python3 tools/lib/lockparse.py requirements.lock
        prints name==version for every entry pip would read, then
        "#entries <n>". Exit 0; 1 if the lock has any parse error (listed on
        stderr); 2 if it cannot be read or is not plain ASCII (see read()).

Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
"""
import re
import sys

# pip._internal.req.req_file.COMMENT_RE, verbatim.
COMMENT_RE = re.compile(r"(^|\s+)#.*$")
PIN_RE = re.compile(r"^([A-Za-z0-9._-]+)==([A-Za-z0-9.!+_-]+)$")
HASH_RE = re.compile(r"^--hash=sha256:(.*)$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
COL0_PIN_RE = re.compile(r"^[A-Za-z0-9._-]+==")
# PEP 263's coding declaration, as bytes, without the name group (stricter:
# "coding:" with nothing after it is refused too). pip's own test,
# line[0:1] == b"#" and ENCODING_RE.search(line), never matches a line this
# one does not.
CODING_RE = re.compile(rb"^[ \t\f]*#.*?coding[:=]")
# Every byte-order mark pip honours begins with one of these (UTF-32's too).
BOMS = (b"\xef\xbb\xbf", b"\xff\xfe", b"\xfe\xff")
# ASCII bytes str.splitlines() treats as a line break and grep does not.
BREAK_BYTES = b"\r\x0b\x0c\x1c\x1d\x1e"


class LockEncodingError(ValueError):
    """The lock is not the plain ASCII every reader decodes the same way."""
    def __init__(self, problems):
        ValueError.__init__(self, "; ".join(problems))
        self.problems = problems


def norm(name):
    """PEP 503 normalised project name."""
    return re.sub(r"[-_.]+", "-", name).lower()


def byte_problems(raw):
    """Why pip might decode these bytes differently from this parser, or break
    them into lines grep does not. [] for any lock the generator writes."""
    probs = []
    if raw.startswith(BOMS):
        probs.append("requirements.lock starts with a byte-order mark: pip decodes the file by it; "
                     "the lock must be plain ASCII")
    for no, line in enumerate(raw.split(b"\n"), start=1):
        if no <= 2 and CODING_RE.match(line):
            probs.append("requirements.lock line %d: a coding declaration (PEP 263): pip decodes the "
                         "whole file by it; the lock must be plain ASCII with no coding line" % no)
        if line.endswith(b"\r"):
            line = line[:-1]                    # CRLF is tolerated
        for col, b in enumerate(bytearray(line), start=1):
            if b >= 0x80:
                probs.append("requirements.lock line %d col %d: byte 0x%02x is not ASCII: pip decodes "
                             "it by the locale or a coding line, not as UTF-8" % (no, col, b))
                break
            if b in BREAK_BYTES:
                probs.append("requirements.lock line %d: a line break pip honours and grep does not "
                             "(byte 0x%02x)" % (no, b))
                break
            if (b < 0x20 and b != 0x09) or b == 0x7f:
                probs.append("requirements.lock line %d col %d: control character 0x%02x"
                             % (no, col, b))
                break
    return probs


def read(path):
    """The lock's text, exactly as pip decodes it: the bytes must be plain
    ASCII with no BOM and no coding line (byte_problems), else
    LockEncodingError. OSError if the file cannot be read."""
    with open(path, "rb") as f:
        raw = f.read()
    probs = byte_problems(raw)
    if probs:
        raise LockEncodingError(probs)
    return raw.decode("ascii")


def logical_lines(text):
    """pip's join_lines + ignore_comments: yields (first physical line number,
    logical line) for every non-empty logical line."""
    def joined():
        start, buf = None, []
        for no, line in enumerate(text.splitlines(), start=1):
            if not line.endswith("\\") or COMMENT_RE.match(line):
                if COMMENT_RE.match(line):
                    line = " " + line
                if buf:
                    buf.append(line)
                    yield start, "".join(buf)
                    buf = []
                else:
                    yield no, line
            else:
                if not buf:
                    start = no
                buf.append(line.strip("\\"))
        if buf:
            yield start, "".join(buf)
    for no, line in joined():
        line = COMMENT_RE.sub("", line).strip()
        if line:
            yield no, line


def break_args_options(line):
    """pip's break_args_options: split on " " only."""
    tokens = line.split(" ")
    args, options = [], tokens[:]
    for token in tokens:
        if token.startswith("-"):
            break
        args.append(token)
        options.pop(0)
    return " ".join(args), " ".join(options)


def parse(text):
    """-> (entries, errors). entries: one dict per requirement pip would read,
    in order: name (as written), key (normalised), version, hashes, line.
    errors: human-readable problems; a lock with any error is not a lock any
    consumer may trust."""
    entries, errors, seen = [], [], set()
    for no, line in logical_lines(text):
        req, opts = break_args_options(line)
        m = PIN_RE.match(req.strip())
        if not m:
            errors.append("requirements.lock: not an exact pin with hashes: %s" % line[:80])
            continue
        name, ver = m.group(1), m.group(2)
        key = norm(name)
        hashes, bad, other = [], [], []
        for tok in opts.split():
            h = HASH_RE.match(tok)
            if not h:
                other.append(tok)
            elif HEX64_RE.match(h.group(1)):
                hashes.append(h.group(1))
            else:
                bad.append(h.group(1))
        if key in seen:
            errors.append("%s appears twice in requirements.lock" % key)
        seen.add(key)
        if other:
            errors.append("%s==%s has an option that is not --hash=sha256:...: %s" % (key, ver, other[0][:40]))
        if not hashes and not bad:
            errors.append("%s==%s has no --hash" % (key, ver))
        if bad:
            errors.append("%s has a malformed hash: %s" % (key, bad[0][:20]))
        entries.append({"name": name, "key": key, "version": ver,
                        "hashes": hashes + bad, "line": no})
    return entries, errors


def layout_problems(text):
    """Where a column-0 reader of the lock would see something other than
    what pip reads. Stricter than pip; the generator never trips it."""
    probs = []
    starts = {no for no, _ in logical_lines(text)}
    lines = text.splitlines()
    for no, line in enumerate(lines, start=1):
        if COL0_PIN_RE.match(line) and no not in starts:
            probs.append("requirements.lock line %d: looks like an entry but pip does not read it as one "
                         "(a comment or continuation swallows it): %s" % (no, line[:60]))
    entries, _ = parse(text)
    for e in entries:
        first = lines[e["line"] - 1]
        whole = "%s==%s" % (e["name"], e["version"])
        if not COL0_PIN_RE.match(first):
            probs.append("requirements.lock line %d: %s==%s is not at column 0 — pip reads it, "
                         "a column-0 reader does not" % (e["line"], e["key"], e["version"]))
        elif first[:len(whole) + 1] not in (whole, whole + " "):
            probs.append("requirements.lock line %d: %s is not written whole on its first line "
                         "(a continuation splits it); a column-0 reader sees %s"
                         % (e["line"], whole, first.split(" ")[0]))
    return probs


def main(argv):
    if len(argv) != 2:
        print("usage: lockparse.py <requirements.lock>", file=sys.stderr)
        return 2
    try:
        text = read(argv[1])
    except (OSError, LockEncodingError) as e:
        print("lockparse: cannot read %s: %s" % (argv[1], e), file=sys.stderr)
        return 2
    entries, errors = parse(text)
    if errors:
        for e in errors:
            print("lockparse: %s" % e, file=sys.stderr)
        return 1
    for e in entries:
        print("%s==%s" % (e["name"], e["version"]))
    print("#entries %d" % len(entries))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
