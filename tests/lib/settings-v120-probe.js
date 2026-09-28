// Frontend contract tests: execute the shipped component, with deterministic
// fetch and time. No backend, npm, network, or installed browser is required.
'use strict';
const rawAssert = require('node:assert/strict');
let assertions = 0;
const assert = new Proxy(rawAssert, { get(target, key) {
    return (...args) => { target[key](...args); assertions++; };
} });
// Real timer keeps Node alive even when an unresolved promise has no handles.
const watchdog = setTimeout(() => {
    console.error('FAIL: probe watchdog expired before completion');
    process.exit(1);
}, 5000);
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = process.argv[2];
const scenario = process.argv[3];
const source = fs.readFileSync(process.env.TM_SETTINGS_SOURCE || path.join(root, 'app/components/SettingsTab.js'), 'utf8');
// Independent contract fixtures: do not derive expected fields/ranges from code.
const groups = {
    sessions: { session_max_concurrent: '7' },
    rate: { ratelimit_login_per_min: '22', ratelimit_login_burst: '8', ratelimit_api_per_min: '450', ratelimit_api_burst: '140', ratelimit_conn_per_ip: '30' },
    redirect: { http_redirect_enabled: 'false' },
    syslog: { syslog_enabled: 'true', syslog_host: 'logs.example.org', syslog_port: '10514', syslog_protocol: 'udp', syslog_app_id: 'tm.audit-2' },
    retention: { audit_retention_days: '730', audit_max_rows: '123456', audit_warn_pct: '88' },
    time: { ntp_servers: 'time.example.org,2001:db8::1' },
};
const loaded = { ...Object.assign({}, ...Object.values(groups)), banner_text: 'CONTROLLED', banner_bg: 'red', banner_fg: 'white', banner_enabled: 'true', dow_enabled: 'true' };
const capacity = { rows: 80000, max_rows: 100000, oldest: null, retention_days: 365, pct: 80, warn_pct: 75, warning: true, last_prune: null };
const time = { source: 'chrony', servers: ['time.example.org'], synced: true, offset_ms: 0, stratum: 3, last_sync: null };
const tls = { protocols: ['TLSv1.2', 'TLSv1.3'], ciphers: ['TEST-CIPHER'], fips_mode: true, cert: { subject: 'example.org', issuer: 'Example CA', not_after: '2027-01-01', key_type: 'EC P-256', sans: ['example.org'] }, chain_present: true };
const json = (data, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => data });
const plain = object => JSON.parse(JSON.stringify(object));
let uploadBodies = [];
let calls = [], csv = '', now = 0, nextId = 0;
const timers = new Map();
let handler = url => json(url === '/api/settings' ? loaded : url === '/api/audit/capacity' ? capacity : url === '/api/system/time' ? time : url === '/api/system/tls' ? tls : { state: 'idle', message: '', details: [] });
const sandbox = {
    ClusterModal: {}, console, AbortController,
    fetch: async (url, options = {}) => {
        calls.push({ url, options: options.body?.fields
            ? { ...options, body: { fields: { ...options.body.fields } } } : options, at: now });
        if (options.body?.fields) uploadBodies.push(options.body);
        return handler(url, options);
    },
    setTimeout(fn, ms) { const id = ++nextId; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimeout(id) { timers.delete(id); },
    Date: class extends Date { static now() { return now; } },
    document: { getElementById: () => null, body: { style: {} }, createElement: () => ({ click() {} }) },
    URL: { createObjectURL: () => 'blob:stub' },
    Blob: function (parts) { csv = parts.join(''); },
    FormData: class {
        constructor(form) { this.fields = { ...form.fields }; }
        get(key) { return this.fields[key]; }
        delete(key) { delete this.fields[key]; }
    },
};
vm.createContext(sandbox);
vm.runInContext(source + '\nglobalThis.S = SettingsTab;', sandbox);
const S = sandbox.S;
function instance() {
    const inst = S.data();
    for (const [key, method] of Object.entries(S.methods)) inst[key] = method.bind(inst);
    for (const [key, get] of Object.entries(S.computed)) Object.defineProperty(inst, key, { get: get.bind(inst) });
    inst.$emit = () => {};
    return inst;
}
async function flush() { for (let i = 0; i < 25; i++) await Promise.resolve(); }
async function tick() {
    await flush();
    const next = [...timers.entries()].sort((a, b) => a[1].at - b[1].at)[0];
    rawAssert.ok(next, 'an unfinished operation must schedule a timer');
    timers.delete(next[0]); now = next[1].at; next[1].fn();
    await flush();
}
async function finish(promise) {
    let done = false, error;
    promise.then(() => { done = true; }, e => { done = true; error = e; });
    await flush();
    for (let i = 0; !done && i < 100; i++) await tick();
    rawAssert.ok(done, 'operation must finish by its deadline');
    if (error) throw error;
    rawAssert.equal(timers.size, 0, 'operation must clean up timers');
}
async function ready() {
    const inst = instance();
    await inst.loadSettings();
    for (const job of Object.values(inst.applyJobs)) job.uncertain = false;
    calls = [];
    return inst;
}
async function main() {
    if (scenario === 'bindings') {
        const inst = await ready();
        assert.deepEqual(plain(inst.hostSettings), Object.assign({}, ...Object.values(groups)));
        assert.deepEqual(plain(inst.railGroups.find(g => g.id === 'security').sections), ['Sessions', 'Rate limiting', 'HTTP redirect', 'TLS & certificate']);
        assert.deepEqual(plain(inst.railGroups.find(g => g.id === 'logging').sections), ['Remote syslog', 'Audit retention']);
        for (const [section, values] of Object.entries(groups)) {
            const form = S.template.match(new RegExp('<form @submit.prevent="saveHostSection\\(\'' + section + '\'\\)">([\\s\\S]*?)</form>'));
            assert.ok(form, section + ' must have a Save form');
            assert.match(form[1], /<fieldset :disabled="!settingsLoaded \|\| sectionSaving\./);
            for (const [key, value] of Object.entries(values)) {
                // Drive the real binding expression from the labelled input. A
                // wrong v-model changes the wrong property, and the PUT fails.
                const control = form[1].match(new RegExp('<(?:input|select)\\b[^>]*id="' + key + '"[^>]*>'));
                assert.ok(control, 'missing labelled control ' + key);
                const model = control[0].match(/v-model="([^"]+)"/);
                assert.ok(model, 'missing binding ' + key);
                assert.equal(model[1], 'hostSettings.' + key, key + ' binding');
                inst.hostSettings[key] = 'deliberately different';
                vm.runInNewContext('inst.' + model[1] + ' = value', { inst, value });
            }
            await inst.saveHostSection(section);
            const put = calls.filter(c => c.options.method === 'PUT').at(-1);
            assert.ok(put, section + ' sends a PUT');
            assert.deepEqual(JSON.parse(put.options.body), values, section + ' saves only its keys');
            assert.equal(put.options.headers['Content-Type'], 'application/json');
            assert.match(inst.sectionMessages[section], /✓ Saved/);
        }
        for (const [query, group] of [['NTP servers', 'system'], ['time source', 'system'], ['rate limiting', 'security'], ['audit retention', 'logging']]) {
            inst.railQuery = query;
            assert.ok(inst.railGroups.filter(g => inst.railMatch(g)).some(g => g.id === group));
        }
        assert.doesNotMatch(S.template, /v-html|<script/);
        assert.equal((S.template.match(/ref="certForm"/g) || []).length, 1);
    } else if (scenario === 'validation') {
        const inst = await ready();
        const ranges = { syslog_port: [1,65535], session_max_concurrent: [0,50], ratelimit_login_per_min: [1,600], ratelimit_login_burst: [0,100], ratelimit_api_per_min: [10,6000], ratelimit_api_burst: [0,1000], ratelimit_conn_per_ip: [1,500], audit_retention_days: [30,3650], audit_max_rows: [10000,50000000], audit_warn_pct: [50,95] };
        for (const [key, [min,max]] of Object.entries(ranges)) {
            for (const value of [String(min-1), String(max+1), '1.5', '', 'Infinity', '1e2', 'text']) {
                calls = [];
                assert.equal(await inst.saveSettings({ [key]: value }), false, key + ' rejects ' + value);
                assert.equal(calls.length, 0, 'invalid values never reach the server');
                assert.match(inst.settingsSaveError, new RegExp(key));
            }
            for (const value of [String(min), String(max)]) assert.equal(await inst.saveSettings({ [key]: value }), true, key + ' accepts boundary ' + value);
        }
        for (const key of ['syslog_enabled', 'http_redirect_enabled']) {
            assert.equal(await inst.saveSettings({ [key]: 'yes' }), false);
            for (const value of ['true', 'false']) assert.equal(await inst.saveSettings({ [key]: value }), true);
        }
        for (const value of ['udp','tcp','tls']) assert.equal(await inst.saveSettings({ syslog_protocol: value }), true);
        assert.equal(await inst.saveSettings({ syslog_protocol: 'https' }), false);
        for (const value of ['', 'a'.repeat(49), 'bad id', 'bad@id']) assert.equal(await inst.saveSettings({ syslog_app_id: value }), false);
        for (const value of ['a'.repeat(48), 'A.b_c-d']) assert.equal(await inst.saveSettings({ syslog_app_id: value }), true);
        for (const value of ['logs.example.org', '192.0.2.1', '::1', '2001:db8::1', '::ffff:192.0.2.1', 'a'.repeat(253)]) assert.equal(await inst.saveSettings({ syslog_enabled: 'true', syslog_host: value }), true, value);
        for (const value of ['', 'a'.repeat(254), 'host/path', '[::1]', '1:2:3', '2001:::1', '::ffff:999.0.0.1']) assert.equal(await inst.saveSettings({ syslog_enabled: 'true', syslog_host: value }), false, value);
        assert.equal(await inst.saveSettings({ syslog_enabled: 'false', syslog_host: '' }), true, 'fresh disabled default');
        for (const value of ['', 'time.example.org', 'time.example.org, ::1', Array(5).fill('time.example.org').join(',')]) assert.equal(await inst.saveSettings({ ntp_servers: value }), true, value);
        for (const value of [' ', ',', 'time.example.org,', Array(6).fill('time.example.org').join(','), 'https://time.example.org']) assert.equal(await inst.saveSettings({ ntp_servers: value }), false, value);
    } else if (scenario === 'errors') {
        const inst = instance();
        handler = () => json({}, 401);
        await inst.loadSettings();
        await inst.saveHostSection('sessions');
        await inst.applyToHost('syslog');
        assert.equal(inst.settingsLoaded, false);
        assert.equal(calls.filter(c => ['PUT','POST'].includes(c.options.method)).length, 0);
        handler = () => json(loaded);
        await inst.loadSettings();
        handler = () => json({ error: 'invalid', field: 'session_max_concurrent', reason: 'too many sessions' }, 400);
        inst.hostSettings.session_max_concurrent = '8';
        await inst.saveHostSection('sessions');
        assert.match(inst.sectionMessages.sessions, /session_max_concurrent: too many sessions/);
        assert.equal(inst.savedHostSettings.session_max_concurrent, '7', 'failed saves do not change saved export data');
        handler = () => json({ error: 'audit_unavailable' }, 503);
        await inst.saveHostSection('sessions');
        assert.match(inst.sectionMessages.sessions, /Audit logging is unavailable.*action was blocked/);
        inst.applyJobs.nginx.uncertain = false;
        await finish(inst.applyToHost('nginx'));
        assert.match(inst.applyJobs.nginx.message, /Audit logging is unavailable.*nothing was changed/);
        for (const failure of ['audit', 'network']) {
            handler = (url, options) => {
                if (options.method === 'POST') return json({ state: 'queued' }, 202);
                if (failure === 'network') throw new Error('offline');
                return json({ error: 'audit_unavailable' }, 503);
            };
            await finish(inst.applyToHost('nginx'));
            assert.equal(inst.applyJobs.nginx.message, 'Status unknown — the host may or may not have applied the change. Check again.');
            assert.equal(inst.applyJobs.nginx.uncertain, true);
            assert.equal(inst.applyJobs.nginx.state, 'unknown');
            inst.applyJobs.nginx.uncertain = false;
        }
        handler = () => { throw new Error('offline'); };
        await inst.saveHostSection('sessions');
        assert.match(inst.sectionMessages.sessions, /could not be reached/);
        await inst.loadSettings();
        assert.equal(inst.settingsLoaded, false, 'failed reload closes save gate');
    } else if (scenario === 'apply') {
        for (const domain of ['syslog','time','nginx']) {
            const inst = await ready();
            let count = 0;
            handler = (url, options) => {
                if (options.method === 'POST') return json({ domain, job: 'job1', state: 'queued' }, 202);
                if (url.endsWith('/apply/' + domain)) {
                    count++;
                    return json({ domain, state: count === 1 ? 'running' : 'ok', message: count === 1 ? 'Testing' : 'Applied', details: ['Validated', 'Reloaded'] });
                }
                return json(domain === 'time' ? time : {});
            };
            inst.sectionSaving[domain === 'nginx' ? 'rate' : domain] = true;
            await inst.applyToHost(domain);
            assert.equal(calls.length, 0, 'apply waits for the pending save');
            inst.sectionSaving[domain === 'nginx' ? 'rate' : domain] = false;
            const pending = inst.applyToHost(domain);
            assert.equal(inst.applyJobs[domain].busy, true);
            const duplicate = inst.applyToHost(domain);
            assert.equal(calls.filter(c => c.options.method === 'POST').length, 1, 'double apply is blocked while POST is pending');
            await finish(Promise.all([pending, duplicate]));
            const posts = calls.filter(c => c.options.method === 'POST');
            assert.equal(posts.length, 1, 'double apply is blocked');
            assert.equal(posts[0].url, '/api/system/apply/' + domain);
            assert.equal(posts[0].options.body, '{}');
            assert.equal(posts[0].options.headers?.['Content-Type'], 'application/json', 'Apply POST must declare JSON');
            const polls = calls.filter(c => !c.options.method && c.url.endsWith('/apply/' + domain));
            assert.deepEqual(polls.map(c => c.at - posts[0].at), [2000, 4000]);
            assert.ok(polls.every(c => c.options.headers['X-TM-Background'] === '1'));
            assert.equal(inst.applyJobs[domain].busy, false);
            assert.equal(inst.applyJobs[domain].state, 'ok');
            assert.equal(inst.applyJobs[domain].message, 'Applied');
            assert.deepEqual(plain(inst.applyJobs[domain].details), ['Validated','Reloaded']);
        }
        for (const state of ['failed', 'rolled_back']) {
            const inst = await ready();
            handler = (url, options) => json(options.method ? { state: 'queued' } : { state, message: 'Validation failed', details: ['Original config restored'] });
            await finish(inst.applyToHost('syslog'));
            assert.equal(inst.applyJobs.syslog.state, state);
            assert.equal(inst.statusGlyph(state), '✕');
            assert.equal(inst.applyJobs.syslog.busy, false);
        }
    } else if (scenario === 'timeout') {
        for (const hung of [false, true]) {
            const inst = await ready();
            handler = () => hung ? new Promise(() => {}) : json({ state: 'running', message: 'Still running', details: [] });
            const started = now;
            await finish(inst.applyToHost('syslog'));
            assert.equal(now - started, 90000);
            assert.equal(inst.applyJobs.syslog.busy, false);
            assert.equal(inst.applyJobs.syslog.uncertain, true);
            assert.match(inst.applyJobs.syslog.message, /90 seconds.*unknown/);
            const n = calls.length;
            await inst.applyToHost('syslog');
            assert.equal(calls.length, n, 'unknown outcomes require status check before retry');
            handler = () => json({ state: 'ok', message: 'Applied', details: [] });
            await finish(inst.runHostApply('syslog'));
            assert.equal(inst.applyJobs.syslog.uncertain, false);
        }
        const inst = await ready();
        handler = () => new Promise(() => {});
        const pending = inst.runHostApply('nginx');
        await flush();
        S.beforeUnmount.call(inst);
        await finish(pending);
        const n = calls.length;
        await inst.applyToHost('nginx');
        assert.equal(calls.length, n, 'no fetch after unmount');
    } else if (scenario === 'panels') {
        const inst = instance();
        S.mounted.call(inst);
        await flush();
        assert.deepEqual(plain(inst.hostPanels), { capacity, time, tls });
        assert.equal(inst.hostPanels.capacity.warning, true);
        assert.ok(calls.some(c => c.url === '/api/audit/capacity'));
        assert.match(S.template, /v-if="hostPanels.capacity\?\.warning" class="host-audit-banner" role="alert"/);
        assert.match(S.template, /role="progressbar"[^>]*:aria-valuenow=/);
        for (const key of ['source', 'servers', 'synced', 'offset_ms', 'stratum', 'last_sync']) assert.ok(S.template.includes('hostPanels.time.' + key), 'time panel shows ' + key);
        for (const key of ['protocols', 'ciphers', 'fips_mode', 'chain_present']) assert.ok(S.template.includes('hostPanels.tls.' + key), 'TLS panel shows ' + key);
        for (const key of ['subject', 'issuer', 'not_after', 'key_type', 'sans']) assert.ok(S.template.includes('hostPanels.tls.cert?.' + key), 'TLS cert shows ' + key);
        handler = () => json({}, 500);
        await inst.loadHostPanel('capacity');
        assert.match(inst.hostPanelErrors.capacity, /HTTP 500/);
        assert.equal(inst.hostPanels.capacity.warning, true, 'failed refresh does not falsely clear warning');
        for (const state of ['idle','queued','running','unknown']) assert.equal(inst.statusGlyph(state), '!');
        assert.equal(inst.statusGlyph('ok'), '✓');
        S.beforeUnmount.call(inst);
    } else if (scenario === 'tls') {
        for (const failure of [null, 'no-chain', 'invalid_cert', 'audit_unavailable', 'network', 'pem', 'unknown', 'proto']) {
            const inst = await ready();
            let resets = 0;
            const canary = 'PRIVATE_CANARY_92817';
            const pem = '-----BEGIN PRIVATE KEY-----\n' + canary + '\n-----END PRIVATE KEY-----';
            inst.$refs = { certForm: { fields: { cert: { name: 'cert.pem' }, key: { name: 'secret.key', contents: pem }, chain: { name: 'chain.pem' } }, reset() { resets++; this.fields = {}; } } };
            if (failure === 'no-chain') inst.$refs.certForm.fields.chain.name = '';
            handler = (url, options) => {
                if (options.method === 'POST') {
                    if (failure === 'network') throw new Error(pem);
                    if (failure && failure !== 'no-chain') return json({ error: failure === 'audit_unavailable' ? failure : 'invalid_cert', reason: failure === 'invalid_cert' ? 'key_mismatch' : failure === 'pem' ? pem : failure === 'unknown' ? 'UNTRUSTED error text' : failure === 'proto' ? 'constructor' : '' }, failure === 'audit_unavailable' ? 503 : 400);
                    return json({ state: 'queued', domain: 'tls', job: 'cert1' }, 202);
                }
                return json(url === '/api/system/tls' ? tls : { state: 'ok', message: 'Certificate installed', details: ['Verified'] });
            };
            const pending = inst.submitCertificate();
            assert.equal(resets, 1, 'clear inputs immediately even before response');
            const data = Object.fromEntries(Object.keys(S.data()).map(key => [key, inst[key]]));
            assert.ok(!JSON.stringify(data).includes('secret.key'), 'key must never enter component data');
            await finish(pending);
            const request = calls.find(c => c.options.method === 'POST');
            assert.equal(request.url, '/api/system/tls/cert');
            assert.deepEqual(Object.keys(request.options.body.fields), failure === 'no-chain' ? ['cert','key'] : ['cert','key','chain']);
            assert.equal(request.options.headers, undefined, 'browser must set multipart boundary');
            assert.ok(!calls.some(c => c.url === '/api/system/apply/tls' && c.options.method === 'POST'));
            if (failure === 'invalid_cert') assert.match(inst.applyJobs.tls.message, /Certificate does not match key/);
            if (failure === 'audit_unavailable') assert.match(inst.applyJobs.tls.message, /Audit logging is unavailable/);
            if (!failure || failure === 'no-chain') assert.equal(inst.applyJobs.tls.state, 'ok');
            assert.equal(inst.applyJobs.tls.busy, false);
            assert.ok(!JSON.stringify(inst).includes(canary), 'PEM canary must be absent from all component state');
            assert.deepEqual(Object.keys(uploadBodies.at(-1).fields), [], 'release multipart file references after submit');
            assert.ok(!inst.applyJobs.tls.message.includes('UNTRUSTED'));
            // 'proto': a reason that names an Object.prototype member is not a known reason (S6653 lookup).
            if (failure === 'pem' || failure === 'unknown' || failure === 'proto') assert.equal(inst.applyJobs.tls.message, 'Certificate upload failed. Check the certificate and key, then try again.');
        }
        // Every domain filters hostile status message/details before storing them.
        for (const domain of ['syslog', 'time', 'nginx', 'tls']) {
            const inst = await ready();
            for (const secret of ['-----BEGIN PRIVATE KEY-----CANARY', 'A'.repeat(65)]) {
                handler = () => json({ state: 'ok', message: secret, details: ['Safe detail', secret] });
                await finish(inst.runHostApply(domain));
                assert.equal(inst.applyJobs[domain].message, '');
                assert.deepEqual(plain(inst.applyJobs[domain].details), ['Safe detail']);
            }
        }
    } else if (scenario === 'integration') {
        const inst = await ready();
        assert.equal(Object.keys(loaded).length, 21, 'full GET fixture');
        const normalized = { ...loaded, syslog_protocol: 'udp', ntp_servers: 'a.example.org,b.example.org', session_max_concurrent: '8' };
        handler = (url, opts) => opts.method === 'PUT' ? json({ ok: true, changed: ['syslog_protocol', 'ntp_servers', 'session_max_concurrent'] }) : json(normalized);
        inst.hostSettings.syslog_protocol = 'UDP';
        assert.equal(await inst.saveSettings({ syslog_protocol: 'UDP', ntp_servers: 'a.example.org, b.example.org', session_max_concurrent: '08' }), true);
        assert.deepEqual(calls.map(c => [c.url, c.options.method || 'GET']), [['/api/settings', 'PUT'], ['/api/settings', 'GET']]);
        for (const key of ['syslog_protocol', 'ntp_servers', 'session_max_concurrent']) {
            assert.equal(inst.hostSettings[key], normalized[key]);
            assert.equal(inst.savedHostSettings[key], normalized[key]);
        }
        handler = (url, opts) => json({}, opts.method === 'PUT' ? 200 : 503);
        assert.equal(await inst.saveSettings({ session_max_concurrent: '9' }), false);
        assert.equal(inst.settingsLoaded, false);
        assert.match(inst.settingsSaveError, /were saved.*could not be reloaded/);
        handler = () => json(loaded);
        await inst.loadSettings();
        const failures = [
            [400, 'invalid', /syslog_host: host required/, false],
            [404, 'unknown_domain', /not supported.*TLS/, false],
            [409, 'apply_in_progress', /already queued or running.*Check status/, true],
            [429, 'apply_throttled', /Wait 3 seconds/, false],
            [502, 'apply_unit_failed', /service could not start/, false],
            [503, 'audit_unavailable', /blocked; nothing was changed/, false],
            [500, 'audit_write_failed', /change WAS made.*audit record/, true],
            [415, 'Content-Type must be application/json', /requires Content-Type: application\/json/, false],
        ];
        for (const [status, error, message, uncertain] of failures) {
            for (const domain of ['syslog', 'tls']) {
                if (domain === 'tls' && [400, 404, 415].includes(status)) continue;
                inst.applyJobs[domain].uncertain = false;
                calls = [];
                handler = () => ({ ...json({ error, field: 'syslog_host', reason: 'host required', retry_after: 5 }, status), headers: { get: key => key === 'Retry-After' ? '3' : null } });
                const opts = domain === 'tls' ? { method: 'POST', body: new sandbox.FormData({ fields: {} }) } : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' };
                await finish(inst.runHostApply(domain, opts));
                assert.match(inst.applyJobs[domain].message, message);
                assert.equal(inst.applyJobs[domain].uncertain, uncertain);
                assert.equal(calls.length, 1, 'refused POST never automatically retried');
            }
        }
        for (const [status, pattern] of [[411, /requires Content-Length/], [413, /200 KiB.*multipart framing/], [415, /requires multipart\/form-data/]]) {
            inst.applyJobs.tls.uncertain = false;
            handler = () => json({ error: 'invalid_cert', reason: '-----BEGIN PRIVATE KEY-----DO_NOT_ECHO' }, status);
            await finish(inst.runHostApply('tls', { method: 'POST', body: new sandbox.FormData({ fields: {} }) }));
            assert.match(inst.applyJobs.tls.message, pattern);
            assert.equal(inst.applyJobs.tls.uncertain, false);
            assert.ok(!JSON.stringify(inst).includes('DO_NOT_ECHO'));
        }
        const summary = { subject: 'example.org', issuer: 'Example CA', not_after: '2027-01-01', key_type: 'EC P-256', chain_count: 2 };
        handler = url => json(url === '/api/system/tls' ? tls : { state: 'ok', job: 'job42', applied: { ...summary, key: 'NEVER_STORE_KEY' }, applied_at: '2026-09-27' });
        await finish(inst.runHostApply('tls'));
        assert.equal(inst.applyJobs.tls.job, 'job42');
        assert.deepEqual(plain(inst.applyJobs.tls.applied), summary);
        assert.equal(inst.applyJobs.tls.applied_at, '2026-09-27');
        assert.ok(!JSON.stringify(inst).includes('NEVER_STORE_KEY'));
        for (const field of Object.keys(summary)) assert.ok(S.template.includes('applyJobs.tls.applied.' + field));
        for (const domain of ['syslog', 'time', 'nginx', 'tls']) assert.ok(S.template.includes('applyJobs.' + domain + '.job'));
        // Every Settings mutation uses the same distinct audit messages.
        for (const [status, error, message] of [[503, 'audit_unavailable', /nothing was changed/], [500, 'audit_write_failed', /change WAS made/]]) {
            handler = () => json({ error }, status);
            await inst.saveSettings({ session_max_concurrent: '8' });
            assert.match(inst.settingsSaveError, message);
            await inst.deleteCluster({ id: 'example' });
            assert.match(inst.clusterError, message);
            await inst.restartService();
            assert.match(inst.restartMessage, message);
        }
        sandbox.window = { location: { hostname: 'example.org' } };
        vm.runInContext(fs.readFileSync(path.join(root, 'app/components/LoginView.js'), 'utf8') + '\nglobalThis.L = LoginView;', sandbox);
        for (const [status, error, pattern] of [[503, 'audit_unavailable', /Sign-in was blocked.*No sign-in session was issued/], [500, 'audit_write_failed', /sign-in change WAS made.*audit record/]]) {
            const login = { ...sandbox.L.data(), username: 'test', password: 'test', $emit() { throw Error('failed login must not emit success'); } };
            handler = () => json({ error }, status);
            await sandbox.L.methods.doLogin.call(login);
            assert.match(login.error, pattern);
            assert.equal(login.loading, false);
        }
    } else if (scenario === 'ppsm') {
        const inst = await ready();
        const applied = {
            syslog: { ...groups.syslog, syslog_port: '20514', syslog_protocol: 'tcp' },
            nginx: { http_redirect_enabled: 'true' }, time: { ntp_servers: 'live.example.org' },
        };
        handler = url => json({ applied: applied[url.split('/').at(-1)] });
        inst.hostSettings.syslog_port = '9999';
        await finish(inst.downloadPpsm());
        assert.match(csv, /"Logging","Syslog","20514","TCP","Outbound","Enabled; applied protocol: tcp/);
        assert.match(csv, /Enabled by applied http_redirect_enabled/);
        assert.match(csv, /Applied NTP servers: live.example.org/);
        assert.ok(!csv.includes('10514') && !csv.includes('9999') && !csv.includes('time.example.org'));
        assert.equal(calls.filter(c => c.url.includes('/apply/')).length, 3);
        handler = (url, options) => options.method === 'PUT' ? json({}) : json({ applied: applied[url.split('/').at(-1)] });
        await inst.saveHostSection('syslog');
        await finish(inst.downloadPpsm());
        assert.ok(!csv.includes('9999'), 'saved settings do not claim to be applied');
        applied.syslog = { ...groups.syslog, syslog_port: '9999', syslog_protocol: 'tls' };
        applied.nginx.http_redirect_enabled = 'false';
        await finish(inst.downloadPpsm());
        assert.match(csv, /"Logging","Syslog over TLS","9999","TCP","Outbound","Enabled; applied protocol: tls/);
        assert.match(csv, /Disabled by applied http_redirect_enabled/);
        for (const failure of ['null', 'http', 'network', 'hung']) {
            handler = () => {
                if (failure === 'network') throw new Error('offline');
                if (failure === 'hung') return new Promise(() => {});
                return json({ applied: null }, failure === 'http' ? 503 : 200);
            };
            await finish(inst.downloadPpsm());
            const note = failure === 'null' ? 'not yet applied' : 'state unknown';
            for (const service of ['HTTP', 'NTP', 'Syslog', 'Syslog over TLS']) {
                const row = csv.split('\n').find(row => row.includes('"' + service + '"'));
                assert.ok(row.includes(note), service + ' explicitly reports ' + note);
            }
            assert.ok(!csv.includes('9999') && !csv.includes('live.example.org'));
        }
    } else throw new Error('Unknown scenario: ' + scenario);
    const expected = { bindings: 93, validation: 269, errors: 14, apply: 45, timeout: 13, panels: 27, tls: 103, ppsm: 28, integration: 83 };
    rawAssert.equal(assertions, expected[scenario], 'complete the exact scenario assertion count');
    console.log('ALL ' + assertions + ' ASSERTIONS PASSED');
}
main().catch(e => { console.error(e.stack); process.exitCode = 1; }).finally(() => clearTimeout(watchdog));
