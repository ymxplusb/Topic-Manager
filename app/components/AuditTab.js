// Jarvis Topic Manager — Audit Log Tab
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const AuditTab = {
    name: 'AuditTab',
    data() {
        // writeFailure: the last audit write failure (SRG-APP-000360), from
        // /api/audit/capacity; the banner shows while it is current.
        return { entries: [], total: 0, page: 1, pages: 1, loading: false, error: '', writeFailure: null };
    },
    methods: {
        async fetch(p) {
            if (p !== undefined) this.page = p;
            this.loading = true; this.error = '';
            try {
                const r = await fetch(`/api/audit?page=${this.page}&per_page=50`);
                const d = await r.json();
                if (!r.ok) { this.error = d.error || 'Failed'; return; }
                this.entries = d.entries; this.total = d.total; this.pages = d.pages;
            } catch (e) {
                this.error = 'Network error';
            } finally {
                this.loading = false;
            }
        },
        async loadWriteFailure() {
            try {
                const r = await fetch('/api/audit/capacity', { headers: { 'X-TM-Background': '1' } });
                if (r.ok) { const d = await r.json(); this.writeFailure = d.write_failure || null; }
            } catch (e) { /* the banner is an extra; the list still loads */ }
        },
        async exportCsv() {
            const r   = await fetch('/api/audit/export');
            if (!r.ok) {
                let d = {};
                try { d = await r.json(); } catch (e) { d = {}; }
                this.error = d.message || d.error || ('Export failed (HTTP ' + r.status + ')');
                return;
            }
            const txt = await r.text();
            const a   = document.createElement('a');
            a.href = URL.createObjectURL(new Blob([txt], { type: 'text/csv' }));
            a.download = 'topic-manager-audit.csv';
            a.click();
        },
        actionClass(a, outcome) {
            if (outcome === 'failure') return 'aa-delete';
            if (a === 'CREATE')        return 'aa-create';
            if (a === 'DELETE')        return 'aa-delete';
            if (a === 'UPDATE_CONFIG') return 'aa-update';
            return '';
        },
    },
    mounted() { this.fetch(1); this.loadWriteFailure(); },
    template: `
<div>
  <div v-if="writeFailure && writeFailure.current" class="host-audit-banner" role="alert">
    ! The audit trail could not be written at {{ writeFailure.failed_at }} ({{ writeFailure.reason }}), and no record has been written since. Actions are refused until it recovers; <template v-if="writeFailure.syslog_delivered === true">the record went to the host syslog as AUDIT_WRITE_FAILED.</template><template v-else-if="writeFailure.syslog_delivered === false">the host syslog did NOT accept the record either: its only copy is the service log (journalctl -u topic-manager, AUDIT_WRITE_FAILED).</template><template v-else>look for AUDIT_WRITE_FAILED in the host syslog, and in the service log (journalctl -u topic-manager) if it is not there.</template>
  </div>
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
      <thead><tr><th>Timestamp (UTC)</th><th>User</th><th>Source</th><th>Action</th><th>Outcome</th><th>Target</th><th>Detail</th><th>Cluster</th></tr></thead>
      <tbody>
        <tr v-for="e in entries" :key="e.id">
          <td style="font-family:var(--mono);font-size:.66rem;color:var(--text-muted);white-space:nowrap">{{ e.ts }}</td>
          <td style="font-family:var(--mono);font-size:.68rem">{{ e.user }}</td>
          <td style="font-family:var(--mono);font-size:.63rem;color:var(--text-muted)">{{ e.source }}</td>
          <td><span :class="actionClass(e.action, e.outcome)" style="font-weight:600;font-size:.7rem">{{ e.action }}</span></td>
          <td :class="e.outcome === 'failure' ? 'aa-delete' : ''" style="font-size:.66rem">{{ e.outcome }}</td>
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
