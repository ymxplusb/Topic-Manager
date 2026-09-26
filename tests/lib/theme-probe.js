// =============================================================================
// tests/lib/theme-probe.js — drives the REAL theme helpers in
// app/components/TopBar.js (tmReadTheme / tmSaveTheme / tmApplyTheme).
//
// Loads the shipped source into a vm context with a stubbed localStorage and
// document.body.classList, then reports what the helpers decided. It never
// re-implements them.
//
// Usage: node tests/lib/theme-probe.js <repo-root> <scenario>
//   scenarios:  saved-light  saved-cb  saved-garbage  saved-none
//               storage-throws  apply-each
//
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
// =============================================================================
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = process.argv[2];
const scenario = process.argv[3];
const srcPath = path.join(repoRoot, 'app', 'components', 'TopBar.js');
const src = fs.readFileSync(srcPath, 'utf8');

const classes = new Set();
const store = {};
let throwing = false;

const sandbox = {
    console: console,
    localStorage: {
        getItem: function (k) {
            if (throwing) throw new Error('SecurityError');
            return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null;
        },
        setItem: function (k, v) {
            if (throwing) throw new Error('SecurityError');
            store[k] = String(v);
        },
    },
    document: {
        body: {
            classList: {
                add: function () { for (const c of arguments) classes.add(c); },
                remove: function () { for (const c of arguments) classes.delete(c); },
            },
        },
        addEventListener: function () {},
        removeEventListener: function () {},
    },
};
vm.createContext(sandbox);
vm.runInContext(src + '\n;globalThis.__t = { read: tmReadTheme, save: tmSaveTheme, apply: tmApplyTheme, TopBar: TopBar };',
                sandbox, { filename: srcPath });
const t = sandbox.__t;

function emit(k, v) { console.log(k + '=' + v); }
function cls() { return Array.from(classes).sort().join(',') || '(none)'; }

try {
    if (scenario === 'saved-light')   { store.tmTheme = 'light'; }
    if (scenario === 'saved-cb')      { store.tmTheme = 'cb'; }
    if (scenario === 'saved-garbage') { store.tmTheme = 'light-mode cb-mode'; }
    if (scenario === 'storage-throws') { throwing = true; }

    if (scenario === 'apply-each') {
        ['dark', 'light', 'cb', 'bogus'].forEach(function (x) {
            classes.add('light-mode'); classes.add('cb-mode');   // dirty start
            const got = t.apply(x);
            emit('apply.' + x, got + '|' + cls());
        });
    } else {
        const theme = t.read();
        emit('read', theme);
        emit('applied', t.apply(theme));
        emit('classes', cls());
        // The mounted() path of the real component, bound to a bare object.
        const inst = t.TopBar.data.call({});
        emit('dataTheme', inst.currentTheme);
        const self = Object.assign(inst, {});
        t.TopBar.mounted.call(self);
        emit('mountedTheme', self.currentTheme);
        emit('mountedClasses', cls());
        // setTheme must persist, and must not throw when storage does.
        t.TopBar.methods.setTheme.call(self, 'light');
        emit('afterSet', self.currentTheme + '|' + cls());
        emit('stored', throwing ? '(storage unavailable)' : store.tmTheme);
    }
} catch (e) {
    emit('EXCEPTION', (e && e.message) || e);
    process.exit(3);
}
