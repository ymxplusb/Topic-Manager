// Jarvis Topic Manager — Consumer Groups Tab
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const ConsumerGroupsTab = {
    name: 'ConsumerGroupsTab',
    props: ['clusterId'],
    data() {
        return { groups: [], loading: false, error: '', countdown: 30, refreshTimer: null };
    },
    computed: {
        stable()   { return this.groups.filter(g => g.state === 'Stable').length; },
        empty()    { return this.groups.filter(g => g.state === 'Empty').length; },
    },
    methods: {
        async fetch() {
            this.countdown = 30;
            this.loading = true; this.error = '';
            try {
                const qs = this.clusterId ? `?cluster=${this.clusterId}` : '';
                const r  = await window.fetch(`/api/consumer-groups${qs}`);
                const d  = await r.json();
                if (!r.ok) { this.error = d.error || 'Failed'; return; }
                this.groups = d.groups || [];
            } catch (e) {
                this.error = 'Network error';
            } finally {
                this.loading = false;
            }
        },
        stateClass(s) {
            if (s === 'Stable') return 'text-green';
            if (s === 'Empty')  return 'text-muted';
            return 'text-amber';
        },
    },
    mounted() {
        this.fetch();
        this.refreshTimer = setInterval(() => {
            if (this.loading) return;
            this.countdown--;
            if (this.countdown <= 0) { this.fetch(); this.countdown = 30; }
        }, 1000);
    },
    beforeUnmount() { clearInterval(this.refreshTimer); },
    watch: { clusterId() { this.fetch(); } },
    template: `
<div>
  <div class="stats-row" style="grid-template-columns:repeat(3,1fr)">
    <div class="stat-card"><div class="lbl">Total Groups</div><div class="val">{{ groups.length }}</div></div>
    <div class="stat-card"><div class="lbl">Stable</div><div class="val" style="color:var(--accent-green)">{{ stable }}</div></div>
    <div class="stat-card"><div class="lbl">Empty</div><div class="val" style="color:var(--text-muted)">{{ empty }}</div></div>
  </div>

  <div class="toolbar">
    <div class="tspacer"></div>
    <button class="btn btn-sm" @click="fetch" :disabled="loading">
      <span v-if="loading" class="spinner" style="width:10px;height:10px"></span>
      <span v-else>↻</span>
      {{ loading ? 'Refreshing…' : 'Refresh' }}
      <span v-if="!loading" style="font-family:var(--mono);font-size:.58rem;color:var(--text-muted);margin-left:2px">{{ countdown }}s</span>
    </button>
  </div>

  <div v-if="loading" style="text-align:center;padding:48px;color:var(--text-muted)"><span class="spinner" style="width:20px;height:20px"></span></div>
  <div v-else-if="error" style="color:var(--accent-red);font-size:.75rem;padding:12px">{{ error }}</div>
  <div v-else-if="!groups.length" class="empty-state">
    <div class="ei">📦</div>
    <div class="et">No consumer groups found</div>
    <div>No active consumers on this cluster.</div>
  </div>
  <div v-else class="twrap">
    <table class="dt">
      <thead>
        <tr>
          <th>Group ID</th>
          <th>State</th>
          <th style="text-align:center">Simple</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="g in groups" :key="g.id">
          <td class="nc">{{ g.id }}</td>
          <td><span :class="stateClass(g.state)">● {{ g.state }}</span></td>
          <td class="num"><span style="font-size:.65rem;color:var(--text-muted)">{{ g.is_simple ? 'Yes' : 'No' }}</span></td>
        </tr>
      </tbody>
    </table>
  </div>
</div>
`,
};
