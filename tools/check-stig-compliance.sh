#!/usr/bin/env bash
# =============================================================================
# check-stig-compliance.sh — the STIG compliance page and its document must be
# ONE answer.
#
# docs/STIG-COMPLIANCE.md is the source of truth (James 2026-10-02, DQ3):
# every rule of the STIG decision board with its decision, status, how it is
# met, how it is verified and its evidence. Settings > Support > STIG
# compliance shows the same rules from tm/compliance.py RULES, with what the
# host measures now. Two copies of one list drift — the PPSM pair did, for
# months — so this gate holds them together field for field: id, title,
# severity, decision, status and live checks, in the same order.
#
# It also asserts the document's own COVERAGE and SHAPE, not just agreement
# (two copies that both lost a rule would agree perfectly):
#   * 75 rules: 32 NGNX-APP and 43 SRG-APP; 64 decided Yes, 8 Other, 3 No;
#   * every rule has Severity, Decision, Status, Live checks, How met, How
#     verified and Evidence; Other, INHERITED and N-A also an AO decision point;
#   * NOT-MET only for a rule decided No, and every rule decided No is NOT-MET;
#   * the Totals table equals the statuses counted;
#   * every live check named is one tm/compliance.py declares, every declared
#     check is used, and each is actually produced by the code that measures
#     it (a host check by install/libexec/tm-apply, an app check by
#     tm/compliance.py);
#   * every repository path cited as evidence exists.
#
# tm/compliance.py is read with the AST, never imported: the gate must run
# where ldap3 and confluent-kafka are not installed.
#
# Exit: 0 agree and complete · 1 disagree or incomplete · 3 could not run.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${STIG_DOC:-${REPO_ROOT}/docs/STIG-COMPLIANCE.md}"
RULES_PY="${STIG_RULES:-${REPO_ROOT}/tm/compliance.py}"
HELPER="${STIG_HELPER:-${REPO_ROOT}/install/libexec/tm-apply}"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "check-stig-compliance: no python found" >&2; exit 3; }
for f in "$DOC" "$RULES_PY" "$HELPER"; do
    [[ -s "$f" ]] || { echo "FAIL: ${f} is missing or empty"; exit 1; }
done

_native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

"$PY" - "$(_native "$DOC")" "$(_native "$RULES_PY")" "$(_native "$HELPER")" "$(_native "$REPO_ROOT")" <<'PYCHK'
import ast, io, os, re, sys

doc_path, rules_path, helper_path, root = sys.argv[1:5]
problems = []

# ── the document ─────────────────────────────────────────────────────────────
FIELDS = ('Severity', 'Decision', 'Status', 'Live checks', 'How met', 'How verified', 'Evidence')
text = io.open(doc_path, encoding='utf-8').read()
heads = list(re.finditer(r'^### (\S+) - (.+)$', text, re.M))
doc_rules = []
for i, m in enumerate(heads):
    end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
    end = min(end, text.find('\n## ', m.end()) if text.find('\n## ', m.end()) > 0 else end)
    body = text[m.end():end]
    fields = dict(re.findall(r'^- \*\*([A-Za-z ]+):\*\* (.*)$', body, re.M))
    rid, title = m.group(1), m.group(2).strip()
    for f in FIELDS:
        if not fields.get(f, '').strip():
            problems.append('%s: no "%s" in the document' % (rid, f))
    checks = tuple(re.findall(r'`([a-z_]+)`', fields.get('Live checks', '')))
    if fields.get('Live checks', '').strip() != 'none' and not checks:
        problems.append('%s: "Live checks" is neither "none" nor a list of `checks`' % rid)
    doc_rules.append({'id': rid, 'title': title, 'sev': fields.get('Severity', ''),
                      'decision': fields.get('Decision', ''), 'status': fields.get('Status', ''),
                      'checks': checks, 'ao': fields.get('AO decision point', '').strip(),
                      'evidence': fields.get('Evidence', '')})

# ── RULES, by the AST ────────────────────────────────────────────────────────
tree = ast.parse(io.open(rules_path, encoding='utf-8').read())
consts = {}
names = {}          # module-level NAME = 'string' (and NAME1, NAME2 = 's1', 's2')
for node in tree.body:
    if not (isinstance(node, ast.Assign) and len(node.targets) == 1):
        continue
    tgt, val = node.targets[0], node.value
    if isinstance(tgt, ast.Name) and isinstance(val, ast.Constant) and isinstance(val.value, str):
        names[tgt.id] = val.value
    elif isinstance(tgt, ast.Tuple) and isinstance(val, ast.Tuple) and len(tgt.elts) == len(val.elts):
        for t, v in zip(tgt.elts, val.elts):
            if isinstance(t, ast.Name) and isinstance(v, ast.Constant) and isinstance(v.value, str):
                names[t.id] = v.value


def value(a):
    if isinstance(a, ast.Name):
        if a.id not in names:
            raise ValueError('RULES names %s, which is not a module string constant' % a.id)
        return names[a.id]
    return ast.literal_eval(a)


rules = None
for node in tree.body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        name = node.targets[0].id
        if name == 'RULES':
            rules = []
            for call in node.value.elts:
                if not (isinstance(call, ast.Call) and getattr(call.func, 'id', '') == 'Rule'):
                    problems.append('RULES holds something that is not a Rule(...) literal')
                    continue
                rid, sev, dec, st, chk, title = [value(a) for a in call.args]
                rules.append({'id': rid, 'sev': sev, 'decision': dec, 'status': st,
                              'checks': tuple(chk), 'title': title})
        elif name in ('HOST_CHECKS', 'APP_CHECKS', 'STATUSES', 'DECISIONS'):
            consts[name] = ast.literal_eval(node.value)
