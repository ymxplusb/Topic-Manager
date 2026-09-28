// Jarvis Topic Manager — Settings Tab
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
// Values stay strings, matching app_settings and PUT /api/settings.
const SETTINGS_V120_DEFAULTS = {
    syslog_enabled: 'false', syslog_host: '', syslog_port: '6514',
    syslog_protocol: 'tls', syslog_app_id: 'topic-manager', ntp_servers: '',
    session_max_concurrent: '3', ratelimit_login_per_min: '10',
    ratelimit_login_burst: '5', ratelimit_api_per_min: '300',
    ratelimit_api_burst: '100', ratelimit_conn_per_ip: '20',
    audit_retention_days: '365', audit_max_rows: '5000000', audit_warn_pct: '75',
    http_redirect_enabled: 'true',
};
const SETTINGS_V120_SECTIONS = {
    sessions: ['session_max_concurrent'],
    rate: ['ratelimit_login_per_min', 'ratelimit_login_burst', 'ratelimit_api_per_min', 'ratelimit_api_burst', 'ratelimit_conn_per_ip'],
    redirect: ['http_redirect_enabled'],
    syslog: ['syslog_enabled', 'syslog_host', 'syslog_port', 'syslog_protocol', 'syslog_app_id'],
    retention: ['audit_retention_days', 'audit_max_rows', 'audit_warn_pct'],
    time: ['ntp_servers'],
};
const SETTINGS_V120_RANGES = {
    syslog_port: [1, 65535], session_max_concurrent: [0, 50],
    ratelimit_login_per_min: [1, 600], ratelimit_login_burst: [0, 100],
    ratelimit_api_per_min: [10, 6000], ratelimit_api_burst: [0, 1000],
    ratelimit_conn_per_ip: [1, 500], audit_retention_days: [30, 3650],
    audit_max_rows: [10000, 50000000], audit_warn_pct: [50, 95],
};

// Discard possible PEM/base64 material before it can enter job state.
function settingsJobText(value) {
    return typeof value === 'string' && !/-----BEGIN|[A-Za-z0-9+/]{65,}/.test(value) ? value : '';
}
const SETTINGS_STATUS_UNKNOWN = 'Status unknown — the host may or may not have applied the change. Check again.';
const SETTINGS_TLS_ERRORS = {
    key_mismatch: 'Certificate does not match key.',
    cert_key_mismatch: 'Certificate does not match key.',
    invalid_cert: 'The certificate is invalid.',
    invalid_key: 'The private key is invalid.',
    encrypted_key: 'Use an unencrypted private key.',
    invalid_chain: 'The certificate chain is invalid.',
};
const SETTINGS_FAILED_STATES = new Set(['failed', 'rolled_back']);
const SETTINGS_SETTLED_STATES = new Set(['idle', 'ok', 'failed', 'rolled_back']);
const SETTINGS_PENDING_STATES = new Set(['queued', 'running']);
// A POST answered with one of these was refused: nothing was queued.
const SETTINGS_REFUSAL_STATUSES = new Set([400, 401, 403, 404, 411, 413, 415, 429, 502]);
const SETTINGS_TLS_UPLOAD_FAILED = 'Certificate upload failed. Check the certificate and key, then try again.';
// A backend refusal the operator is told about in words, keyed by
// "<HTTP status> <error code>".
const SETTINGS_HOST_ERRORS = {
    '503 audit_unavailable': 'Audit logging is unavailable. The action was blocked; nothing was changed. Restore audit logging before retrying.',
    '500 audit_write_failed': 'The change WAS made, but its audit record could not be written. Check the audit database and AUDIT_WRITE_FAILED in the host syslog before making any further change.',
    '409 apply_in_progress': 'An apply is already queued or running. Check status before applying again.',
    '404 unknown_domain': 'This apply domain is not supported. TLS changes must use the certificate upload form.',
    '502 apply_unit_failed': 'The host apply service could not start. Check the service on the host, then check status before retrying.',
};
// Statuses nginx or the upload route answer before any JSON error code exists.
const SETTINGS_HTTP_ERRORS = {
    411: 'Certificate upload requires Content-Length. Retry the file upload and check that your proxy preserves this header.',
    413: 'Certificate upload exceeds the 200 KiB request limit, including multipart framing. Choose smaller PEM files.',
};

function settingsThrottleText(response, data) {
    const seconds = Number(response.headers?.get('Retry-After') || data.retry_after);
    const wait = Number.isFinite(seconds) && seconds > 0 ? Math.ceil(seconds) : 5;
    return 'Apply requests are limited to one per domain every 5 seconds. Wait ' + wait + ' seconds before retrying.';
}

function settingsTlsErrorText(response, data) {
    if (response.status === 400 && data.error === 'invalid_cert' && Object.hasOwn(SETTINGS_TLS_ERRORS, data.reason))
        return SETTINGS_TLS_ERRORS[data.reason];
    return SETTINGS_TLS_UPLOAD_FAILED;
}

// The operator-facing sentence for a failed host request (never a poll: a
// failed poll is always "status unknown").
function settingsHostErrorText(response, data, fallback, context) {
    const known = response.status + ' ' + data.error;
    if (Object.hasOwn(SETTINGS_HOST_ERRORS, known)) return SETTINGS_HOST_ERRORS[known];
    if (response.status === 429 && data.error === 'apply_throttled') return settingsThrottleText(response, data);
    if (Object.hasOwn(SETTINGS_HTTP_ERRORS, response.status)) return SETTINGS_HTTP_ERRORS[response.status];
    if (response.status === 415) {
        return context === 'tls' ? 'Certificate upload requires multipart/form-data. Select the PEM files and submit the upload form.'
            : 'This request requires Content-Type: application/json. Reload the page before retrying.';
    }
    if (context === 'tls') return settingsTlsErrorText(response, data);
    if (response.status === 400 && data.error === 'invalid') return data.field + ': ' + data.reason;
    return data.reason || data.error || fallback + ' (HTTP ' + response.status + ').';
}

function settingsHostValid(value) {
    if (!value || value.length > 253) return false;
    if (/^[A-Za-z0-9.-]+$/.test(value)) return true;
    // IPv6 literal, including an optional IPv4 tail; no zone IDs or brackets.
    if (!value.includes(':') || /[^0-9a-fA-F:.]/.test(value)) return false;
    let address = value;
    if (address.includes('.')) {
        const tail = address.slice(address.lastIndexOf(':') + 1);
        if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(tail)
            || tail.split('.').some(n => Number(n) > 255 || (n.length > 1 && n[0] === '0'))) return false;
        address = address.slice(0, address.lastIndexOf(':') + 1) + '0:0';
    }
    const halves = address.split('::');
    if (halves.length > 2) return false;
    const groups = halves.flatMap(h => h ? h.split(':') : []);
    if (groups.some(g => !/^[0-9a-fA-F]{1,4}$/.test(g))) return false;
    return halves.length === 2 ? groups.length < 8 : groups.length === 8;
}

// The first line an apply run shows, before the host has answered.
function settingsApplyStartMessage(domain, options) {
    if (!options) return 'Checking host status…';
    return domain === 'tls' ? 'Uploading certificate…' : 'Requesting apply of saved settings…';
}

// The 2 s between status polls; run.wake ends it early when the run stops.
function settingsApplyPause(run) {
    return new Promise(resolve => {
        run.wake = resolve;
        run.timer = setTimeout(resolve, 2000);
    });
}

// TLS applied data is a certificate summary, never settings or PEM.
function settingsTlsSummaryValue(key, value) {
    if (key === 'chain_count') return Number.isInteger(value) ? value : null;
    return settingsJobText(value);
}

function settingsTlsSummary(applied) {
    return Object.fromEntries(['subject', 'issuer', 'not_after', 'key_type', 'chain_count']
        .map(key => [key, settingsTlsSummaryValue(key, applied[key])]));
}

// What one status answer may put into job state: filtered text only.
function settingsJobUpdate(domain, data) {
    return {
        job: settingsJobText(data.job), state: data.state, applied_at: settingsJobText(data.applied_at),
        applied: domain === 'tls' && data.applied ? settingsTlsSummary(data.applied) : null,
        message: settingsJobText(data.message),
        details: Array.isArray(data.details) ? data.details.map(settingsJobText).filter(Boolean) : [],
    };
}

// CC-1: the PPSM describes what the host status endpoint says was APPLIED,
// never what is merely saved. One domain, bounded to 10 s.
function settingsLiveState(data) {
    if (data.applied === null) return { note: 'not yet applied' };
    if (data.applied && typeof data.applied === 'object') return { config: data.applied };
    return { note: 'state unknown' };
}

async function settingsLiveApplied(domain) {
    const controller = new AbortController();
    let timer;
    try {
        const data = await Promise.race([
            (async () => {
                const response = await fetch('/api/system/apply/' + domain, {
                    signal: controller.signal, cache: 'no-store', headers: { 'X-TM-Background': '1' },
                });
                if (!response.ok) throw new Error('Status unavailable');
                return response.json();
            })(),
            new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Timeout')), 10000); }),
        ]);
        return [domain, settingsLiveState(data)];
    } catch {
        // Unreachable, refused, unparsable or too slow: the export states that
        // the host state is unknown rather than failing or guessing.
        return [domain, { note: 'state unknown' }];
    } finally {
        clearTimeout(timer);
        controller.abort();
    }
}

