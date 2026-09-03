#!/usr/bin/env bash
# =============================================================================
# t14 — THE IDLE SESSION ENDS, AND A BACKGROUND POLL CANNOT KEEP IT ALIVE.
#
# James, 2026-09-02: "When session expires, it should automatically log the user
# out. this should be after 15 minutes."
#
# THE DEFECT THIS FILE EXISTS FOR is not the number. TopicsTab and
# ConsumerGroupsTab each auto-refresh every 30 seconds; every refresh was an
# authenticated request, and every authenticated request called
# `touch_session(db, sid, _timeout())`, which pushes `expires_at` a further FULL
# TIMEOUT into the future. So an open tab renewed its own session twice a minute
# for as long as the browser was open, and the server-side timeout could only
# ever expire a tab that was CLOSED. Changing 30 to 15 would not have altered
# that by one second — it would have been a number change that looked like a
# security fix.
#
# So the cases below assert the RULE (a background request does not extend a
# session) and, crucially, case 4 proves the rule can FAIL: with the header
# check removed the session is extended again and case 2 goes red. A test that
# passes whether or not the guard is present is not a test of the guard.
#
# tm/models.py imports nothing outside the standard library, so the session
# cases run on the workstation. The route-level case needs Flask and is skipped
# loudly where it is absent.
#
# Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
# =============================================================================
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"

tm_header "the idle session, and the poll that used to renew it forever"

PY="$(tm_python)"
[ -n "$PY" ] || tm_die "no python found"

# ── 1. ONE definition of the default, and it is 15 ───────────────────────────
case_default_is_fifteen_in_one_place() {
    local src_cfg src_app src_routes
    src_cfg="$(cat "${TM_REPO_ROOT}/tm/config.py")"
    src_app="$(cat "${TM_REPO_ROOT}/tm/app.py")"
    src_routes="$(cat "${TM_REPO_ROOT}/tm/routes.py")"

    printf '%s' "$src_cfg" | grep -qE 'DEFAULT_SESSION_TIMEOUT_MINUTES *= *15' \
        || _tm_afail "tm/config.py does not define DEFAULT_SESSION_TIMEOUT_MINUTES = 15"

    # THE POINT: neither reader may carry its own number. Both used to say 30,
    # independently, so the cookie lifetime and the session row could disagree.
    printf '%s' "$src_app" | grep -q "DEFAULT_SESSION_TIMEOUT_MINUTES" \
        || _tm_afail "tm/app.py does not read the shared default"
    printf '%s' "$src_routes" | grep -q "DEFAULT_SESSION_TIMEOUT_MINUTES" \
        || _tm_afail "tm/routes.py does not read the shared default"

    printf '%s' "$src_app" | grep -qE "timeout_minutes'?, *30" \
        && _tm_afail "tm/app.py still carries its own literal 30"
    printf '%s' "$src_routes" | grep -qE "timeout_minutes'?, *30" \
        && _tm_afail "tm/routes.py still carries its own literal 30"
    tm_note "config.py defines 15; app.py and routes.py both read it"
    return 0
}