if rules is None:
    print('FAIL: tm/compliance.py has no RULES'); sys.exit(1)
for k in ('HOST_CHECKS', 'APP_CHECKS', 'STATUSES', 'DECISIONS'):
    if k not in consts:
        print('FAIL: tm/compliance.py has no %s literal' % k); sys.exit(1)

# ── coverage and shape ───────────────────────────────────────────────────────
ids = [r['id'] for r in doc_rules]
if len(ids) != len(set(ids)):
    problems.append('the document lists a rule twice: %s' % sorted({i for i in ids if ids.count(i) > 1}))
n_ngx = sum(i.startswith('NGNX-APP-') for i in ids)
n_srg = sum(i.startswith('SRG-APP-') for i in ids)
if (len(ids), n_ngx, n_srg) != (75, 32, 43):
    problems.append('the document has %d rules (%d NGNX-APP, %d SRG-APP); the board has 75 (32, 43)'
                    % (len(ids), n_ngx, n_srg))
dec = {d: sum(r['decision'] == d for r in doc_rules) for d in ('Yes', 'Other', 'No')}
if dec != {'Yes': 64, 'Other': 8, 'No': 3}:
    problems.append('decisions in the document %s; the board decided Yes 64, Other 8, No 3' % dec)
for r in doc_rules:
    if r['status'] not in consts['STATUSES']:
        problems.append('%s: status %r is not one of %s' % (r['id'], r['status'], consts['STATUSES']))
    if r['decision'] not in consts['DECISIONS']:
        problems.append('%s: decision %r is not one of %s' % (r['id'], r['decision'], consts['DECISIONS']))
    if (r['status'] == 'NOT-MET') != (r['decision'] == 'No'):
        problems.append('%s: NOT-MET is for, and only for, a rule decided No (decision %s, status %s)'
                        % (r['id'], r['decision'], r['status']))
    if (r['decision'] == 'Other' or r['status'] in ('INHERITED', 'N-A')) and not r['ao']:
        problems.append('%s: decided %s, status %s, but no "AO decision point"'
                        % (r['id'], r['decision'], r['status']))
    for path in re.findall(r'(?<![\w/])((?:tm|app|install|nginx|tools|tests|systemd|docs)/[\w.-]+(?:/[\w.-]+)*)',
                           r['evidence']):
        path = path.rstrip('.')
        if not os.path.exists(os.path.join(root, path)):
            problems.append('%s: the evidence cites %s, which does not exist' % (r['id'], path))
    if r['id'] not in r['evidence'] and False:
        pass

totals = dict(re.findall(r'^\| (MET|PARTLY|INHERITED|N-A|NOT-MET) \| (\d+) \|$', text, re.M))
for st in consts['STATUSES']:
    got = sum(r['status'] == st for r in doc_rules)
    if int(totals.get(st, -1)) != got:
        problems.append('the Totals table says %s %s; the rules say %d' % (st, totals.get(st, '(absent)'), got))

# ── the two copies agree ─────────────────────────────────────────────────────
keys = ('id', 'title', 'sev', 'decision', 'status', 'checks')
if len(rules) != len(doc_rules):
    problems.append('tm/compliance.py RULES has %d rules, the document %d' % (len(rules), len(doc_rules)))
for i, (a, b) in enumerate(zip(doc_rules, rules)):
    for k in keys:
        if a[k] != b[k]:
            problems.append('rule %d (%s): %s differs - document %r, page %r' % (i + 1, a['id'], k, a[k], b[k]))

# ── every check is declared, used and produced ───────────────────────────────
declared = set(consts['HOST_CHECKS']) | set(consts['APP_CHECKS'])
if set(consts['HOST_CHECKS']) & set(consts['APP_CHECKS']):
    problems.append('a check is declared both host and app: %s'
                    % sorted(set(consts['HOST_CHECKS']) & set(consts['APP_CHECKS'])))
used = {c for r in doc_rules for c in r['checks']}
for c in sorted(used - declared):
    problems.append('the document names the check %s, which tm/compliance.py does not declare' % c)
for c in sorted(declared - used):
    problems.append('tm/compliance.py declares the check %s and no rule uses it' % c)
def produced(path):
    src = io.open(path, encoding='utf-8').read()
    return set(re.findall(r"_check\(\s*'([a-z_]+)'", src))
helper_keys, app_keys = produced(helper_path), produced(rules_path)
for c in consts['HOST_CHECKS']:
    if c not in helper_keys:
        problems.append('host check %s is never produced by %s' % (c, os.path.basename(helper_path)))
for c in consts['APP_CHECKS']:
    if c not in app_keys:
        problems.append('app check %s is never produced by tm/compliance.py' % c)

if problems:
    print('FAIL: docs/STIG-COMPLIANCE.md and the compliance page disagree, or the document is incomplete:')
    for p in problems[:60]:
        print('  - ' + p)
    if len(problems) > 60:
        print('  ... and %d more' % (len(problems) - 60))
    sys.exit(1)
st = {s: sum(r['status'] == s for r in doc_rules) for s in consts['STATUSES']}
print('PASS: %d rules (%d NGNX-APP, %d SRG-APP), document and page agree field for field; %s; '
      '%d live checks (%d host, %d app), each produced by its code'
      % (len(doc_rules), n_ngx, n_srg, ', '.join('%s %d' % kv for kv in st.items()), len(declared),
         len(consts['HOST_CHECKS']), len(consts['APP_CHECKS'])))
PYCHK