function settingsSyslogTransport(syslog, config) {
    if (syslog.note) return 'N/A';
    return config.syslog_protocol === 'udp' ? 'UDP' : 'TCP';
}

// One check per field that has one; a field with none always passes. The
// server validates again (tm/settings_schema.py) and its answer is final.
const SETTINGS_BOOL_KEYS = new Set(['syslog_enabled', 'http_redirect_enabled']);
const SETTINGS_BOOL_VALUES = new Set(['true', 'false']);
const SETTINGS_SYSLOG_PROTOCOLS = new Set(['udp', 'tcp', 'tls']);
const SETTINGS_FIELD_CHECKS = {
    syslog_protocol: value => SETTINGS_SYSLOG_PROTOCOLS.has(value.trim().toLowerCase()) ? '' : 'Choose UDP, TCP or TLS.',
    syslog_app_id: value => /^[A-Za-z0-9._-]{1,48}$/.test(value) ? '' : 'Use 1–48 letters, numbers, dots, underscores or hyphens.',
    syslog_host: (value, current) => (value === '' && current.syslog_enabled === 'false') || settingsHostValid(value)
        ? '' : 'Enter a hostname or IP address (1–253 characters).',
    ntp_servers: value => {
        if (value === '') return '';
        const servers = value.split(',').map(v => v.trim());
        return servers.length > 5 || servers.some(v => !settingsHostValid(v))
            ? 'Enter 1–5 comma-separated hostnames or IP addresses, or leave empty to keep host defaults.' : '';
    },
};

function settingsFieldReason(key, value, current) {
    const range = SETTINGS_V120_RANGES[key];
    if (range) {
        return !/^\d+$/.test(value) || Number(value) < range[0] || Number(value) > range[1]
            ? 'Enter a whole number from ' + range[0] + ' to ' + range[1] + '.' : '';
    }
    if (SETTINGS_BOOL_KEYS.has(key)) return SETTINGS_BOOL_VALUES.has(value) ? '' : 'Choose true or false.';
    return Object.hasOwn(SETTINGS_FIELD_CHECKS, key) ? SETTINGS_FIELD_CHECKS[key](value, current) : '';
}

function settingsValidation(payload, current) {
    for (const [key, value] of Object.entries(payload)) {
        const reason = settingsFieldReason(key, value, current);
        if (reason) return key + ': ' + reason;
    }
    return '';
}