# ── 2. A BACKGROUND REQUEST DOES NOT EXTEND THE SESSION ──────────────────────
# Driven through the real require_auth source rather than re-implemented: the
# rule under test is a line in that decorator, and asserting a copy of it would
# pass on a build where the real one was deleted.
case_background_request_does_not_extend() {
    local out
    out="$("$PY" - "$TM_REPO_ROOT" <<'PYEOF'
import ast, io, os, sys
root = sys.argv[1]
src = io.open(os.path.join(root, "tm", "routes.py"), encoding="utf-8").read()
tree = ast.parse(src)

# Find the touch_session call and prove it is GUARDED, by AST rather than by
# grep: a commented-out guard, or one in a docstring, satisfies a text search.
found = []
for node in ast.walk(tree):
    if not isinstance(node, ast.If):
        continue
    test = ast.dump(node.test)
    if "X-TM-Background" not in test:
        continue
    for child in ast.walk(node):
        if (isinstance(child, ast.Call)
                and isinstance(child.func, ast.Name)
                and child.func.id == "touch_session"):
            found.append(node.lineno)

# And that NO touch_session call sits outside such a guard.
guarded_lines = set()
for lineno in found:
    for node in ast.walk(tree):
        if isinstance(node, ast.If) and node.lineno == lineno:
            for child in ast.walk(node):
                if isinstance(child, ast.Call) and getattr(child.func, "id", "") == "touch_session":
                    guarded_lines.add(child.lineno)

all_calls = [n.lineno for n in ast.walk(tree)
             if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "touch_session"]
unguarded = [ln for ln in all_calls if ln not in guarded_lines]

print("guarded=%d unguarded=%d" % (len(guarded_lines), len(unguarded)))
if not guarded_lines:
    print("FAIL: no touch_session call is guarded by the X-TM-Background header")
elif unguarded:
    print("FAIL: touch_session called without the guard at line(s) %s" %
          ",".join(str(x) for x in unguarded))
else:
    print("OK")
PYEOF
)"
    printf '%s\n' "$out" | grep -q '^OK$' \
        || _tm_afail "the session-extension guard is missing or bypassed: ${out}"
    tm_note "$(printf '%s' "$out" | head -1)"
    return 0
}

# ── 3. The rule is REACHABLE: the polls actually send the header ─────────────
# A server-side guard keyed on a header no client sends is a guard that never
# fires. Both auto-refresh call sites must ask for it.
case_the_polls_declare_themselves() {
    local f
    for f in TopicsTab ConsumerGroupsTab; do
        tm_assert_grep "X-TM-Background" "${TM_REPO_ROOT}/app/components/${f}.js" \
            "${f}.js does not send the background header"
        # The 30-second refresh must pass the flag; a person-driven fetch must not.
        grep -qE 'this\.fetch\(true\)' "${TM_REPO_ROOT}/app/components/${f}.js" \
            || _tm_afail "${f}.js auto-refresh does not mark itself as background"
    done
    tm_note "both auto-refresh timers send X-TM-Background: 1"
    return 0
}

# ── 4. THE MUTATION CONTROL ──────────────────────────────────────────────────
# Delete the guard and case 2 must FAIL. Without this, case 2 would pass on a
# tree where the header check had been removed and nobody would learn anything.
case_the_guard_can_fail() {
    local tmp rc
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    cp -r "${TM_REPO_ROOT}/tm" "$tmp/tm"

    # The mutation: un-guard the call, exactly as a careless edit would.
    "$PY" - "$tmp" <<'PYEOF'
import io, os, re, sys
p = os.path.join(sys.argv[1], "tm", "routes.py")
s = io.open(p, encoding="utf-8").read()
s = re.sub(r"if request\.headers\.get\('X-TM-Background'\) != '1':\n\s+touch_session\(db, sid, _timeout\(\)\)",
           "touch_session(db, sid, _timeout())", s)
io.open(p, "w", encoding="utf-8", newline="\n").write(s)
PYEOF

    grep -q "X-TM-Background" "$tmp/tm/routes.py" \
        && _tm_afail "the mutation did not apply — this control proves nothing"

    # RUN THE REAL CHECK, not a copy of it. Case 4 used to re-implement case 2's
    # AST walk against the mutant, which is a control asserting a COPY of the
    # rule: the two could drift, and this would go on passing while the real
    # check rotted. Instead, case 2's own function runs with TM_REPO_ROOT
    # pointed at the mutant, in a subshell because _tm_afail exits.
    ( TM_REPO_ROOT="$tmp" case_background_request_does_not_extend >/dev/null 2>&1 )
    rc=$?
    [ "$rc" -ne 0 ] \
        || _tm_afail "case 2 PASSED against a tree with the guard removed — it is not testing the guard"
    tm_note "guard removed -> the real case-2 check exits ${rc}, so it can fail"
    return 0
}

