// Jarvis Topic Manager — Settings Tab
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const SettingsTab = {
    name: 'SettingsTab',
    props: ['clusters', 'activeClusterId', 'version'],
    emits: ['open-about', 'cluster-changed'],
    data() {
        return {
            // DoW Consent
            dowEnabled: false,
            // Banner
            bannerEnabled: false,
            bannerText: 'UNCLASSIFIED',
            bannerBg: 'green',
            bannerFg: 'white',
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
        };
    },
    computed: {
        bannerHex() {
            const c = this.bannerColors.find(x => x.val === this.bannerBg);
            return c ? c.hex : '#16a34a';
        },
        fgColor() {
            return { white: '#ffffff', black: '#000000', grey: '#d1d5db' }[this.bannerFg] || '#ffffff';
        },
    },
    methods: {
        async loadSettings() {
            try {
                const r = await window.fetch('/api/settings');
                if (!r.ok) return;
                const s = await r.json();
                this.dowEnabled    = s.dow_enabled    === 'true';
                this.bannerEnabled = s.banner_enabled === 'true';
                this.bannerText    = s.banner_text    || 'UNCLASSIFIED';
                this.bannerBg      = s.banner_bg      || 'green';
                this.bannerFg      = s.banner_fg      || 'white';
                this.applyBanner();
            } catch (_) {}
        },
        async saveDow() {
            await window.fetch('/api/settings', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ dow_enabled: String(this.dowEnabled) }),
            });
        },
        async saveBanner() {
            await window.fetch('/api/settings', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    banner_enabled: String(this.bannerEnabled),
                    banner_text:    this.bannerText,
                    banner_bg:      this.bannerBg,
                    banner_fg:      this.bannerFg,
                }),
            });
            this.applyBanner();
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
                const r = await window.fetch(`/api/clusters/${id}/test`);
                const d = await r.json();
                this.testResults[id] = d;
            } catch (e) {
                this.testResults[id] = { ok: false, detail: 'Network error' };
            } finally {
                this.testing[id] = false;
                this.testResults = { ...this.testResults };
            }
        },
        downloadPpsm() {
            const rows = [
                ['Jarvis Topic Manager — PPSM', '', '', '', '', ''],
                ['Version', '1.0.0', '', '', '', ''],
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
    <div class="ssec-title">Cluster Profiles</div>
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
        <button class="btn btn-sm" v-if="c.id !== activeClusterId" @click="$emit('cluster-changed', c.id)">Set Active</button>
        <span v-else class="stig" style="font-size:.58rem">Active</span>
      </div>
    </div>
    <div style="font-size:.66rem;color:var(--text-muted);margin-top:8px">
      To add or modify clusters, edit <code style="font-family:var(--mono)">/etc/topic-manager/config.yaml</code> and restart the service.
    </div>
  </div>

  <!-- Branding / Banner -->
  <!-- DoW Consent Banner -->
  <div class="ssec">
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

  <div class="ssec">
    <div class="ssec-title">Branding &amp; Classification Banner</div>
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

  <!-- STIG Compliance -->
  <div class="ssec">
    <div class="ssec-title">STIG / Compliance Controls</div>
    <div class="srow"><div class="srow-lbl">Audit Logging</div><div><span class="stig">✓ Enabled</span></div></div>
    <div class="srow"><div class="srow-lbl">TLS Enforcement</div><div><span class="stig">TLS 1.2 / 1.3</span></div></div>
    <div class="srow"><div class="srow-lbl">HTTPS Only</div><div><span class="stig">✓ nginx redirect</span></div></div>
    <div class="srow"><div class="srow-lbl">Session Timeout</div><div><span class="stig">✓ 30 min</span></div></div>
    <div class="srow"><div class="srow-lbl">HTTPOnly Cookies</div><div><span class="stig">✓ Enabled</span></div></div>
    <div class="srow"><div class="srow-lbl">Destructive Confirmation</div><div><span class="stig">✓ Name-match required</span></div></div>
    <div class="srow"><div class="srow-lbl">Password Complexity</div><div><span class="stig">Delegated to AD</span></div></div>
    <div class="srow"><div class="srow-lbl">Security Headers</div><div><span class="stig">✓ Set by nginx</span></div></div>
    <div class="srow"><div class="srow-lbl">Concurrent Session Limit<span class="hint">Server-side session table, enforced at login (set max_concurrent in config.yaml)</span></div><div><span class="stig">✓ Enforced</span></div></div>
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

</div>
`,
};