const SettingsTab = {
    name: 'SettingsTab',
    components: { ClusterModal },
    props: ['clusters', 'activeClusterId', 'version', 'protocols', 'mechanisms'],
    emits: ['open-about', 'cluster-changed', 'clusters-changed'],
    data() {
        const railGroups = settingsRailGroups();
        return {
            // Section rail (v1.1.0). railGroups is derived from the template;
            // activeGroup is restored from localStorage only if it still names
            // a real pane.
            railGroups,
            activeGroup: settingsInitialGroup(railGroups),
            railQuery: '',
            // Settings load state. NOTHING below is rendered or saved until
            // settingsLoaded is true. Seeding real-looking values into the same
            // fields the save path reads is what made a failed load overwrite
            // the operator's banner with green/UNCLASSIFIED for every user.
            settingsLoaded: false,
            settingsError: '',
            settingsSaveError: '',
            hostSettings: {},
            savedHostSettings: {},
            sectionSaving: {},
            sectionMessages: {},
            hostPanels: { time: null, capacity: null, tls: null },
            hostPanelErrors: {},
            hostPanelLoading: {},
            applyJobs: Object.fromEntries(['syslog', 'time', 'nginx', 'tls'].map(domain =>
                [domain, { busy: false, uncertain: true, state: 'idle', job: '', applied: null, applied_at: null, message: '', details: [] }])),
            hostRuns: {},
            hostDisposed: false,
            // DoW Consent
            dowEnabled: false,
            // Banner — empty until the server has answered
            bannerEnabled: false,
            bannerText: '',
            bannerBg: '',
            bannerFg: '',
            bannerColors: [
                { val: 'green',  hex: '#16a34a', label: 'Green' },
                { val: 'blue',   hex: '#2563eb', label: 'Blue' },
                { val: 'purple', hex: '#7c3aed', label: 'Purple' },
                { val: 'red',    hex: '#dc2626', label: 'Red' },
                { val: 'orange', hex: '#ea580c', label: 'Orange' },
                { val: 'yellow', hex: '#ca8a04', label: 'Yellow' },
            ],
            // Cluster test
            testResults: {},
            testing: {},
            // Cluster Builder
            showClusterModal: false,
            editingCluster: null,
            deletingCluster: null,
            clusterError: '',
            // Service restart
            restartNginxHard: false,
            restartState: '',        // '' | 'working' | 'ok' | 'failed'
            restartMessage: '',
        };
    },
    computed: {
        bannerHex() {
            const c = this.bannerColors.find(x => x.val === this.bannerBg);
            return c ? c.hex : '#16a34a';
        },
        restartColour() {
            if (this.restartState === 'ok')     return 'var(--accent-green)';
            if (this.restartState === 'failed') return 'var(--accent-red)';
            return 'var(--text-muted)';
        },
        fgColor() {
            return { white: '#ffffff', black: '#000000', grey: '#d1d5db' }[this.bannerFg] || '#ffffff';
        },
    },
    watch: {
        // Rail search auto-jump, as in CORTEX: if the open group no longer
        // matches the query, move to the first group that does, through
        // selectGroup() so the jump is persisted like any other choice.
        railQuery(q) {
            if (!q.trim()) return;
            const cur = this.railGroups.find(g => g.id === this.activeGroup);
            if (cur && this.railMatch(cur)) return;
            const first = this.railGroups.find(g => this.railMatch(g));
            if (first) this.selectGroup(first.id);
        },
    },
    methods: {
        // ── Section rail ───────────────────────────────────────────
        selectGroup(id) {
            if (!this.railGroups.some(g => g.id === id)) return;
            this.activeGroup = id;
            try { localStorage.setItem(SETTINGS_GROUP_KEY, id); } catch (e) { /* storage unavailable: the choice holds for this visit */ }
        },
        railMatch(g) {
            const q = settingsSearchNorm(this.railQuery);
            if (!q) return true;
            return settingsSearchNorm(g.name + ' ' + g.sections.join(' ') + ' ' + g.terms.join(' ')).includes(q);
        },
        // F4. This used to `return` on a non-ok response, leaving the seeded
        // 'UNCLASSIFIED'/'green' defaults sitting in the very fields
        // saveBanner() reads. An expired session on load followed by one
        // toggle therefore PUT those defaults over the operator's real
        // banner — globally, for every user. The failure is now surfaced and
        // the form stays unrendered, so there is nothing to save.
        async loadSettings() {
            this.settingsError = '';
            this.settingsLoaded = false;
            let s;
            try {
                const r = await fetch('/api/settings');
                if (!r.ok) {
                    this.settingsError = r.status === 401
                        ? 'Your session has expired. Sign in again to load or change these settings.'
                        : 'Could not load settings (HTTP ' + r.status + '). Nothing has been changed.';
                    return;
                }
                s = await r.json();
            } catch (e) {
                this.settingsError = 'Could not reach the server to load settings. Nothing has been changed.';
                return;
            }
            this.dowEnabled    = s.dow_enabled    === 'true';
            this.bannerEnabled = s.banner_enabled === 'true';
            this.bannerText    = s.banner_text    || 'UNCLASSIFIED';
            this.bannerBg      = s.banner_bg      || 'green';
            this.bannerFg      = s.banner_fg      || 'white';
            this.hostSettings = Object.fromEntries(Object.entries(SETTINGS_V120_DEFAULTS)
                .map(([key, fallback]) => [key, String(s[key] ?? fallback)]));
            this.savedHostSettings = { ...this.hostSettings };
            this.settingsLoaded = true;
            this.applyBanner();
        },
        // Both save paths refuse while settingsLoaded is false. The template
        // does not render the controls either, so this is the second of two
        // independent barriers — the one that still holds if a control is ever
        // rendered outside the v-if.
        async saveSettings(payload) {
            if (!this.settingsLoaded) {
                this.settingsSaveError = 'Settings have not loaded — refusing to save.';
                return false;
            }
            this.settingsSaveError = settingsValidation(payload, { ...this.savedHostSettings, ...payload });
            if (this.settingsSaveError) return false;
            try {
                const r = await fetch('/api/settings', {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload),
                });
                if (!r.ok) {
                    this.settingsSaveError = await this.hostResponseError(r, 'Save failed');
                    return false;
                }
            } catch (e) {
                this.settingsSaveError = 'Save failed: the server could not be reached.';
                return false;
            }
            // PUT returns changed key names, not their normalised values.
            // Reload all 21 keys before reporting success or enabling Apply.
            await this.loadSettings();
            if (!this.settingsLoaded) {
                this.settingsSaveError = 'The settings were saved, but their normalised values could not be reloaded. Reload settings before making another change.';
                return false;
            }
            return true;
        },
        async saveDow() {
            await this.saveSettings({ dow_enabled: String(this.dowEnabled) });
        },
        async saveBanner() {
            const ok = await this.saveSettings({
                banner_enabled: String(this.bannerEnabled),
                banner_text:    this.bannerText,
                banner_bg:      this.bannerBg,
                banner_fg:      this.bannerFg,
            });
            if (ok) this.applyBanner();
        },
        applyBanner() {
            const top = document.getElementById('banner-top');
            const bot = document.getElementById('banner-bot');
            if (!top || !bot) return;
            [top, bot].forEach(el => {
                el.style.display    = this.bannerEnabled ? 'block' : 'none';
                el.style.background = this.bannerHex;
                el.style.color      = this.fgColor;
                el.textContent      = this.bannerText;
            });
            // Push app content down/up so fixed banners don't overlap it
            const h = this.bannerEnabled ? (top.offsetHeight || 26) + 'px' : '0px';
            document.body.style.paddingTop    = h;
            document.body.style.paddingBottom = h;
        },
        // ── v1.2.0 host settings ────────────────────────────────────
        async hostResponseError(response, fallback, context = 'save', parsed = null) {
            let data = parsed || {};
            if (!parsed) try { data = await response.json(); } catch (e) { /* non-JSON proxy response */ }
            if (context === 'poll') return SETTINGS_STATUS_UNKNOWN;
            return settingsHostErrorText(response, data, fallback, context);
        },
        async saveHostSection(section) {
            if (this.sectionSaving[section]) return;
            this.sectionSaving[section] = true;
            this.sectionMessages[section] = '';
            try {
                const payload = Object.fromEntries(SETTINGS_V120_SECTIONS[section]
                    .map(key => [key, String(this.hostSettings[key] ?? '')]));
                const ok = await this.saveSettings(payload);
                this.sectionMessages[section] = (ok ? '✓ Saved.' : '✕ ' + this.settingsSaveError);
                if (ok && section === 'retention') await this.loadHostPanel('capacity');
            } finally { this.sectionSaving[section] = false; }
        },
        async loadHostPanel(panel) {
            if (this.hostDisposed || this.hostPanelLoading[panel]) return;
            const paths = { time: '/api/system/time', capacity: '/api/audit/capacity', tls: '/api/system/tls' };
            this.hostPanelLoading[panel] = true;
            this.hostPanelErrors[panel] = '';
            try {
                const response = await fetch(paths[panel], { cache: 'no-store', headers: { 'X-TM-Background': '1' } });
                if (!response.ok) throw new Error(await this.hostResponseError(response, 'Status unavailable'));
                const data = await response.json();
                if (!this.hostDisposed) this.hostPanels[panel] = data;
            } catch (e) {
                if (!this.hostDisposed) this.hostPanelErrors[panel] = e.message || 'Status unavailable.';
            } finally { this.hostPanelLoading[panel] = false; }
        },
        statusGlyph(state) {
            if (state === 'ok') return '✓';
            return SETTINGS_FAILED_STATES.has(state) ? '✕' : '!';
        },
        // One deadline covers POST, polling, and even a hung fetch/body read.
        // Run state holds cancellation handles only; certificate files stay local.
        async runHostApply(domain, options = null) {
            const job = this.applyJobs[domain];
            if (!job || job.busy || this.hostDisposed) return;
            if (options && (!this.settingsLoaded || job.uncertain)) return;
            job.busy = true;
            if (options) job.state = 'requesting';
            job.message = settingsApplyStartMessage(domain, options);
            job.details = [];
            const run = { controller: new AbortController(), timer: null, wake: null, cancel: null };
            this.hostRuns[domain] = run;
            const deadline = Date.now() + 90000;
            let expiry;
            const expired = new Promise((resolve, reject) => {
                run.cancel = () => reject(new Error('Monitoring stopped.'));
                expiry = setTimeout(() => {
                    run.controller.abort();
                    reject(Object.assign(new Error('Monitoring timed out after 90 seconds. The host outcome is unknown. Check status before applying again.'), { safe: true }));
                }, 90000);
            });
            try {
                await Promise.race([this.monitorHostApply(domain, job, run, options, deadline), expired]);
            } catch (e) {
                job.uncertain = !e.refused;
                job.state = e.refused ? 'failed' : 'unknown';
                job.message = e.safe ? settingsJobText(e.message) : SETTINGS_STATUS_UNKNOWN;
            } finally {
                if (domain === 'tls' && options?.body) {
                    ['cert', 'key', 'chain'].forEach(key => options.body.delete(key));
                    options.body = null;
                }
                options = null;
                clearTimeout(expiry);
                clearTimeout(run.timer);
                if (run.wake) run.wake();
                run.controller.abort();
                job.busy = false;
                delete this.hostRuns[domain];
            }
        },
        // One host request of an apply run. A refusal (the request was
        // answered and nothing was queued) is marked so the job reads
        // "failed", not "unknown".
        async hostApplyRequest(domain, run, url, opts) {
            let response;
            try {
                response = await fetch(url, { ...opts, signal: run.controller.signal, cache: 'no-store' });
            } finally {
                if (domain === 'tls' && opts.body) {
                    ['cert', 'key', 'chain'].forEach(key => opts.body.delete(key));
                    opts.body = null;
                }
            }
            if (!response.ok) {
                const error = new Error(await this.hostResponseError(response, 'Host request failed', opts.method === 'POST' ? domain : 'poll'));
                error.safe = true;
                error.refused = opts.method === 'POST' && (SETTINGS_REFUSAL_STATUSES.has(response.status)
                    || error.message.startsWith('Audit logging is unavailable.'));
                throw error;
            }
            return response.json();
        },
        hostRunStopped(run) {
            return this.hostDisposed || run.controller.signal.aborted;
        },
        // Submit (when there is something to submit), then poll the status
        // until the job settles, the run stops, or the deadline passes.
        async monitorHostApply(domain, job, run, options, deadline) {
            if (options && !(await this.submitHostApply(domain, job, run, options))) return;
            await this.pollHostApply(domain, job, run, deadline, !options);
        },
        // The request itself. False when the run stopped while it was in flight.
        async submitHostApply(domain, job, run, options) {
            const data = await this.hostApplyRequest(domain, run, domain === 'tls' ? '/api/system/tls/cert' : '/api/system/apply/' + domain, options);
            if (this.hostRunStopped(run)) return false;
            Object.assign(job, { job: settingsJobText(data.job), state: data.state, uncertain: true, message: 'Apply queued. Waiting for host status…' });
            return true;
        },
        // Poll until the job settles; `immediate` skips the first pause (a
        // status check with nothing submitted).
        async pollHostApply(domain, job, run, deadline, immediate) {
            let first = immediate;
            while (!this.hostDisposed && Date.now() < deadline) {
                if (!first) await settingsApplyPause(run);
                first = false;
                if (this.hostRunStopped(run)) return;
                const data = await this.hostApplyRequest(domain, run, '/api/system/apply/' + domain, { headers: { 'X-TM-Background': '1' } });
                if (this.hostRunStopped(run)) return;
                Object.assign(job, settingsJobUpdate(domain, data));
                if (SETTINGS_SETTLED_STATES.has(data.state)) {
                    this.settleHostApply(domain, job);
                    return;
                }
                if (!SETTINGS_PENDING_STATES.has(data.state)) throw new Error('Unknown apply state. Check status before applying again.');
            }
            if (!this.hostDisposed) throw new Error('Monitoring timed out after 90 seconds. The host outcome is unknown. Check status before applying again.');
        },
        settleHostApply(domain, job) {
            job.uncertain = false;
            if (domain === 'time' || domain === 'tls') void this.loadHostPanel(domain);
        },
        applyToHost(domain) {
            if (!['syslog', 'time', 'nginx'].includes(domain)) return;
            if (domain === 'nginx' ? (this.sectionSaving.rate || this.sectionSaving.redirect) : this.sectionSaving[domain]) return;
            return this.runHostApply(domain, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
        },
        submitCertificate() {
            const form = this.$refs.certForm;
            if (!form) return;
            try {
                if (!this.settingsLoaded || this.applyJobs.tls.busy || this.applyJobs.tls.uncertain) return;
                // FormData is only a local variable. Never read PEM into a string,
                // persist a File, or set multipart Content-Type (fetch adds its boundary).
                const body = new FormData(form);
                if (!body.get('chain')?.name) body.delete('chain');
                return this.runHostApply('tls', { method: 'POST', body });
            } finally { form.reset(); }
        },
        async testCluster(id) {
            this.testing[id] = true;
            try {
                const r = await fetch(`/api/clusters/${id}/test`);
                const d = await r.json();
                this.testResults[id] = d;
            } catch (e) {
                this.testResults[id] = { ok: false, detail: 'Network error' };
            } finally {
                this.testing[id] = false;
                this.testResults = { ...this.testResults };
            }
        },
        // ── Cluster Builder ────────────────────────────────────────
        addCluster() {
            this.clusterError = '';
            this.editingCluster = null;
            this.showClusterModal = true;
        },
        editCluster(c) {
            this.clusterError = '';
            this.editingCluster = c;
            this.showClusterModal = true;
        },
        onClusterSaved() {
            this.showClusterModal = false;
            this.editingCluster = null;
            this.$emit('clusters-changed');
        },
        async deleteCluster(c) {
            this.clusterError = '';
            this.deletingCluster = c.id;
            try {
                const r = await fetch('/api/clusters/' + encodeURIComponent(c.id), { method: 'DELETE' });
                const d = await r.json();
                if (!r.ok) { this.clusterError = await this.hostResponseError(r, 'Delete failed', 'delete', d); return; }
                this.$emit('clusters-changed');
            } catch (e) {
                this.clusterError = 'Network error while deleting the cluster profile';
            } finally {
                this.deletingCluster = null;
            }
        },
        // ── Service restart ────────────────────────────────────────
        // The API answers 202 and detaches, so the response says only that the
        // work was accepted. The truth is whether the service comes back, and
        // the only way to know that is to ask /api/health until it answers.
        async restartService() {
            this.restartState = 'working';
            this.restartMessage = 'Checking the nginx configuration...';
            let accepted;
            try {
                const r = await fetch('/api/service/restart', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ restart_nginx: this.restartNginxHard }),
                });
                accepted = await r.json();
                if (!r.ok) {
                    this.restartState = 'failed';
                    this.restartMessage = await this.hostResponseError(r, 'Restart refused', 'restart', accepted);
                    return;
                }
            } catch (e) {
                this.restartState = 'failed';
                this.restartMessage = 'Could not reach the server to request a restart.';
                return;
            }
            this.restartMessage = 'nginx ' + accepted.nginx_action
                + ' requested, topic-manager restarting. Waiting for it to come back...';
            const came = await this.waitForHealth(60000, 2000);
            if (came) {
                this.restartState = 'ok';
                this.restartMessage = 'Back up: ' + came + ' (nginx ' + accepted.nginx_action + 'ed).';
            } else {
                this.restartState = 'failed';
                this.restartMessage = 'The service DID NOT come back within 60 seconds. '
                    + 'Check: sudo systemctl status topic-manager nginx';
            }
        },
        // Resolves to the version string once /api/health answers, or false on
        // timeout. It must survive the fetch failing outright — the backend is
        // being restarted underneath it, so a rejected fetch is the expected
        // case, not an error.
        async waitForHealth(timeoutMs, intervalMs) {
            const deadline = Date.now() + timeoutMs;
            // Do not accept the answer from a worker that has not restarted
            // yet: wait out one interval before the first probe.
            while (Date.now() < deadline) {
                await new Promise(res => setTimeout(res, intervalMs));
                try {
                    const r = await fetch('/api/health', { cache: 'no-store' });
                    if (r.ok) {
                        const d = await r.json();
                        if (d.status === 'ok') return 'version ' + (d.version || 'unknown');
                    }
                } catch (e) { /* expected while the service is down */ }
            }
            return false;
        },
        // Fresh-install defaults produce THE SAME DOCUMENT AS PPSM.csv, row for row. The two used to
        // disagree; tools/check-ppsm-consistency.sh runs this method under node
        // and fails on any difference except the Generated date. Edit both, or
        // the gate stops the release. Single-quoted literals: never an
        // apostrophe in a cell (hazards[csv-single-quoted-literals]). Always
        // keep the static file in sync with the default rows below.
        async downloadPpsm() {
            // CC-1: only the host status endpoint describes applied configuration.
            const live = Object.fromEntries(await Promise.all(['syslog', 'time', 'nginx'].map(settingsLiveApplied)));
            const config = live.syslog.config || {};
            const syslogPort = config.syslog_port || 'N/A';
            const syslogTransport = settingsSyslogTransport(live.syslog, config);
            const syslogState = config.syslog_enabled === 'true' ? 'Enabled' : 'Disabled';
            const syslogDescription = live.syslog.note || syslogState + '; applied protocol: ' + config.syslog_protocol;
            const rows = [
                ['Jarvis Topic Manager — Ports, Protocols and Services Management (PPSM)', '', '', '', '', ''],
                ['Version', '1.2.0', '', '', '', ''],
                ['Copyright', '(c) 2025-2026 James Rodman', '', '', '', ''],
                ['Scope', 'Every port, protocol and service the Topic Manager host listens on or initiates. Ports marked operator-defined come from configuration. Live applied settings shown; unavailable state is explicit. Static PPSM describes installer defaults.', '', '', '', ''],
                ['Generated', new Date().toISOString().split('T')[0], '', '', '', ''],
                ['', '', '', '', '', ''],
                ['Section', 'Service/Component', 'Port', 'Protocol', 'Direction', 'Description'],
                ['--- INBOUND (to the Topic Manager host) ---', '', '', '', '', ''],
                ['Web', 'HTTPS', '443', 'TCP', 'Inbound', 'Topic Manager web UI and REST API. nginx TLS termination: TLS 1.2 and 1.3 only, FIPS-approved cipher suites (ECDHE with AES-GCM).'],
                ['Web', 'HTTP', '80', 'TCP', 'Inbound', live.nginx.note || (live.nginx.config.http_redirect_enabled === 'true' ? 'Redirect to HTTPS only (301). No content is served on this port. Enabled by applied http_redirect_enabled.' : 'Disabled by applied http_redirect_enabled. Port 80 listener and firewall rule removed.')],
                ['Admin', 'SSH', '22', 'TCP', 'Inbound', 'Operating-system administration of the host (key-based). Not used by the application.'],
                ['--- INTERNAL LOOPBACK (not reachable off the host) ---', '', '', '', '', ''],
                ['App', 'gunicorn (Flask)', '5001', 'TCP', 'Loopback', 'nginx to the application backend, bound to 127.0.0.1 only.'],
                ['App', 'systemd-resolved', '53', 'UDP/TCP', 'Loopback', 'Local stub resolver (127.0.0.53). Host service, not part of the application.'],
                ['--- OUTBOUND (the Topic Manager host initiates) ---', '', '', '', '', ''],
                ['Auth', 'Directory (LDAPS)', '636', 'TCP', 'Outbound', 'Authentication and group-membership check against the directory named in auth.ldap_server. TLS certificate validation is enforced. Plain LDAP (389) is not used.'],
                ['Kafka', 'Kafka brokers', 'operator-defined (commonly 9092, 9093, 9094)', 'TCP', 'Outbound', 'Kafka AdminClient to the brokers named in each cluster profile. Commonly 9092 PLAINTEXT and 9093/9094 SSL or SASL_SSL; the profiles decide.'],
                ['Infra', 'DNS', '53', 'UDP/TCP', 'Outbound', 'Name resolution for the directory and Kafka broker host names.'],
                ['Infra', 'NTP', '123', 'UDP', 'Outbound', 'Time synchronisation by the host time service. Required for TLS validity and audit timestamps. ' + (live.time.note || (live.time.config.ntp_servers ? 'Applied NTP servers: ' + live.time.config.ntp_servers : 'Host configuration unchanged (empty applied ntp_servers).'))],
                ['Logging', 'Syslog', syslogPort, syslogTransport, 'Outbound', syslogDescription + '. Remote forwarding of app audit and nginx logs. This row applies when udp or tcp is selected; port is syslog_port.'],
                ['Logging', 'Syslog over TLS', syslogPort, live.syslog.note ? 'N/A' : 'TCP', 'Outbound', syslogDescription + '. TLS remote forwarding of app audit and nginx logs. This row applies when tls is selected; port is syslog_port.'],
                ['PKI', 'OCSP / CRL', 'N/A', 'N/A', 'Outbound', 'NOT USED. Neither nginx nor the application fetches OCSP responses or CRLs; certificate revocation is not checked online.'],
                ['--- OUTBOUND (online install and upgrade ONLY; none of these at runtime or on an air-gapped host) ---', '', '', '', '', ''],
                ['Install', 'Ubuntu APT repositories', '80/443', 'TCP', 'Outbound', 'OS packages (nginx, python3-venv, polkitd). Port 80 unless the configured mirror is HTTPS.'],
                ['Install', 'PyPI (pypi.org, files.pythonhosted.org)', '443', 'TCP', 'Outbound', 'Python wheels for the pinned dependency set.'],
                ['Install', 'jsDelivr CDN (cdn.jsdelivr.net)', '443', 'TCP', 'Outbound', 'Vue.js runtime, verified against a pinned SHA-256 before use.'],
                ['Install', 'Source repository (operator-supplied --repo-url)', '443', 'TCP', 'Outbound', 'Online upgrade only: git clone of the release source. No default; the offline bundle needs no network at all.'],
                ['Tooling', 'OSV.dev (api.osv.dev)', '443', 'TCP', 'Outbound', 'Software composition analysis (tools/sca-check.sh). Developer or CI workstation only, never the target host.'],
                ['--- DATA AT REST ---', '', '', '', '', ''],
                ['Storage', 'Audit database', 'N/A', 'File', 'Local', '/opt/topic-manager/data/tm.db: audit log, server-side sessions and app settings. File 0600 and directory 0700, owned by the topic-manager service account.'],
                ['Storage', 'Session cookie', 'N/A', 'Cookie', 'Browser', 'Holds the server-side session id only, signed with HMAC-SHA-256. HttpOnly, Secure, SameSite=Lax.'],
                ['Storage', 'Theme and Settings preferences', 'N/A', 'localStorage', 'Browser', 'UI preferences only (theme, last Settings section). No credentials or sensitive data.'],
                ['Storage', 'TLS private key', 'N/A', 'File', 'Local', '/etc/topic-manager/tls/server.key, 0600 root:root on a fresh install. An upgraded host keeps its recorded mode.'],
                ['Storage', 'Application config', 'N/A', 'File', 'Local', '/etc/topic-manager/config.yaml, 0640 root:topic-manager. Holds the session signing key and, if a service account is configured, the LDAP bind password.'],
                ['Storage', 'Backups', 'N/A', 'File', 'Local', '/var/backups/topic-manager/, 0700 root:root. Holds config, TLS key and audit database; archives are 0600.'],
            ];
            const csv = rows.map(r => r.map(v => `"${String(v).replaceAll('"', '""')}"`).join(',')).join('\n');
            const a = document.createElement('a');
            a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
            a.download = 'topic-manager-ppsm.csv';
            a.click();
        },
    },
    mounted() {
        this.loadSettings();
        ['time', 'capacity', 'tls'].forEach(panel => this.loadHostPanel(panel));
        ['syslog', 'time', 'nginx', 'tls'].forEach(domain => this.runHostApply(domain));
    },
    beforeUnmount() {
        this.hostDisposed = true;
        Object.values(this.hostRuns).forEach(run => {
            run.controller.abort();
            if (run.cancel) run.cancel();
            clearTimeout(run.timer);
            if (run.wake) run.wake();
        });
    },
    template: `
<div>
  <div v-if="hostPanels.capacity?.warning" class="host-audit-banner" role="alert">
    ! Audit capacity warning: {{ hostPanels.capacity.rows }} / {{ hostPanels.capacity.max_rows }} rows ({{ hostPanels.capacity.pct }}%).
    <button type="button" class="btn btn-sm" @click="selectGroup('logging')">Review audit retention</button>
  </div>
  <div v-if="['security', 'logging', 'system'].includes(activeGroup) &amp;&amp; !settingsLoaded" class="host-status" role="status">
    {{ settingsError ? '✕ ' + settingsError : '! Loading saved settings…' }}
    <button v-if="settingsError" type="button" class="btn btn-sm" @click="loadSettings">Retry</button>
  </div>

  <!-- v1.1.0 — section rail + panes, the CORTEX Settings pattern. The rail is
       DERIVED from this template by deriveSettingsRail() below: pane ids from
       the v-show conditions, group names from each settings-group-label, and
       section names from the ssec-title of every card between them. A card
       that moves pane moves in the rail in the same edit, because it IS the
       same edit. -->
  <div class="settings-shell">
  <nav class="settings-rail" aria-label="Settings sections">
    <input v-model="railQuery" type="text" class="settings-rail-search" placeholder="Search settings&hellip;"
           aria-label="Search settings" @keydown.escape="railQuery = ''">
    <button v-for="g in railGroups" :key="g.id" type="button" class="settings-rail-item"
            :class="{ active: activeGroup === g.id, dimmed: railQuery && !railMatch(g) }"
            :aria-current="activeGroup === g.id ? 'true' : null"
            @click="selectGroup(g.id)">{{ g.name }}</button>
  </nav>
  <div class="settings-content">

  <!-- ═══ General ═══ -->
  <div v-show="activeGroup==='general'" class="settings-pane">
  <div class="settings-group-label">General</div>

  <!-- Cluster Profiles -->
  <div class="ssec">
    <div class="ssec-title" style="display:flex;align-items:center;justify-content:space-between">
      <span>Cluster Profiles</span>
      <button class="btn btn-sm btn-primary" @click="addCluster">+ Add Cluster</button>
    </div>
    <div v-if="!clusters.length" style="font-size:.72rem;color:var(--text-muted);margin-bottom:8px">
      No cluster profile is configured yet. Add one with + Add Cluster.
    </div>
    <div class="cp-row" v-for="c in clusters" :key="c.id">
      <div class="cp-dot" :style="{ background: c.id === activeClusterId ? 'var(--accent-green)' : 'var(--text-muted)' }"></div>
      <div style="flex:1;min-width:0">
        <div class="cp-name">{{ c.name }}</div>
        <div class="cp-hosts">{{ c.bootstrap_servers }}</div>
        <div class="cp-hosts" :style="{ color: c.security_protocol === 'PLAINTEXT' ? 'var(--text-muted)' : 'var(--accent-cyan)' }">
          {{ c.security_protocol }}
          <span v-if="testResults[c.id]" :style="{ color: testResults[c.id].ok ? 'var(--accent-green)' : 'var(--accent-red)', marginLeft:'8px' }">
            {{ testResults[c.id].ok ? '● Connected' : '✕ ' + (testResults[c.id].detail?.error || 'Connection failed') }}
          </span>
        </div>
      </div>
      <div class="cp-acts">
        <button class="btn btn-sm" @click="testCluster(c.id)" :disabled="testing[c.id]">
          <span v-if="testing[c.id]" class="spinner" style="width:10px;height:10px"></span>
          <span v-else>Test</span>
        </button>
        <button class="btn btn-sm" @click="editCluster(c)">Edit</button>
        <button class="btn btn-sm" @click="deleteCluster(c)"
                :disabled="deletingCluster === c.id || clusters.length < 2"
                :title="clusters.length < 2 ? 'The last cluster profile cannot be deleted' : 'Delete this cluster profile'">
          <span v-if="deletingCluster === c.id" class="spinner" style="width:10px;height:10px"></span>
          <span v-else>Delete</span>
        </button>
        <button class="btn btn-sm" v-if="c.id !== activeClusterId" @click="$emit('cluster-changed', c.id)">Set Active</button>
        <span v-else class="stig" style="font-size:.58rem">Active</span>
      </div>
    </div>
    <div v-if="clusterError" style="margin-top:8px;color:var(--accent-red);font-size:.72rem">{{ clusterError }}</div>
    <div style="font-size:.66rem;color:var(--text-muted);margin-top:8px">
      Profiles are stored in <code style="font-family:var(--mono)">/etc/topic-manager/clusters.d/clusters.yaml</code>.
      Changes take effect immediately — no restart is needed, and every change is written to the audit log.
    </div>
  </div>

  <!-- Branding / Banner -->
  <!-- These sections are NOT rendered until /api/settings has actually
       answered. Rendering seeded defaults and letting the operator toggle one
       is how a failed load became a global overwrite of the real banner. -->
  <div class="ssec" v-if="!settingsLoaded">
    <div class="ssec-title">Consent &amp; Classification Banner</div>
    <div v-if="settingsError" style="font-size:.72rem;color:var(--accent-red)">
      {{ settingsError }}
      <button class="btn btn-sm" style="margin-left:10px" @click="loadSettings">Retry</button>
    </div>
    <div v-else style="font-size:.72rem;color:var(--text-muted)">
      <span class="spinner" style="width:10px;height:10px"></span> Loading saved settings...
    </div>
  </div>

  <!-- DoW Consent Banner -->
  <div class="ssec" v-if="settingsLoaded">
    <div class="ssec-title">DoW Consent Banner</div>
    <div class="srow">
      <div class="srow-lbl">
        Enable Consent Banner
        <span class="hint">Shows a U.S. Government consent-to-monitor notice after Sign In is clicked. User must click I Agree to proceed.</span>
      </div>
      <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-size:.72rem">
        <input type="checkbox" v-model="dowEnabled" @change="saveDow" style="accent-color:var(--accent)"> Enabled
      </label>
    </div>
  </div>

  <!-- The custom selection panel. KEPT AS IT IS on the owner's direction, so
       the banner can be set by hand if a DoD-issued one has to come down. -->
  <div class="ssec" v-if="settingsLoaded">
    <div class="ssec-title">Branding &amp; Classification Banner</div>
    <div v-if="settingsSaveError" style="margin-bottom:8px;color:var(--accent-red);font-size:.72rem">{{ settingsSaveError }}</div>
    <div class="srow">
      <div class="srow-lbl">Enable Banner<span class="hint">Shows at top and bottom of every page</span></div>
      <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-size:.72rem">
        <input type="checkbox" v-model="bannerEnabled" @change="saveBanner" style="accent-color:var(--accent)"> Enabled
      </label>
    </div>
    <div class="srow">
      <div class="srow-lbl">Banner Text</div>
      <input class="fc" type="text" v-model="bannerText" @change="saveBanner" style="width:200px;font-size:.75rem;padding:5px 9px">
    </div>
    <div class="srow">
      <div class="srow-lbl">Background Color</div>
      <select class="fc" v-model="bannerBg" @change="saveBanner" style="width:200px;font-size:.75rem;padding:5px 9px">
        <option v-for="c in bannerColors" :key="c.val" :value="c.val">{{ c.label }}</option>
      </select>
    </div>
    <div class="srow">
      <div class="srow-lbl">Text Color</div>
      <select class="fc" v-model="bannerFg" @change="saveBanner" style="width:200px;font-size:.75rem;padding:5px 9px">
        <option value="white">White</option>
        <option value="black">Black</option>
        <option value="grey">Grey</option>
      </select>
    </div>
    <!-- Preview -->
    <div style="margin-top:12px">
      <div style="font-size:.62rem;color:var(--text-muted);margin-bottom:6px">Preview:</div>
      <div :style="{ background: bannerHex, color: fgColor, textAlign:'center', padding:'3px 0', fontSize:'.72rem', fontWeight:'700', letterSpacing:'.1em', textTransform:'uppercase', borderRadius:'4px' }">
        {{ bannerEnabled ? bannerText : '(disabled)' }}
      </div>
    </div>
  </div>
  </div>

  <!-- ═══ Security ═══ -->
  <div v-show="activeGroup==='security'" class="settings-pane">
  <div class="settings-group-label">Security</div>
  <div class="ssec host-settings">
    <div class="ssec-title">Sessions</div>
    <form @submit.prevent="saveHostSection('sessions')">
    <fieldset :disabled="!settingsLoaded || sectionSaving.sessions">
    <div class="srow"><div class="srow-lbl"><label for="session_max_concurrent">Concurrent sessions</label><span class="hint">0 means unlimited. This setting takes precedence over the configuration file.</span></div><input id="session_max_concurrent" class="fc" type="number" v-model="hostSettings.session_max_concurrent" min="0" max="50" step="1"></div>
    <button class="btn btn-sm btn-primary" type="submit">{{ sectionSaving.sessions ? 'Saving…' : 'Save' }}</button>
    </fieldset>
    </form>
    <p class="host-status" role="status">{{ sectionMessages.sessions }}</p>
  </div>
  <div class="ssec host-settings">
    <div class="ssec-title">Rate limiting</div>
    <form @submit.prevent="saveHostSection('rate')">
    <fieldset :disabled="!settingsLoaded || sectionSaving.rate">
    <div class="srow"><div class="srow-lbl"><label for="ratelimit_login_per_min">Login requests per minute</label></div><input id="ratelimit_login_per_min" class="fc" type="number" v-model="hostSettings.ratelimit_login_per_min" min="1" max="600" step="1"></div>
    <div class="srow"><div class="srow-lbl"><label for="ratelimit_login_burst">Login burst</label></div><input id="ratelimit_login_burst" class="fc" type="number" v-model="hostSettings.ratelimit_login_burst" min="0" max="100" step="1"></div>
    <div class="srow"><div class="srow-lbl"><label for="ratelimit_api_per_min">API requests per minute</label></div><input id="ratelimit_api_per_min" class="fc" type="number" v-model="hostSettings.ratelimit_api_per_min" min="10" max="6000" step="1"></div>
    <div class="srow"><div class="srow-lbl"><label for="ratelimit_api_burst">API burst</label></div><input id="ratelimit_api_burst" class="fc" type="number" v-model="hostSettings.ratelimit_api_burst" min="0" max="1000" step="1"></div>
    <div class="srow"><div class="srow-lbl"><label for="ratelimit_conn_per_ip">Concurrent connections per IP</label></div><input id="ratelimit_conn_per_ip" class="fc" type="number" v-model="hostSettings.ratelimit_conn_per_ip" min="1" max="500" step="1"></div>
    <button class="btn btn-sm btn-primary" type="submit">{{ sectionSaving.rate ? 'Saving…' : 'Save' }}</button>
    </fieldset>
    </form>
    <p class="host-status" role="status">{{ sectionMessages.rate }}</p>
    <p class="host-note">Save changes first. Apply to host uses the saved settings.</p>
    <div class="host-actions">
      <button type="button" class="btn btn-sm" @click="applyToHost('nginx')" :disabled="!settingsLoaded || sectionSaving.rate || sectionSaving.redirect || applyJobs.nginx.busy || applyJobs.nginx.uncertain">Apply to host</button>
      <button type="button" class="btn btn-sm" @click="runHostApply('nginx')" :disabled="applyJobs.nginx.busy">Check status</button>
    </div>
    <div class="host-status" role="status" aria-live="polite" :data-state="applyJobs.nginx.state">
      <strong>{{ statusGlyph(applyJobs.nginx.state) }} {{ applyJobs.nginx.state }}</strong>
      <span>{{ applyJobs.nginx.message }}</span>
      <span v-if="applyJobs.nginx.job">Job: {{ applyJobs.nginx.job }}</span>
      <ul v-if="applyJobs.nginx.details.length"><li v-for="(detail, i) in applyJobs.nginx.details" :key="i">{{ detail }}</li></ul>
    </div>
  </div>
  <div class="ssec host-settings">
    <div class="ssec-title">HTTP redirect</div>
    <form @submit.prevent="saveHostSection('redirect')">
    <fieldset :disabled="!settingsLoaded || sectionSaving.redirect">
    <div class="srow"><div class="srow-lbl"><label for="http_redirect_enabled">Redirect HTTP to HTTPS</label><span class="hint">Network: disabling removes the port 80 listener and its firewall rule when applied.</span></div><select id="http_redirect_enabled" class="fc" v-model="hostSettings.http_redirect_enabled"><option value="true">Enabled</option><option value="false">Disabled</option></select></div>
    <button class="btn btn-sm btn-primary" type="submit">{{ sectionSaving.redirect ? 'Saving…' : 'Save' }}</button>
    </fieldset>
    </form>
    <p class="host-status" role="status">{{ sectionMessages.redirect }}</p>
    <p class="host-note">Save changes first. Apply to host uses the saved settings.</p>
    <div class="host-actions">
      <button type="button" class="btn btn-sm" @click="applyToHost('nginx')" :disabled="!settingsLoaded || sectionSaving.rate || sectionSaving.redirect || applyJobs.nginx.busy || applyJobs.nginx.uncertain">Apply to host</button>
      <button type="button" class="btn btn-sm" @click="runHostApply('nginx')" :disabled="applyJobs.nginx.busy">Check status</button>
    </div>
    <div class="host-status" role="status" aria-live="polite" :data-state="applyJobs.nginx.state">
      <strong>{{ statusGlyph(applyJobs.nginx.state) }} {{ applyJobs.nginx.state }}</strong>
      <span>{{ applyJobs.nginx.message }}</span>
      <span v-if="applyJobs.nginx.job">Job: {{ applyJobs.nginx.job }}</span>
      <ul v-if="applyJobs.nginx.details.length"><li v-for="(detail, i) in applyJobs.nginx.details" :key="i">{{ detail }}</li></ul>
    </div>
  </div>
  <div class="ssec host-settings">
    <div class="ssec-title">TLS &amp; certificate</div>
    <div class="host-readout">
      <div class="host-actions"><strong>Current TLS configuration</strong><button type="button" class="btn btn-sm" @click="loadHostPanel('tls')" :disabled="hostPanelLoading.tls">Refresh status</button></div>
      <p v-if="hostPanelErrors.tls" class="host-status" data-state="failed" role="alert">✕ {{ hostPanelErrors.tls }} Any displayed values are from the last successful refresh.</p>
      <p v-if="!hostPanels.tls" class="host-note">{{ hostPanelLoading.tls ? 'Loading status…' : 'Status unavailable.' }}</p>
      <dl v-if="hostPanels.tls" class="host-facts">
        <dt>Protocols</dt><dd>{{ hostPanels.tls.protocols.join(', ') }}</dd>
        <dt>Ciphers</dt><dd>{{ hostPanels.tls.ciphers.join(', ') }}</dd>
        <dt>FIPS mode</dt><dd>{{ hostPanels.tls.fips_mode ? '✓ Enabled' : '! Disabled' }}</dd>
        <dt>Subject</dt><dd>{{ hostPanels.tls.cert?.subject || 'Unavailable' }}</dd>
        <dt>Issuer</dt><dd>{{ hostPanels.tls.cert?.issuer || 'Unavailable' }}</dd>
        <dt>Expires</dt><dd>{{ hostPanels.tls.cert?.not_after || 'Unavailable' }}</dd>
        <dt>Key type</dt><dd>{{ hostPanels.tls.cert?.key_type || 'Unavailable' }}</dd>
        <dt>Subject alternative names</dt><dd>{{ hostPanels.tls.cert?.sans?.join(', ') || 'None' }}</dd>
        <dt>Certificate chain</dt><dd>{{ hostPanels.tls.chain_present ? '✓ Present' : '! Not present' }}</dd>
      </dl>
    </div>
    <form ref="certForm" @submit.prevent="submitCertificate">
      <fieldset :disabled="!settingsLoaded || applyJobs.tls.busy || applyJobs.tls.uncertain">
        <p class="host-note">Upload PEM files. The private key must be unencrypted. Applying validates and installs the certificate on the host.</p>
        <div class="srow"><label for="tls-cert">Certificate (PEM)</label><input id="tls-cert" name="cert" type="file" accept=".pem,.crt" required></div>
        <div class="srow"><label for="tls-key">Private key (PEM)</label><input id="tls-key" name="key" type="file" accept=".pem,.key" required></div>
        <div class="srow"><label for="tls-chain">Chain (optional PEM)</label><input id="tls-chain" name="chain" type="file" accept=".pem,.crt"></div>
        <button type="submit" class="btn btn-sm btn-primary">Apply to host</button>
      </fieldset>
    </form>
    <button type="button" class="btn btn-sm" @click="runHostApply('tls')" :disabled="applyJobs.tls.busy">Check status</button>
    <div class="host-status" role="status" aria-live="polite" :data-state="applyJobs.tls.state">
      <strong>{{ statusGlyph(applyJobs.tls.state) }} {{ applyJobs.tls.state }}</strong>
      <span>{{ applyJobs.tls.message }}</span>
      <span v-if="applyJobs.tls.job">Job: {{ applyJobs.tls.job }}</span>
      <ul v-if="applyJobs.tls.details.length"><li v-for="(detail, i) in applyJobs.tls.details" :key="i">{{ detail }}</li></ul>
      <dl v-if="applyJobs.tls.applied" class="host-facts">
        <dt>Last applied</dt><dd>{{ applyJobs.tls.applied_at || 'Unavailable' }}</dd>
        <dt>Subject</dt><dd>{{ applyJobs.tls.applied.subject }}</dd>
        <dt>Issuer</dt><dd>{{ applyJobs.tls.applied.issuer }}</dd>
        <dt>Expires</dt><dd>{{ applyJobs.tls.applied.not_after }}</dd>
        <dt>Key type</dt><dd>{{ applyJobs.tls.applied.key_type }}</dd>
        <dt>Chain certificates</dt><dd>{{ applyJobs.tls.applied.chain_count }}</dd>
      </dl>
    </div>
  </div>
  </div>

  <!-- ═══ Logging ═══ -->
  <div v-show="activeGroup==='logging'" class="settings-pane">
  <div class="settings-group-label">Logging</div>
  <div class="ssec host-settings">
    <div class="ssec-title">Remote syslog</div>
    <form @submit.prevent="saveHostSection('syslog')">
    <fieldset :disabled="!settingsLoaded || sectionSaving.syslog">
    <div class="srow"><div class="srow-lbl"><label for="syslog_enabled">Remote forwarding</label></div><select id="syslog_enabled" class="fc" v-model="hostSettings.syslog_enabled"><option value="true">Enabled</option><option value="false">Disabled</option></select></div>
    <div class="srow"><div class="srow-lbl"><label for="syslog_host">Syslog host</label></div><input id="syslog_host" class="fc" type="text" v-model="hostSettings.syslog_host" maxlength="253" placeholder="logs.example.org"></div>
    <div class="srow"><div class="srow-lbl"><label for="syslog_port">Syslog port</label></div><input id="syslog_port" class="fc" type="number" v-model="hostSettings.syslog_port" min="1" max="65535" step="1"></div>
    <div class="srow"><div class="srow-lbl"><label for="syslog_protocol">Syslog protocol</label></div><select id="syslog_protocol" class="fc" v-model="hostSettings.syslog_protocol"><option value="udp">UDP</option><option value="tcp">TCP</option><option value="tls">TLS (TCP)</option></select></div>
    <div class="srow"><div class="srow-lbl"><label for="syslog_app_id">Application ID</label></div><input id="syslog_app_id" class="fc" type="text" v-model="hostSettings.syslog_app_id" maxlength="48"></div>
    <button class="btn btn-sm btn-primary" type="submit">{{ sectionSaving.syslog ? 'Saving…' : 'Save' }}</button>
    </fieldset>
    </form>
    <p class="host-status" role="status">{{ sectionMessages.syslog }}</p>
    <p class="host-note">Save changes first. Apply to host uses the saved settings.</p>
    <div class="host-actions">
      <button type="button" class="btn btn-sm" @click="applyToHost('syslog')" :disabled="!settingsLoaded || sectionSaving.syslog || applyJobs.syslog.busy || applyJobs.syslog.uncertain">Apply to host</button>
      <button type="button" class="btn btn-sm" @click="runHostApply('syslog')" :disabled="applyJobs.syslog.busy">Check status</button>
    </div>
    <div class="host-status" role="status" aria-live="polite" :data-state="applyJobs.syslog.state">
      <strong>{{ statusGlyph(applyJobs.syslog.state) }} {{ applyJobs.syslog.state }}</strong>
      <span>{{ applyJobs.syslog.message }}</span>
      <span v-if="applyJobs.syslog.job">Job: {{ applyJobs.syslog.job }}</span>
      <ul v-if="applyJobs.syslog.details.length"><li v-for="(detail, i) in applyJobs.syslog.details" :key="i">{{ detail }}</li></ul>
    </div>
  </div>
  <div class="ssec host-settings">
    <div class="ssec-title">Audit retention</div>
    <form @submit.prevent="saveHostSection('retention')">
    <fieldset :disabled="!settingsLoaded || sectionSaving.retention">
    <div class="srow"><div class="srow-lbl"><label for="audit_retention_days">Retention (days)</label></div><input id="audit_retention_days" class="fc" type="number" v-model="hostSettings.audit_retention_days" min="30" max="3650" step="1"></div>
    <div class="srow"><div class="srow-lbl"><label for="audit_max_rows">Maximum rows</label></div><input id="audit_max_rows" class="fc" type="number" v-model="hostSettings.audit_max_rows" min="10000" max="50000000" step="1"></div>
    <div class="srow"><div class="srow-lbl"><label for="audit_warn_pct">Warning threshold (%)</label></div><input id="audit_warn_pct" class="fc" type="number" v-model="hostSettings.audit_warn_pct" min="50" max="95" step="1"></div>
    <button class="btn btn-sm btn-primary" type="submit">{{ sectionSaving.retention ? 'Saving…' : 'Save' }}</button>
    </fieldset>
    </form>
    <p class="host-status" role="status">{{ sectionMessages.retention }}</p>
    <div class="host-readout">
      <div class="host-actions"><strong>Audit capacity</strong><button type="button" class="btn btn-sm" @click="loadHostPanel('capacity')" :disabled="hostPanelLoading.capacity">Refresh status</button></div>
      <p v-if="hostPanelErrors.capacity" class="host-status" data-state="failed" role="alert">✕ {{ hostPanelErrors.capacity }} Any displayed values are from the last successful refresh.</p>
      <p v-if="!hostPanels.capacity" class="host-note">{{ hostPanelLoading.capacity ? 'Loading status…' : 'Status unavailable.' }}</p>
      <div v-if="hostPanels.capacity">
        <div class="host-capacity-bar" role="progressbar" aria-label="Audit capacity used" aria-valuemin="0" aria-valuemax="100" :aria-valuenow="Math.min(100, Math.max(0, hostPanels.capacity.pct))" :aria-valuetext="hostPanels.capacity.pct + '% used'">
          <span :style="{ width: Math.min(100, Math.max(0, hostPanels.capacity.pct)) + '%' }"></span>
        </div>
        <p class="host-status" :data-state="hostPanels.capacity.warning ? 'warning' : 'ok'">{{ hostPanels.capacity.warning ? '! Warning: audit capacity threshold reached.' : '✓ Audit capacity below warning threshold.' }} {{ hostPanels.capacity.pct }}% used (warning at {{ hostPanels.capacity.warn_pct }}%).</p>
      </div>
      <dl v-if="hostPanels.capacity" class="host-facts">
        <dt>Rows</dt><dd>{{ hostPanels.capacity.rows }}</dd>
        <dt>Maximum rows</dt><dd>{{ hostPanels.capacity.max_rows }}</dd>
        <dt>Retention days</dt><dd>{{ hostPanels.capacity.retention_days }}</dd>
        <dt>Oldest entry</dt><dd>{{ hostPanels.capacity.oldest || 'None' }}</dd>
        <dt>Last prune</dt><dd>{{ hostPanels.capacity.last_prune || 'None' }}</dd>
      </dl>
    </div>
  </div>
  </div>

  <!-- ═══ System ═══ -->
  <div v-show="activeGroup==='system'" class="settings-pane">
  <div class="settings-group-label">System</div>

  <!-- Service Control -->
  <div class="ssec">
    <div class="ssec-title">Service Control</div>
    <div class="srow">
      <div class="srow-lbl">
        Restart Topic Manager
        <span class="hint">Restarts topic-manager.service and reloads nginx. The nginx configuration is tested first; if the test fails nothing is touched.</span>
      </div>
      <button class="btn btn-sm" @click="restartService" :disabled="restartState === 'working'">
        <span v-if="restartState === 'working'" class="spinner" style="width:10px;height:10px"></span>
        <span v-else>↻ Restart Services</span>
      </button>
    </div>
    <div class="srow">
      <div class="srow-lbl">
        Hard-restart nginx
        <span class="hint">Off: nginx is reloaded (graceful). On: nginx is fully restarted, which drops every in-flight request for all users.</span>
      </div>
      <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-size:.72rem">
        <input type="checkbox" v-model="restartNginxHard" :disabled="restartState === 'working'" style="accent-color:var(--accent)"> Hard restart
      </label>
    </div>
    <div v-if="restartMessage" :style="{ marginTop:'8px', fontSize:'.72rem', color: restartColour }">
      {{ restartMessage }}
    </div>
  </div>
  <div class="ssec host-settings">
    <div class="ssec-title">Time source</div>
    <form @submit.prevent="saveHostSection('time')">
    <fieldset :disabled="!settingsLoaded || sectionSaving.time">
    <div class="srow"><div class="srow-lbl"><label for="ntp_servers">NTP servers</label><span class="hint">1–5 comma-separated hostnames or IP addresses. Empty leaves the host configuration untouched.</span></div><input id="ntp_servers" class="fc" type="text" v-model="hostSettings.ntp_servers" placeholder="time.example.org, 2001:db8::123"></div>
    <button class="btn btn-sm btn-primary" type="submit">{{ sectionSaving.time ? 'Saving…' : 'Save' }}</button>
    </fieldset>
    </form>
    <p class="host-status" role="status">{{ sectionMessages.time }}</p>
    <p class="host-note">Save changes first. Apply to host uses the saved settings.</p>
    <div class="host-actions">
      <button type="button" class="btn btn-sm" @click="applyToHost('time')" :disabled="!settingsLoaded || sectionSaving.time || applyJobs.time.busy || applyJobs.time.uncertain">Apply to host</button>
      <button type="button" class="btn btn-sm" @click="runHostApply('time')" :disabled="applyJobs.time.busy">Check status</button>
    </div>
    <div class="host-status" role="status" aria-live="polite" :data-state="applyJobs.time.state">
      <strong>{{ statusGlyph(applyJobs.time.state) }} {{ applyJobs.time.state }}</strong>
      <span>{{ applyJobs.time.message }}</span>
      <span v-if="applyJobs.time.job">Job: {{ applyJobs.time.job }}</span>
      <ul v-if="applyJobs.time.details.length"><li v-for="(detail, i) in applyJobs.time.details" :key="i">{{ detail }}</li></ul>
    </div>
    <div class="host-readout">
      <div class="host-actions"><strong>Current time source</strong><button type="button" class="btn btn-sm" @click="loadHostPanel('time')" :disabled="hostPanelLoading.time">Refresh status</button></div>
      <p v-if="hostPanelErrors.time" class="host-status" data-state="failed" role="alert">✕ {{ hostPanelErrors.time }} Any displayed values are from the last successful refresh.</p>
      <p v-if="!hostPanels.time" class="host-note">{{ hostPanelLoading.time ? 'Loading status…' : 'Status unavailable.' }}</p>
      <dl v-if="hostPanels.time" class="host-facts">
        <dt>Service</dt><dd>{{ hostPanels.time.source }}</dd>
        <dt>Servers</dt><dd>{{ hostPanels.time.servers.join(', ') || 'Host default' }}</dd>
        <dt>Synchronisation</dt><dd>{{ hostPanels.time.synced ? '✓ Synchronised' : '! Not synchronised' }}</dd>
        <dt>Offset (ms)</dt><dd>{{ hostPanels.time.offset_ms ?? 'Unavailable' }}</dd>
        <dt>Stratum</dt><dd>{{ hostPanels.time.stratum ?? 'Unavailable' }}</dd>
        <dt>Last sync</dt><dd>{{ hostPanels.time.last_sync || 'Unavailable' }}</dd>
      </dl>
    </div>
  </div>
  </div>

  <!-- ═══ Support ═══ -->
  <div v-show="activeGroup==='support'" class="settings-pane">
  <div class="settings-group-label">Support</div>

  <!-- Support / PPSM -->
  <div class="ssec">
    <div class="ssec-title">Support &amp; Compliance Downloads</div>
    <div class="srow">
      <div class="srow-lbl">PPSM Export<span class="hint">Ports, Protocols &amp; Services Management</span></div>
      <button class="btn btn-sm" @click="downloadPpsm" :disabled="!settingsLoaded">⬇ Download PPSM</button>
    </div>
  </div>

  <!-- About -->
  <div class="ssec">
    <div class="ssec-title">About</div>
    <div class="srow"><div class="srow-lbl">Product</div><div class="srow-val">Jarvis Topic Manager</div></div>
    <div class="srow"><div class="srow-lbl">Version</div><div class="srow-val">{{ version }}</div></div>
    <div class="srow"><div class="srow-lbl">Copyright</div><div class="srow-val">© 2025–2026 James Rodman</div></div>
    <div class="srow">
      <div class="srow-lbl">Third-Party Software</div>
      <button class="btn btn-sm" @click="$emit('open-about')">View Licenses</button>
    </div>
  </div>
  </div>

  </div>
  </div>

  <ClusterModal
    v-if="showClusterModal"
    :cluster="editingCluster"
    :protocols="protocols"
    :mechanisms="mechanisms"
    @close="showClusterModal = false; editingCluster = null"
    @saved="onClusterSaved"
  />

</div>
`,
};

