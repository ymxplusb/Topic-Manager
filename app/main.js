const { createApp, ref, computed, onMounted } = Vue;

const App = {
    components: { LoginView, TopBar, TopicsTab, ConsumerGroupsTab, AuditTab, SettingsTab, AboutModal },
    // ClusterModal is registered by SettingsTab, which is the only component
    // that renders it. Naming it here too would add a second definition-time
    // reference to the same global for no benefit.
    setup() {
        const user        = ref(null);
        const currentTab  = ref('topics');
        const clusters    = ref([]);
        const activeCluster = ref('');
        // Served by /api/clusters so the Cluster Builder offers exactly what
        // the backend will accept, rather than a second hardcoded list that
        // drifts from tm/clusters.py.
        const protocols   = ref([]);
        const mechanisms  = ref([]);
        const brokerMeta  = ref(null);
        const topicCount  = ref(0);
        const showAbout   = ref(false);
        // Not a version literal: this is the value shown BEFORE /api/version
        // answers. A hardcoded fallback asserts a specific version, so a host
        // that cannot reach its own API displays a confident wrong number —
        // exactly how this system showed 1.0.2 while running 1.0.0 for months.
        // 'unknown' renders literally in the Settings > Version row, which is
        // the truth when the API has not answered.
        const version     = ref('unknown');

        async function fetchVersion() {
            try {
                const r = await fetch('/api/version');
                if (r.ok) { const d = await r.json(); version.value = d.version || 'unknown'; }
            } catch { /* network unavailable — UI stays in previous state */ }
        }

        async function fetchClusters() {
            try {
                const r = await fetch('/api/clusters');
                if (r.ok) {
                    const d = await r.json();
                    clusters.value = d.clusters || [];
                    protocols.value = d.protocols || [];
                    mechanisms.value = d.sasl_mechanisms || [];
                    const active = clusters.value.find(c => c.active);
                    // The selected cluster can be deleted by the Cluster
                    // Builder while it is selected. Leaving activeCluster
                    // pointing at a profile that no longer exists makes every
                    // topic and consumer-group view fail with "cluster not
                    // found", so fall back to whichever profile is active now.
                    const stillThere = clusters.value.some(c => c.id === activeCluster.value);
                    if (!stillThere) activeCluster.value = active ? active.id
                        : (clusters.value[0] ? clusters.value[0].id : '');
                }
            } catch { /* network unavailable — UI stays in previous state */ }
        }

        async function checkSession() {
            try {
                const r = await fetch('/api/auth/whoami');
                if (r.ok) { const d = await r.json(); user.value = d.user; }
            } catch { /* network unavailable — UI stays in previous state */ }
        }

        async function logout() {
            await fetch('/api/auth/logout', { method: 'POST' });
            user.value = null; currentTab.value = 'topics';
        }

        function onLoggedIn(u) {
            user.value = u;
            fetchClusters();
            fetchVersion();
        }

        function onClusterChanged(id) {
            activeCluster.value = id;
            fetch('/api/clusters/active', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ cluster_id: id }),
            });
        }

        const colorMap = { green:'#16a34a', blue:'#2563eb', purple:'#7c3aed',
                           red:'#dc2626', orange:'#ea580c', yellow:'#ca8a04' };
        const fgMap    = { white:'#ffffff', black:'#000000', grey:'#d1d5db' };

        function applyBannerFromSettings(s) {
            const enabled = s.banner_enabled === 'true';
            const bg  = colorMap[s.banner_bg]  || '#16a34a';
            const fg  = fgMap[s.banner_fg]     || '#ffffff';
            const txt = s.banner_text          || 'UNCLASSIFIED';
            ['banner-top', 'banner-bot'].forEach(id => {
                const el = document.getElementById(id);
                if (!el) return;
                el.style.display    = enabled ? 'block' : 'none';
                el.style.background = bg;
                el.style.color      = fg;
                el.textContent      = txt;
            });
            const pad = enabled ? '26px' : '0px';
            document.body.style.paddingTop    = pad;
            document.body.style.paddingBottom = pad;
        }

        onMounted(async () => {
            const t = localStorage.getItem('tmTheme') || 'dark';
            document.body.classList.remove('light-mode', 'cb-mode');
            if (t === 'light') document.body.classList.add('light-mode');
            if (t === 'cb')    document.body.classList.add('cb-mode');

            try {
                const r = await fetch('/api/settings/public');
                if (r.ok) applyBannerFromSettings(await r.json());
            } catch { /* network unavailable — UI stays in previous state */ }

            checkSession().then(() => {
                if (user.value) { fetchClusters(); fetchVersion(); }
            });
        });

        return { user, currentTab, clusters, activeCluster, protocols, mechanisms,
                 brokerMeta, topicCount, showAbout, version,
                 onLoggedIn, logout, onClusterChanged, fetchClusters };
    },
    template: `
<div id="app-shell" v-if="user">
  <TopBar
    :user="user"
    :clusters="clusters"
    :active-cluster-id="activeCluster"
    :broker-meta="brokerMeta"
    @logout="logout"
    @cluster-changed="onClusterChanged"
    @open-about="showAbout = true"
  />
  <nav class="app-nav">
    <button class="ntab" :class="{ act: currentTab === 'topics' }"   @click="currentTab = 'topics'">
      Topics
    </button>
    <button class="ntab" :class="{ act: currentTab === 'cgroups' }"  @click="currentTab = 'cgroups'">Consumer Groups</button>
    <button class="ntab" :class="{ act: currentTab === 'audit' }"    @click="currentTab = 'audit'">Audit Log</button>
    <button class="ntab" :class="{ act: currentTab === 'settings' }" @click="currentTab = 'settings'">Settings</button>
  </nav>
  <div class="app-content">
    <TopicsTab          v-if="currentTab === 'topics'"   :cluster-id="activeCluster" @topic-count="topicCount = $event" />
    <ConsumerGroupsTab  v-if="currentTab === 'cgroups'"  :cluster-id="activeCluster" />
    <AuditTab           v-if="currentTab === 'audit'" />
    <SettingsTab        v-if="currentTab === 'settings'"
      :clusters="clusters"
      :active-cluster-id="activeCluster"
      :version="version"
      :protocols="protocols"
      :mechanisms="mechanisms"
      @open-about="showAbout = true"
      @cluster-changed="onClusterChanged"
      @clusters-changed="fetchClusters"
    />
  </div>
  <AboutModal v-if="showAbout" @close="showAbout = false" />
</div>
<LoginView v-else @logged-in="onLoggedIn" />
`,
};

createApp(App).mount('#app-mount');
