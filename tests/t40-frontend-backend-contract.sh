#!/usr/bin/env bash
# Static route/method coverage, plus explicit error branches in the real components.
# No Flask installation, npm packages, network or browser required.
set -uo pipefail
. "${TM_TESTS_DIR:-$(cd "$(dirname "$0")" && pwd)}/lib/harness.sh"
tm_header "Frontend fetches agree with Flask routes and handle backend errors"
contract() {
    node - "$TM_REPO_ROOT" <<'NODE'
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = process.argv[2];
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const backend = read('tm/routes.py');
const settings = process.env.TM_SETTINGS_SOURCE ? fs.readFileSync(process.env.TM_SETTINGS_SOURCE, 'utf8') : read('app/components/SettingsTab.js');
const login = read('app/components/LoginView.js');
const prefix = backend.match(/bp\s*=\s*Blueprint\([^\n]*url_prefix=['"]([^'"]+)['"]/)[1];
const routes = [...backend.matchAll(/^@bp\.route\(\s*(['"])(.*?)\1\s*,\s*methods\s*=\s*\[([^\]]+)\]\s*\)/gm)].map(m => ({
    path: prefix + m[2], methods: [...m[3].matchAll(/['"]([A-Z]+)['"]/g)].map(x => x[1]),
}));
assert.ok(routes.length > 20, 'Flask decorator parser must discover the route table');
assert.equal(routes.length, (backend.match(/^@bp\.route/gm) || []).length, 'every route decorator must be parsed');
const escape = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
for (const r of routes) r.pattern = new RegExp('^' + r.path.split(/(<[^>]+>)/).map(p => p.startsWith('<') ? '[^/]+' : escape(p)).join('') + '$');

// A deliberately restricted static lexer/resolver for these two components.
// Comments and strings cannot invent fetch calls. Every real fetch is visited;
// unsupported URL/options expressions fail closed, rather than being skipped.
function lex(s) {
    const result = [];
    const re = /\s+|\/\/[^\n]*|\/\*[\s\S]*?\*\/|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`|[A-Za-z_$][\w$]*|\d+|\.\.\.|===|!==|=>|\?\.|[^\s]/gy;
    let m, consumed = 0;
    while ((m = re.exec(s))) {
        consumed = re.lastIndex;
        if (!/^\s|^\/\//.test(m[0]) && !m[0].startsWith('/*')) result.push(m[0]);
    }
    assert.equal(consumed, s.length, 'lex complete source');
    return result;
}
function end(t, start) {
    const close = { '(': ')', '[': ']', '{': '}' }[t[start]];
    assert.ok(close, 'expected opening delimiter');
    for (let i = start + 1; i < t.length; i++) {
        if (t[i] === close) return i;
        if ('([{'.includes(t[i]) && t[i].length === 1) i = end(t, i);
    }
    throw Error('Unclosed delimiter');
}
function split(t, separator = ',') {
    const chunks = []; let start = 0;
    for (let i = 0; i < t.length; i++) {
        if (t[i] === separator) { chunks.push(t.slice(start, i)); start = i + 1; }
        else if ('([{'.includes(t[i]) && t[i].length === 1) i = end(t, i);
    }
    chunks.push(t.slice(start)); return chunks;
}
function calls(t, name) {
    const out = [];
    for (let i = 0; i < t.length - 1; i++) if (t[i] === name && t[i + 1] === '(') {
        const stop = end(t, i + 1);
        // Method declarations are not call sites.
        if (t[stop + 1] !== '{') out.push(split(t.slice(i + 2, stop)));
    }
    return out;
}
function literal(t) {
    assert.ok(/^['"]/.test(t), 'expected a string literal: ' + t);
    return vm.runInNewContext(t);
}
function fields(t) {
    assert.equal(t[0], '{', 'unresolved fetch options: ' + t.join(' '));
    assert.equal(end(t, 0), t.length - 1);
    return split(t.slice(1, -1)).filter(x => x.length).map(p => {
        if (p[0] === '...') return ['...', p.slice(1)];
        const key = /^['"]/.test(p[0]) ? literal(p[0]) : p[0];
        return [key, p[1] === ':' ? p.slice(2) : p];
    });
}
let checked = 0;
for (const [label, source] of [['SettingsTab', settings], ['LoginView', login]]) {
    const t = lex(source);
    // The shared request helper is hostApplyRequest(domain, run, url, opts)
    // (v1.2.0 Sonar refactor; it was a closure named request(url, opts)):
    // each call site's url and opts are the 3rd and 4th arguments.
    const requests = calls(t, 'hostApplyRequest').map(a => {
        assert.equal(a.length, 4, label + ': hostApplyRequest takes (domain, run, url, opts)');
        return a.slice(2);
    });
    const applyCalls = calls(t, 'runHostApply').filter(a => a[1]);
    function urls(expr) {
        const s = expr.join('');
        if (expr.length === 1 && /^['"]/.test(expr[0])) return [literal(expr[0])];
        if (expr.length === 1 && expr[0].startsWith('`')) return [expr[0].slice(1, -1).replace(/\$\{[^}]+\}/g, '__value__')];
        if (s === 'url') { assert.ok(requests.length); return requests.flatMap(a => urls(a[0])); }
        if (s === 'paths[panel]') {
            const i = t.findIndex((x, n) => x === 'paths' && t[n + 1] === '=' && t[n + 2] === '{');
            assert.ok(i >= 0, 'panel path map missing');
            return fields(t.slice(i + 2, end(t, i + 2) + 1)).flatMap(([, v]) => urls(v));
        }
        const ternary = split(expr, '?');
        if (ternary.length === 2) return split(ternary[1], ':').flatMap(urls);
        const plus = split(expr, '+');
        if (plus.length === 2 && /^['"]/.test(plus[0][0])) {
            const suffix = plus[1].join('');
            if (suffix === 'domain') return ['syslog', 'time', 'nginx', 'tls'].map(d => literal(plus[0][0]) + d);
            if (/^encodeURIComponent\([\w.]+\)$/.test(suffix)) return [literal(plus[0][0]) + '__value__'];
        }
        throw Error(label + ': unresolved fetch path: ' + s);
    }
    function options(expr, supplied) {
        if (!expr || !expr.length) return [{}];
        if (expr.join('') === 'options') { assert.ok(applyCalls.length); return applyCalls.flatMap(a => options(a[1])); }
        if (expr.join('') === 'opts') { assert.ok(supplied, 'wrapper options need a call site'); return options(supplied); }
        let variants = [{}];
        for (const [key, value] of fields(expr)) {
            if (key === '...') variants = variants.flatMap(v => options(value, supplied).map(x => ({ ...v, ...x })));
            else variants.forEach(v => { v[key] = value; });
        }
        return variants;
    }
    const fetches = calls(t, 'fetch');
    assert.ok(fetches.length, label + ': must inspect fetch calls');
    for (const args of fetches) {
        const sites = args[0].join('') === 'url' ? requests : [args];
        for (const site of sites) for (const opts of options(args[1], site[1])) for (const url of urls(site[0])) {
            const method = opts.method ? literal(opts.method[0]) : 'GET';
            assert.ok(url.startsWith('/api/') && !url.startsWith('//'), 'same-origin API request required: ' + url);
            assert.ok(routes.some(r => r.pattern.test(url) && r.methods.includes(method)), label + ': backend does not serve ' + method + ' ' + url);
            if (opts.credentials) assert.notEqual(literal(opts.credentials[0]), 'omit', 'authenticated fetch must include same-origin cookies');
            if (opts.headers) assert.ok(!fields(opts.headers).some(([key]) => key === 'Sec-Fetch-Site'), 'browser owns Sec-Fetch-Site');
            checked++;
        }
    }
    // Check each mutation's options at its origin (the shared request helper
    // accepts BOTH JSON apply and FormData upload, correlated at the call site).
    const origins = fetches.filter(a => a[0].join('') !== 'url').concat(applyCalls.map(a => [a[0], a[1]]));
    for (const [, expr] of origins) for (const opts of options(expr)) {
        const method = opts.method ? literal(opts.method[0]) : 'GET';
        if (!['POST', 'PUT', 'PATCH'].includes(method)) continue;
        const headers = opts.headers ? Object.fromEntries(fields(opts.headers)) : {};
        if (opts.body?.join('') === 'body') {
            assert.ok(!headers['Content-Type'] && !headers['Content-Length'], 'browser must generate multipart boundary and length');
            assert.match(source, /const body = new FormData\(form\)/);
        } else {
            assert.equal(headers['Content-Type'] && literal(headers['Content-Type'][0]), 'application/json', 'JSON mutation Content-Type');
            assert.ok(opts.body, 'JSON mutation needs a body');
        }
    }
}
assert.match(backend, /request\.headers\.get\('Sec-Fetch-Site'\) == 'cross-site'/);
assert.match(backend, /if not request\.is_json:/);

// Extract actual error/status pairs from the functions that implement (1)-(4),
// including shared guards. Do not count a bare occurrence in a comment as handling.
function pyFunction(name) {
    const m = backend.match(new RegExp('^def ' + name + '\\([^\\n]*\\):\\n([\\s\\S]*?)(?=^def |^@bp\\.route|$(?![\\s\\S]))', 'm'));
    assert.ok(m, 'missing backend function ' + name); return m[1];
}
const errors = [];
for (const name of ['_parse_json_body', '_audit_unavailable', '_audit_failed_after', '_refuse_if_busy', '_start_staged', 'system_apply', 'system_tls_cert']) {
    const code = pyFunction(name);
    for (const m of code.matchAll(/jsonify\(\{([^}]*?)\}\),\s*(\d{3})/g)) {
        const error = m[1].match(/'error':\s*'([^']+)'/);
        if (error) errors.push({ status: Number(m[2]), error: error[1] });
    }
    if (name === '_refuse_if_busy') {
        assert.match(code, /'error': 'apply_throttled'/);
        assert.match(code, /return resp, 429/);
        errors.push({ status: 429, error: 'apply_throttled' });
    }
}
assert.ok(errors.some(e => e.status === 409 && e.error === 'apply_in_progress'), 'backend busy guard extracted');
assert.ok(errors.some(e => e.status === 411) && errors.some(e => e.status === 413) && errors.some(e => e.status === 415), 'upload guards extracted');
const context = { ClusterModal: {} };
vm.createContext(context);
vm.runInContext(settings + '\nglobalThis.component = SettingsTab;', context);
const handler = context.component.methods.hostResponseError;
for (const error of ['audit_unavailable', 'audit_write_failed']) {
    assert.ok(lex(login).join(' ').includes("data . error === '" + error + "'"), 'LoginView missing explicit ' + error);
}
// Explicit handling is asked of the REAL handler, by running it: every backend
// status/error pair must produce its own sentence in at least one context the
// Settings tab calls it with, never one of the generic fallbacks. (The v1.2.0
// Sonar refactor made the handler table-driven, so a token scan of its body
// no longer sees the branches; running it is the stronger check anyway.)
const GENERIC_TLS = 'Certificate upload failed. Check the certificate and key, then try again.';
const answer = (status, parsed, ctx, retryAfter = null) =>
    handler.call({}, { status, headers: { get: h => (h === 'Retry-After' ? retryAfter : null) } }, 'FALLBACK', ctx, parsed);
async function explicit(status, error) {
    for (const ctx of ['save', 'syslog', 'tls']) {
        const parsed = { error, reason: error === 'invalid_cert' ? 'key_mismatch' : 'backend-reason', field: 'backend-field' };
        const text = await answer(status, parsed, ctx);
        // The generic answers: the caller's fallback, the backend's own error
        // or reason echoed back, and the TLS form's catch-all sentence.
        if (![ 'FALLBACK (HTTP ' + status + ').', error, parsed.reason, GENERIC_TLS ].includes(text)) return true;
    }
    return false;
}
const asyncChecks = (async () => {
    for (const { status, error } of errors) {
        // Invalid/empty JSON has a general 400 fallback; callers always serialize
        // JSON. All named contract errors and transport statuses need branches.
        if (error === 'Invalid or empty JSON body') continue;
        assert.ok(await explicit(status, error), 'missing explicit handling for HTTP ' + status + ' ' + error);
    }
    assert.match(await answer(429, { error: 'apply_throttled' }, 'syslog', '7'), /Wait 7 seconds/, 'Retry-After is read');
    assert.match(await answer(429, { error: 'apply_throttled', retry_after: 3 }, 'syslog'), /Wait 3 seconds/, 'retry_after is read');
    assert.equal(await answer(503, { error: 'audit_unavailable' }, 'poll'), vm.runInContext('SETTINGS_STATUS_UNKNOWN', context),
        'a failed poll is always status unknown');
})();
asyncChecks.then(() => console.log('Checked ' + checked + ' resolved fetch path/method combinations against ' + routes.length + ' Flask decorators; ' + errors.length + ' backend error/status pairs handled.'))
    .catch(e => { console.error(e && e.stack || e); process.exit(1); });
NODE
}
c_contract() {
    contract > "${TM_TMP}/contract.out" 2>&1 || _tm_afail "$(cat "${TM_TMP}/contract.out")"
    cat "${TM_TMP}/contract.out"
}
tm_case "frontend-backend-contract" node c_contract
mutation() {
    local kind="$1" diagnostic="$2"
    node - "$TM_REPO_ROOT/app/components/SettingsTab.js" "$TM_TMP/$kind.js" "$kind" <<'NODE'
const fs = require('node:fs');
const [src, dest, kind] = process.argv.slice(2);
const source = fs.readFileSync(src, 'utf8');
const changed = kind === 'fetch-typo'
    ? source.replace("fetch('/api/settings')", "fetch('/api/settingz')")
    : source.replace(/    '409 apply_in_progress': [^\n]+,\n/, '');
if (source === changed) throw Error('Mutation anchor did not match: ' + kind);
fs.writeFileSync(dest, changed);
NODE
    [ "$?" -eq 0 ] || tm_die "could not construct $kind mutation"
    TM_SETTINGS_SOURCE="$TM_TMP/$kind.js" contract > "$TM_TMP/$kind.out" 2>&1 \
        && _tm_afail "contract passed the $kind mutation"
    tm_assert_grep "$diagnostic" "$TM_TMP/$kind.out" "mutation must fail for its intended reason"
}
c_typo() { mutation fetch-typo 'backend does not serve GET /api/settingz'; }
c_busy() { mutation remove-409 'missing explicit handling for HTTP 409 apply_in_progress'; }
tm_case "contract-rejects-fetch-path-typo" node c_typo
tm_case "contract-rejects-missing-409-handler" node c_busy
tm_finish