// ── Settings rail, DERIVED FROM THE MARKUP ────────────────────────────────────
// The CORTEX lesson (its v3.169.1): a rail that carries its own hand-written
// list of which sections sit in which pane drifts from the markup, and a search
// then jumps the operator to a pane that does not hold the card they asked for.
// So there is no second list. Pane ids come from the v-show conditions, group
// names from each settings-group-label, and section names from each ssec-title.
//
// These are function DECLARATIONS on purpose: SettingsTab.data() calls them,
// and declarations are hoisted, so the order in this file cannot break that.
const SETTINGS_ENTITIES = {
    // The apostrophe is written as a unicode escape: a literal one inside a
    // single-quoted string in this file blanks the whole Settings tab
    // (hazards[csv-single-quoted-literals]).
    amp: '&', lt: '<', gt: '>', quot: '"', apos: '\u0027', nbsp: ' ',
    mdash: '—', ndash: '–', middot: '·', hellip: '…',
};

function settingsDecodeEntities(text) {
    return String(text).replace(/&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z][a-zA-Z0-9]*);/g, (whole, ref) => {
        if (ref.charAt(0) === '#') {
            const hex = ref.charAt(1) === 'x' || ref.charAt(1) === 'X';
            const cp = Number.parseInt(hex ? ref.slice(2) : ref.slice(1), hex ? 16 : 10);
            return Number.isFinite(cp) ? String.fromCodePoint(cp) : whole;
        }
        return Object.hasOwn(SETTINGS_ENTITIES, ref)
            ? SETTINGS_ENTITIES[ref] : whole;
    });
}

