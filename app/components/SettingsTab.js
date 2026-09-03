// Jarvis Topic Manager — Settings Tab
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const SettingsTab = {
    name: 'SettingsTab',
    components: { ClusterModal },
    props: ['clusters', 'activeClusterId', 'version', 'protocols', 'mechanisms'],
    emits: ['open-about', 'cluster-changed', 'clusters-changed'],
    data() {
        return {
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
    methods: {
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
        downloadPpsm() {
            const rows = [
                ['Jarvis Topic Manager — PPSM', '', '', '', '', ''],
                ['Version', '1.0.6', '', '', '', ''],
                ['Generated', new Date().toISOString().split('T')[0], '', '', '', ''],
                ['', '', '', '', '', ''],
                ['Section', 'Service/Component', 'Port', 'Protocol', 'Direction', 'Description'],
                ['--- INBOUND ---', '', '', '', '', ''],
                ['Web', 'SSH',            '22',   'TCP', 'Inbound', 'Secure shell administration'],
                ['Web', 'HTTP',           '80',   'TCP', 'Inbound', 'Redirect to HTTPS (301)'],
                ['Web', 'HTTPS',          '443',  'TCP', 'Inbound', 'Topic Manager web UI + API'],
                ['--- INTERNAL (loopback) ---', '', '', '', '', ''],
                ['App', 'gunicorn Flask', '5001', 'TCP', 'Loopback','nginx → gunicorn backend (127.0.0.1 only)'],
                ['--- OUTBOUND ---', '', '', '', '', ''],
                ['Auth', 'AD/LDAPS',       '636',  'TCP', 'Outbound','Active Directory authentication'],
                ['Auth', 'AD/LDAP',        '389',  'TCP', 'Outbound','Active Directory (fallback)'],
                ['Kafka', 'Kafka Bare Metal','9092', 'TCP', 'Outbound','Kafka broker plaintext (broker1-3)'],
                ['Kafka', 'Kafka K8s',      '9094', 'TCP', 'Outbound','Kafka broker SSL (MetalLB VIPs)'],
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

  <!-- Cluster Profiles -->
  <div class="ssec">
    <div class="ssec-title" style="display:flex;align-items:center;justify-content:space-between">
      <span>Cluster Profiles</span>
      <button class="btn btn-sm btn-primary" @click="addCluster">+ Add Cluster</button>
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
        <input type="checkbox" v-model="restartNginxHard" :disabled="restartState === 'working'" style="accent-color:var(--accent-cyan)"> Hard restart
      </label>
    </div>
    <div v-if="restartMessage" :style="{ marginTop:'8px', fontSize:'.72rem', color: restartColour }">
      {{ restartMessage }}
    </div>
  </div>

  <!-- Branding / Banner -->
  <!-- These two sections are NOT rendered until /api/settings has actually
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
        <input type="checkbox" v-model="dowEnabled" @change="saveDow" style="accent-color:var(--accent-cyan)"> Enabled
      </label>
    </div>
  </div>

  <div class="ssec" v-if="settingsLoaded">
    <div class="ssec-title">Branding &amp; Classification Banner</div>
    <div v-if="settingsSaveError" style="margin-bottom:8px;color:var(--accent-red);font-size:.72rem">{{ settingsSaveError }}</div>
    <div class="srow">
      <div class="srow-lbl">Enable Banner<span class="hint">Shows at top and bottom of every page</span></div>
      <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-size:.72rem">
        <input type="checkbox" v-model="bannerEnabled" @change="saveBanner" style="accent-color:var(--accent-cyan)"> Enabled
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