# ── 5. The logout reason is a CLOSED vocabulary ──────────────────────────────
# The value arrives from the browser and lands in an audit row that any
# authenticated user can export. An attacker-chosen sentence in an audit row is
# a forged record even when it is correctly CSV-escaped.
case_logout_reason_is_not_echoed() {
    local out
    out="$("$PY" - "$TM_REPO_ROOT" <<'PYEOF'
import io, os, re, sys
src = io.open(os.path.join(sys.argv[1], "tm", "routes.py"), encoding="utf-8").read()
m = re.search(r"_LOGOUT_REASONS\s*=\s*\{(.*?)\}", src, re.S)
if not m:
    print("FAIL: no _LOGOUT_REASONS vocabulary"); raise SystemExit
body = m.group(1)
for word in ("'idle'", "'explicit'"):
    if word not in body:
        print("FAIL: %s missing from the vocabulary" % word); raise SystemExit
# The detail must come from the MAP, never from the request value.
if re.search(r"detail\s*=\s*_LOGOUT_REASONS\.get\(", src) is None:
    print("FAIL: the audit detail is not looked up in the vocabulary"); raise SystemExit
if re.search(r"'LOGOUT',\s*\n?\s*request\.remote_addr[^,]*,\s*reason", src):
    print("FAIL: the raw client reason reaches the audit row"); raise SystemExit
print("OK")
PYEOF
)"
    [ "$out" = "OK" ] || _tm_afail "logout reason handling: ${out}"
    tm_note "idle and explicit are distinguished; an unknown reason is not echoed"
    return 0
}

# ── 6. The client arms its clock from the SERVER's number ────────────────────
case_client_reads_the_server_timeout() {
    tm_assert_grep "timeout_minutes" "${TM_REPO_ROOT}/tm/routes.py" \
        "the server does not publish timeout_minutes"
    grep -qE "'user': *session\['user'\], *'timeout_minutes'" "${TM_REPO_ROOT}/tm/routes.py" \
        || _tm_afail "whoami does not carry timeout_minutes — a reloaded tab would guess"
    tm_assert_grep "d.timeout_minutes" "${TM_REPO_ROOT}/app/main.js" \
        "the client does not read the served timeout on reload"
    tm_assert_grep "data.timeout_minutes" "${TM_REPO_ROOT}/app/components/LoginView.js" \
        "the client does not read the served timeout on login"
    tm_note "login and whoami both publish it; the browser reads both"
    return 0
}

# ── 7. Signing out is actually WIRED, not merely defined ─────────────────────
case_idle_expiry_signs_out() {
    local m; m="${TM_REPO_ROOT}/app/main.js"
    tm_assert_grep "logout('idle')" "$m" "the countdown never calls logout"
    tm_assert_grep "armIdleTimer" "$m" "no idle timer is armed"
    grep -qE "ACTIVITY\.forEach\(e => document\.addEventListener" "$m" \
        || _tm_afail "activity never resets the idle timer"
    # The lead matters: without it the sign-out races the server's own expiry
    # and the audit row is lost to a 401.
    tm_assert_grep "LOGOUT_LEAD_MS" "$m" "no lead before the server's expiry"
    tm_note "armed on login and reload, reset on activity, signs out before the server does"
    return 0
}

tm_case "default-is-15-in-one-place"      ""       case_default_is_fifteen_in_one_place
tm_case "background-does-not-extend"      ""       case_background_request_does_not_extend
tm_case "polls-declare-themselves"        ""       case_the_polls_declare_themselves
tm_case "MUTATION-guard-can-fail"         ""       case_the_guard_can_fail
tm_case "logout-reason-closed-vocabulary" ""       case_logout_reason_is_not_echoed
tm_case "client-reads-server-timeout"     ""       case_client_reads_the_server_timeout
tm_case "idle-expiry-signs-out"           ""       case_idle_expiry_signs_out

tm_finish
