const { createApp, ref, computed, onMounted } = Vue;

const App = {
    components: { LoginView, TopBar, TopicsTab, ConsumerGroupsTab, AuditTab, SettingsTab, AboutModal },
    setup() {
        const user        = ref(null);
        const currentTab  = ref('topics');
        const clusters    = ref([]);
        const activeCluster = ref('');
        const brokerMeta  = ref(null);
        const topicCount  = ref(0);
        const showAbout   = ref(false);
        const version     = ref('1.0.0');

        async function fetchVersion() {
            try {
                const r = await fetch('/api/version');
                if (r.ok) { const d = await r.json(); version.value = d.version || '1.0.0'; }
            } catch { /* network unavailable — UI stays in previous state */ }
        }

        async function fetchClusters() {
            try {
                const r = await fetch('/api/clusters');
                if (r.ok) {
                    const d = await r.json();
                    clusters.value = d.clusters || [];
                    const active = clusters.value.find(c => c.active);
                    if (active && !activeCluster.value) activeCluster.value = active.id;
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

        return { user, currentTab, clusters, activeCluster, brokerMeta, topicCount, showAbout, version,
                 onLoggedIn, logout, onClusterChanged };
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
      @open-about="showAbout = true"
      @cluster-changed="onClusterChanged"
    />
  </div>
  <AboutModal v-if="showAbout" @close="showAbout = false" />
</div>
<LoginView v-else @logged-in="onLoggedIn" />
`,
};

createApp(App).mount('#app-mount');
