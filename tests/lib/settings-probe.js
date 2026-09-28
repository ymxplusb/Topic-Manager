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
//               rail  rail-search  group-default  group-saved-valid
//               group-saved-invalid  group-storage-throws  group-select
//               decode
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

    // ─── the v1.1.0 section rail ─────────────────────────────────────────
    } else if (scenario === 'rail') {
        // The rail is DERIVED from the template. Print what it derived, so the
        // case can assert the groups and where each card landed.
        emit('railIds', inst.railGroups.map(function (g) { return g.id; }).join(','));
        emit('railNames', inst.railGroups.map(function (g) { return g.name; }).join(','));
        inst.railGroups.forEach(function (g) {
            emit('sections.' + g.id, JSON.stringify(g.sections));
        });
        emit('activeGroup', inst.activeGroup);

    } else if (scenario === 'rail-search') {
        ['ppsm', 'classification', 'restart', 'cluster profiles', 'zzz-nothing'].forEach(function (q) {
            inst.railQuery = q;
            emit('match.' + q.replace(/ /g, '_'), inst.railGroups.filter(function (g) {
                return inst.railMatch(g); }).map(function (g) { return g.id; }).join(','));
        });

    } else if (scenario === 'decode') {
        // v1.1.1: the rail decodes entities in card titles through
        // settingsDecodeEntities (a top-level function, so a property of the
        // vm global). The template only uses entities it knows, so the rail
        // cases cannot tell an own-property lookup from "any name" or from a
        // lookup that also sees Object.prototype. These inputs can.
        const d = sandbox.settingsDecodeEntities;
        [['named', 'A &amp; B'], ['numeric', 'it&#39;s'], ['hex', '&#x41;&#X42;'],
         ['unknown', 'x &bogus; y'], ['prototype', '&constructor; &toString; &hasOwnProperty;'],
         ['mixed', '&lt;b&gt; &mdash; &nope;']].forEach(function (c) {
            emit('decode.' + c[0], JSON.stringify(d(c[1])));
        });

    } else if (scenario.indexOf('group-') === 0) {
        // localStorage is installed AFTER the component source has run and
        // BEFORE the instance is built, which is when data() reads it.
        const store = {};
        const mode = scenario.slice('group-'.length);
        if (mode === 'saved-valid')   store.tmSettingsGroup = 'support';
        if (mode === 'saved-invalid') store.tmSettingsGroup = 'no-such-pane';
        sandbox.localStorage = mode === 'storage-throws'
            ? { getItem: function () { throw new Error('SecurityError'); },
                setItem: function () { throw new Error('SecurityError'); } }
            : { getItem: function (k) { return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
                setItem: function (k, v) { store[k] = String(v); } };
        const fresh = instance();
        emit('activeGroup', fresh.activeGroup);
        if (mode === 'select') {
            fresh.selectGroup('system');
            emit('afterSelect', fresh.activeGroup);
            emit('stored', store.tmSettingsGroup);
            fresh.selectGroup('no-such-pane');
            emit('afterBogus', fresh.activeGroup);
            emit('storedAfterBogus', store.tmSettingsGroup);
        }
        if (mode === 'storage-throws') {
            fresh.selectGroup('support');
            emit('afterSelect', fresh.activeGroup);
        }

    } else {
        console.error('unknown scenario: ' + scenario);
        process.exit(2);
    }
}

main().catch(function (e) { console.error(e && e.stack || e); process.exit(2); });
