// Jarvis Topic Manager — Audit Log Tab
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const AuditTab = {
    name: 'AuditTab',
    data() {
        return { entries: [], total: 0, page: 1, pages: 1, loading: false, error: '' };
    },
    methods: {
        async fetch(p) {
            if (p !== undefined) this.page = p;
            this.loading = true; this.error = '';
            try {
                const r = await window.fetch(`/api/audit?page=${this.page}&per_page=50`);
                const d = await r.json();
                if (!r.ok) { this.error = d.error || 'Failed'; return; }
                this.entries = d.entries; this.total = d.total; this.pages = d.pages;
            } catch (e) {
                this.error = 'Network error';
            } finally {
                this.loading = false;
            }
        },
        async exportCsv() {
            const r   = await window.fetch('/api/audit/export');
            const txt = await r.text();
            const a   = document.createElement('a');
            a.href = URL.createObjectURL(new Blob([txt], { type: 'text/csv' }));
            a.download = 'topic-manager-audit.csv';
            a.click();
        },
        actionClass(a) {
            if (a === 'CREATE')        return 'aa-create';
            if (a === 'DELETE')        return 'aa-delete';
            if (a === 'UPDATE_CONFIG') return 'aa-update';
            return '';
        },
    },
    mounted() { this.fetch(1); },
    template: `
<div>
  <div class="toolbar">
    <div style="font-size:.72rem;color:var(--text-muted)">{{ total }} total entries</div>
    <div class="tspacer"></div>
    <button class="btn btn-sm" @click="exportCsv">⬇ Export CSV</button>
    <button class="btn btn-sm" @click="fetch()" :disabled="loading">↻ Refresh</button>
  </div>

  <div v-if="loading" style="text-align:center;padding:48px"><span class="spinner" style="width:20px;height:20px"></span></div>
  <div v-else-if="error" style="color:var(--accent-red);font-size:.75rem;padding:12px">{{ error }}</div>
  <div v-else-if="!entries.length" class="empty-state">
    <div class="ei">📋</div>
    <div class="et">No audit entries yet</div>
    <div>Actions taken on topics will appear here.</div>
  </div>
  <div v-else class="twrap">
    <table class="dt">
      <thead><tr><th>Timestamp</th><th>User</th><th>Action</th><th>Target</th><th>Detail</th><th>Cluster</th></tr></thead>
      <tbody>
        <tr v-for="e in entries" :key="e.id">
          <td style="font-family:var(--mono);font-size:.66rem;color:var(--text-muted);white-space:nowrap">{{ e.ts }}</td>
          <td style="font-family:var(--mono);font-size:.68rem">{{ e.user }}</td>
          <td><span :class="actionClass(e.action)" style="font-weight:600;font-size:.7rem">{{ e.action }}</span></td>
          <td class="nc">{{ e.target }}</td>
          <td style="font-family:var(--mono);font-size:.61rem;color:var(--text-muted);max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" :title="e.detail">{{ e.detail }}</td>
          <td style="font-size:.63rem;color:var(--text-muted)">{{ e.cluster_id }}</td>
        </tr>
      </tbody>
    </table>
  </div>

  <!-- pagination -->
  <div v-if="pages > 1" style="display:flex;align-items:center;gap:8px;margin-top:10px;font-size:.7rem;color:var(--text-muted)">
    <button class="btn btn-sm" @click="fetch(page - 1)" :disabled="page <= 1 || loading">← Prev</button>
    <span>Page {{ page }} of {{ pages }}</span>
    <button class="btn btn-sm" @click="fetch(page + 1)" :disabled="page >= pages || loading">Next →</button>
  </div>
</div>
`,
};
