// =============================================================================
// tests/lib/settings-probe.js — drives the REAL app/components/SettingsTab.js.
//
// There is no build step, no npm and no test runner in this repo, so this
// loads the shipped component source into a vm context with a stubbed fetch
// and document, then calls its methods directly. It never re-implements
// loadSettings or saveBanner: a re-implementation would test the test.
//
// It prints one KEY=VALUE line per fact. The bash case asserts on those.
//
// Usage: node tests/lib/settings-probe.js <repo-root> <scenario>
//   scenarios:  load-401  load-network  load-ok  save-before-load
//
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
// =============================================================================
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = process.argv[2];
const scenario = process.argv[3];
const srcPath = path.join(repoRoot, 'app', 'components', 'SettingsTab.js');
const src = fs.readFileSync(srcPath, 'utf8');

// Every fetch the component makes, in order, so the case can assert that a
// PUT was NOT issued. "It did not save" is the claim; the call log is the
// evidence.
const calls = [];
let nextResponse = null;

function makeFetch() {
    return function (url, opts) {
        calls.push({ url: url, method: (opts && opts.method) || 'GET',
                     body: (opts && opts.body) || null });
        if (typeof nextResponse === 'function') return nextResponse(url, opts);
        return Promise.resolve(nextResponse);
    };
}

const sandbox = {
    // SettingsTab names ClusterModal in components: {} at definition time and
    // index.html loads it first. Stub it so the module evaluates.
    ClusterModal: {},
    fetch: makeFetch(),
    document: {
        getElementById: function () { return null; },
        body: { style: {} },
    },
    console: console,
    setTimeout: setTimeout,
    Date: Date,
    URL: { createObjectURL: function () { return ''; } },
    Blob: function () {},
};
vm.createContext(sandbox);
vm.runInContext(src + '\n;globalThis.__SettingsTab = SettingsTab;', sandbox,
                { filename: srcPath });

const SettingsTab = sandbox.__SettingsTab;

// A minimal Vue-less instance: data() fields plus the methods and computed
// getters bound to the same object, which is what `this` is inside a Vue
// options component.
function instance() {
    const inst = SettingsTab.data.call({});
    Object.keys(SettingsTab.methods).forEach(function (k) {
        inst[k] = SettingsTab.methods[k].bind(inst);
    });
    Object.keys(SettingsTab.computed || {}).forEach(function (k) {
        Object.defineProperty(inst, k, {
            get: SettingsTab.computed[k].bind(inst), configurable: true });
    });
    inst.$emit = function () {};
    return inst;
}

function emit(k, v) { console.log(k + '=' + v); }

function report(inst) {
    emit('settingsLoaded', inst.settingsLoaded);
    emit('settingsError', inst.settingsError ? 'set' : 'empty');
    emit('bannerText', JSON.stringify(inst.bannerText));
    emit('bannerBg', JSON.stringify(inst.bannerBg));
    emit('putCount', calls.filter(function (c) { return c.method === 'PUT'; }).length);
    emit('putBodies', JSON.stringify(calls.filter(function (c) {
        return c.method === 'PUT'; }).map(function (c) { return c.body; })));
}

const SEEDED_DEFAULTS = { banner_enabled: 'true', banner_text: 'UNCLASSIFIED',
                          banner_bg: 'green', banner_fg: 'white',
                          dow_enabled: 'false' };
const OPERATOR_VALUES = { banner_enabled: 'true', banner_text: 'SECRET//NOFORN',
                          banner_bg: 'red', banner_fg: 'white',
                          dow_enabled: 'true' };

async function main() {
    const inst = instance();

    if (scenario === 'load-401') {
        // The exact reported path: the session expired, /api/settings answers
        // 401, and then the operator toggles the banner switch.
        nextResponse = { ok: false, status: 401,
                         json: function () { return Promise.resolve({}); } };
        await inst.loadSettings();
        inst.bannerEnabled = !inst.bannerEnabled;
        await inst.saveBanner();
        report(inst);

    } else if (scenario === 'load-network') {
        nextResponse = function () { return Promise.reject(new Error('offline')); };
        await inst.loadSettings();
        await inst.saveDow();
        report(inst);

    } else if (scenario === 'load-ok') {
        nextResponse = function (url, opts) {
            if (opts && opts.method === 'PUT') {
                return Promise.resolve({ ok: true, status: 200,
                    json: function () { return Promise.resolve({ ok: true }); } });
            }
            return Promise.resolve({ ok: true, status: 200,
                json: function () { return Promise.resolve(OPERATOR_VALUES); } });
        };
        await inst.loadSettings();
        await inst.saveBanner();
        report(inst);

    } else if (scenario === 'save-before-load') {
        // loadSettings is never called at all. The save path must still
        // refuse: the template guard and the method guard are two independent
        // barriers, and this case exercises the second one on its own.
        nextResponse = { ok: true, status: 200,
                         json: function () { return Promise.resolve(SEEDED_DEFAULTS); } };
        await inst.saveBanner();
        await inst.saveDow();
        report(inst);

    } else {
        console.error('unknown scenario: ' + scenario);
        process.exit(2);
    }
}

main().catch(function (e) { console.error(e && e.stack || e); process.exit(2); });
