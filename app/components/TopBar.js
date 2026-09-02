// Jarvis Topic Manager — Top Navigation Bar
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const TopBar = {
    name: 'TopBar',
    props: ['user', 'clusters', 'activeClusterId', 'brokerMeta'],
    emits: ['logout', 'cluster-changed', 'open-about'],
    data() {
        return {
            showThemeMenu: false,
            showClusterMenu: false,
            currentTheme: localStorage.getItem('tmTheme') || 'dark',
        };
    },
    computed: {
        activeCluster() {
            return this.clusters.find(c => c.id === this.activeClusterId) || this.clusters[0] || null;
        },
        brokerCount() {
            return this.brokerMeta ? this.brokerMeta.broker_count : '—';
        },
        userInitials() {
            const name = this.user?.display_name || this.user?.username || 'U';
            return name.split(/[\s._-]/).map(w => w[0]).join('').toUpperCase().slice(0, 2);
        },
    },
    methods: {
        setTheme(t) {
            this.currentTheme = t;
            this.showThemeMenu = false;
            localStorage.setItem('tmTheme', t);
            document.body.classList.remove('light-mode', 'cb-mode');
            if (t === 'light') document.body.classList.add('light-mode');
            else if (t === 'cb')  document.body.classList.add('cb-mode');
        },
        selectCluster(id) {
            this.showClusterMenu = false;
            this.$emit('cluster-changed', id);
        },
        themeLabel(t) {
            return { dark: '🌑 Dark', light: '☀️ Light', cb: '👁 Color Blind' }[t] || t;
        },
        closeMenus() { this.showThemeMenu = false; this.showClusterMenu = false; },
    },
    mounted() {
        const saved = localStorage.getItem('tmTheme');
        if (saved) this.setTheme(saved);
        document.addEventListener('click', this.closeMenus);
    },
    beforeUnmount() {
        document.removeEventListener('click', this.closeMenus);
    },
    template: `
<header class="app-header">
  <div class="hdr-logo">
    <span class="glyph"><img src="/jarvis-mark.png?v=1004" alt="Jarvis" width="24" height="24" style="display:block;object-fit:contain"></span>
    <span class="name">
      <span class="sub">JARVIS</span>
      <span class="main">TOPIC MANAGER</span>
    </span>
  </div>
  <div class="hdiv"></div>

  <!-- Cluster Selector -->
  <div class="cluster-pill" @click.stop="showClusterMenu = !showClusterMenu; showThemeMenu = false" v-if="activeCluster">
    <div class="cdot" :style="{ background: activeCluster.active ? 'var(--accent-green)' : 'var(--text-muted)' }"></div>
    <div>
      <span class="cname">{{ activeCluster.name }}</span>
      <span style="color:var(--text-muted);margin:0 4px">·</span>
      <span class="ctype">{{ activeCluster.bootstrap_servers.split(',')[0] }}</span>
    </div>
    <span class="caret">▾</span>
    <div class="cluster-dropdown" v-if="showClusterMenu">
      <div class="cdrop-item" v-for="c in clusters" :key="c.id"
           :class="{ active: c.id === activeClusterId }"
           @click.stop="selectCluster(c.id)">
        <div class="cdot" :style="{ width:'7px', height:'7px', borderRadius:'50%', background: c.active ? 'var(--accent-green)' : 'var(--text-muted)', flexShrink: 0 }"></div>
        <div>
          <div style="font-weight:600;color:var(--text-primary)">{{ c.name }}</div>
          <div style="font-family:var(--mono);font-size:.58rem;color:var(--text-muted)">{{ c.security_protocol }}</div>
        </div>
        <span v-if="c.id === activeClusterId" style="margin-left:auto;color:var(--accent-cyan);font-size:.7rem">✓</span>
      </div>
    </div>
  </div>

  <div class="hdr-right">
    <div class="broker-stat" v-if="brokerMeta">
      <div class="dot"></div>
      <span>{{ brokerCount }} broker{{ brokerCount !== 1 ? 's' : '' }}</span>
    </div>
    <div class="hdiv"></div>

    <!-- Theme picker -->
    <div style="position:relative">
      <button class="theme-btn" @click.stop="showThemeMenu = !showThemeMenu; showClusterMenu = false" :title="'Theme: ' + currentTheme">
        {{ currentTheme === 'dark' ? '🌑' : currentTheme === 'light' ? '☀️' : '👁' }}
      </button>
      <div class="theme-menu" v-if="showThemeMenu" @click.stop>
        <button @click="setTheme('dark')"  :class="{ active: currentTheme === 'dark'  }">🌑 Dark</button>
        <button @click="setTheme('light')" :class="{ active: currentTheme === 'light' }">☀️ Light</button>
        <button @click="setTheme('cb')"    :class="{ active: currentTheme === 'cb'    }">👁 Color Blind</button>
      </div>
    </div>

    <div class="user-pill">
      <div class="av">{{ userInitials }}</div>
      <span>{{ user?.display_name || user?.username }}</span>
    </div>
    <button class="btn btn-sm" @click="$emit('logout')">Sign out</button>
  </div>
</header>
`,
};
