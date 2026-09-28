// Jarvis Topic Manager — Settings Tab
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
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
            this.settingsSaveError = '';
            try {
                const r = await fetch('/api/settings', {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload),
                });
                if (!r.ok) {
                    this.settingsSaveError = 'Save failed (HTTP ' + r.status + ').';
                    return false;
                }
            } catch (e) {
                this.settingsSaveError = 'Save failed: the server could not be reached.';
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
                if (!r.ok) { this.clusterError = d.error || 'Delete failed'; return; }
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
                    this.restartMessage = accepted.error || ('Refused (HTTP ' + r.status + ')');
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
        // THE SAME DOCUMENT AS PPSM.csv, row for row (v1.1.0). The two used to
        // disagree; tools/check-ppsm-consistency.sh runs this method under node
        // and fails on any difference except the Generated date. Edit both, or
        // the gate stops the release. Single-quoted literals: never an
        // apostrophe in a cell (hazards[csv-single-quoted-literals]), and never
        // a double quote, which this naive CSV join does not escape.
        downloadPpsm() {
            const rows = [
                ['Jarvis Topic Manager — Ports, Protocols and Services Management (PPSM)', '', '', '', '', ''],
                ['Version', '1.1.1', '', '', '', ''],
                ['Copyright', '(c) 2025-2026 James Rodman', '', '', '', ''],
                ['Scope', 'Every port, protocol and service the Topic Manager host listens on or initiates. Ports marked operator-defined come from configuration.', '', '', '', ''],
                ['Generated', new Date().toISOString().split('T')[0], '', '', '', ''],
                ['', '', '', '', '', ''],
                ['Section', 'Service/Component', 'Port', 'Protocol', 'Direction', 'Description'],
                ['--- INBOUND (to the Topic Manager host) ---', '', '', '', '', ''],
                ['Web', 'HTTPS', '443', 'TCP', 'Inbound', 'Topic Manager web UI and REST API. nginx TLS termination: TLS 1.2 and 1.3 only, FIPS-approved cipher suites (ECDHE with AES-GCM).'],
                ['Web', 'HTTP', '80', 'TCP', 'Inbound', 'Redirect to HTTPS only (301). No content is served on this port.'],
                ['Admin', 'SSH', '22', 'TCP', 'Inbound', 'Operating-system administration of the host (key-based). Not used by the application.'],
                ['--- INTERNAL LOOPBACK (not reachable off the host) ---', '', '', '', '', ''],
                ['App', 'gunicorn (Flask)', '5001', 'TCP', 'Loopback', 'nginx to the application backend, bound to 127.0.0.1 only.'],
                ['App', 'systemd-resolved', '53', 'UDP/TCP', 'Loopback', 'Local stub resolver (127.0.0.53). Host service, not part of the application.'],
                ['--- OUTBOUND (the Topic Manager host initiates) ---', '', '', '', '', ''],
                ['Auth', 'Directory (LDAPS)', '636', 'TCP', 'Outbound', 'Authentication and group-membership check against the directory named in auth.ldap_server. TLS certificate validation is enforced. Plain LDAP (389) is not used.'],
                ['Kafka', 'Kafka brokers', 'operator-defined (commonly 9092, 9093, 9094)', 'TCP', 'Outbound', 'Kafka AdminClient to the brokers named in each cluster profile. Commonly 9092 PLAINTEXT and 9093/9094 SSL or SASL_SSL; the profiles decide.'],
                ['Infra', 'DNS', '53', 'UDP/TCP', 'Outbound', 'Name resolution for the directory and Kafka broker host names.'],
                ['Infra', 'NTP', '123', 'UDP', 'Outbound', 'Time synchronisation by the host time service. Required for TLS validity and audit timestamps.'],
                ['Logging', 'Syslog', '514', 'UDP/TCP', 'Outbound', 'PLANNED for v1.2.0 (remote syslog). Not used by this release: the application logs to the local syslog socket only.'],
                ['Logging', 'Syslog over TLS', '6514', 'TCP', 'Outbound', 'PLANNED for v1.2.0 (remote syslog over TLS). Not used by this release.'],
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
            const csv = rows.map(r => r.map(v => `"${v}"`).join(',')).join('\n');
            const a = document.createElement('a');
            a.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
            a.download = 'topic-manager-ppsm.csv';
            a.click();
        },
    },
    mounted() { this.loadSettings(); },
    template: `
<div>

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
  </div>

  <!-- ═══ Support ═══ -->
  <div v-show="activeGroup==='support'" class="settings-pane">
  <div class="settings-group-label">Support</div>

  <!-- Support / PPSM -->
  <div class="ssec">
    <div class="ssec-title">Support &amp; Compliance Downloads</div>
    <div class="srow">
      <div class="srow-lbl">PPSM Export<span class="hint">Ports, Protocols &amp; Services Management</span></div>
      <button class="btn btn-sm" @click="downloadPpsm">⬇ Download PPSM</button>
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

  <!-- v1.2.0 adds its groups HERE (Security, Logging, Time source), one pane
       each, in the same shape as the three above: a settings-pane div shown
       on activeGroup, opening with a settings-group-label, holding ssec cards.
       The rail needs no edit, because it is read out of this template. Do NOT
       write an example pane in literal markup inside a comment: the rail
       reader does not know what a comment is, and would list it. -->

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
    const termRe = /<div class="srow-lbl">\s*([^<]+)/g;
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
        while ((t = termRe.exec(slice)) !== null) terms.push(settingsDecodeEntities(t[1]).trim());
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