// Punctuation-insensitive, so "ppsm", "support compliance" and "classification"
// all find their card.
function settingsSearchNorm(text) {
    return String(text).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function deriveSettingsRail(template) {
    const paneRe = /<div\s+v-show="activeGroup===['"]([^'"]+)['"]/g;
    const labelRe = /<div class="settings-group-label">([\s\S]*?)<\/div>/;
    // Both title shapes in use: <div class="ssec-title">Name</div> and the
    // Cluster Profiles one, which wraps the name in a <span> beside a button.
    const titleRe = /<div class="ssec-title"[^>]*>\s*(?:<span>)?([^<]+)/g;
    // Row labels are search terms too: "PPSM" names a row, not a card, and an
    // operator looking for the PPSM export types "ppsm".
    const termRe = /<div class="srow-lbl">([\s\S]*?)<\/div>/g;
    const starts = [];
    let m;
    while ((m = paneRe.exec(template)) !== null) starts.push({ id: m[1], at: m.index });
    return starts.map((pane, i) => {
        const slice = template.slice(pane.at, i + 1 < starts.length ? starts[i + 1].at : template.length);
        const label = labelRe.exec(slice);
        const sections = [];
        titleRe.lastIndex = 0;
        let t;
        while ((t = titleRe.exec(slice)) !== null) sections.push(settingsDecodeEntities(t[1]).trim());
        const terms = [];
        termRe.lastIndex = 0;
        while ((t = termRe.exec(slice)) !== null) terms.push(settingsDecodeEntities(t[1].replaceAll(/<[^<>]*>/g, ' ')).trim());
        return {
            id: pane.id,
            name: label ? settingsDecodeEntities(label[1]).trim() : pane.id,
            sections,
            terms,
        };
    });
}

let SETTINGS_RAIL_CACHE = null;
function settingsRailGroups() {
    if (!SETTINGS_RAIL_CACHE) SETTINGS_RAIL_CACHE = deriveSettingsRail(SettingsTab.template);
    // A fresh copy per instance: two instances sharing one array is how
    // read-only state stops being read-only.
    return SETTINGS_RAIL_CACHE.map(g => ({ id: g.id, name: g.name, sections: g.sections.slice(), terms: g.terms.slice() }));
}

const SETTINGS_GROUP_KEY = 'tmSettingsGroup';

// The saved group is honoured only if it names a pane that exists NOW — a
// value saved by a later release, or typed into devtools, falls back to the
// first pane rather than showing an empty page. Storage that throws (a
// locked-down profile) falls back the same way instead of taking the tab down.
function settingsInitialGroup(groups) {
    let saved = null;
    try { saved = localStorage.getItem(SETTINGS_GROUP_KEY); } catch (e) { saved = null; }
    if (groups.some(g => g.id === saved)) return saved;
    return groups.length ? groups[0].id : '';
}
