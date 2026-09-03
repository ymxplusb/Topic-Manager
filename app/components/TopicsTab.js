// Jarvis Topic Manager — Topics Tab (main view)
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const TopicsTab = {
    name: 'TopicsTab',
    props: ['clusterId'],
    emits: ['topic-count'],
    components: { CreateTopicModal, TopicConfigModal, DeleteTopicModal },
    data() {
        return {
            topics: [], brokerMeta: null,
            showBrokerPopup: false,
            loading: false, error: '',
            countdown: 30, refreshTimer: null,
            search: '', showInternal: false,
            sortKey: 'name', sortAsc: true,
            selected: new Set(),
            // modals
            showCreate: false,
            configTopic: null,
            deleteTopic: null,
            showBulkDelete: false,
            bulkDeleting: false,
            bulkDeleteError: '',
        };
    },
    computed: {
        userTopics()     { return this.topics.filter(t => !t.internal); },
        internalTopics() { return this.topics.filter(t => t.internal); },
        filtered() {
            const q = this.search.toLowerCase();
            let list = this.showInternal ? this.topics : this.userTopics;
            if (q) list = list.filter(t => t.name.toLowerCase().includes(q));
            return [...list].sort((a, b) => {
                let av = a[this.sortKey], bv = b[this.sortKey];
                if (typeof av === 'string') { av = av.toLowerCase(); bv = bv.toLowerCase(); }
                if (this.sortAsc) return av > bv ? 1 : -1;
                return av < bv ? 1 : -1;
            });
        },
        totalPartitions() { return this.userTopics.reduce((s, t) => s + t.partitions, 0); },
        brokerCount()     { return this.brokerMeta?.broker_count ?? '—'; },
        selectedCount()   { return this.selected.size; },
    },
    watch: { clusterId() { this.fetch(); } },
    methods: {
        // `background` is true only for the tab's own 30-second refresh.
        // It travels as X-TM-Background so require_auth does not treat the
        // poll as user activity and slide the session; a person pressing
        // Refresh, or switching cluster, is activity and sends nothing.
        _bg(background) {
            return background ? { headers: { 'X-TM-Background': '1' } } : {};
        },
        async fetch(background) {
            this.countdown = 30;
            this.loading = true; this.error = ''; this.selected = new Set();
            try {
                const qs = this.clusterId ? `?cluster=${this.clusterId}&internal=true` : '?internal=true';
                const brokerQs = this.clusterId ? `?cluster=${this.clusterId}` : '';
                const opts = this._bg(background);
                const [tr, mr] = await Promise.all([
                    fetch(`/api/topics${qs}`, opts),
                    fetch(`/api/broker/metadata${brokerQs}`, opts),
                ]);
                const td = await tr.json();
                if (!tr.ok) { this.error = td.error || 'Failed to load topics'; return; }
                this.topics = td.topics || [];
                if (mr.ok) this.brokerMeta = await mr.json();
                this.$emit('topic-count', this.userTopics.length);
            } catch (e) {
                this.error = 'Network error — check server connection';
            } finally {
                this.loading = false;
            }
        },
        sortBy(k) { if (this.sortKey === k) this.sortAsc = !this.sortAsc; else { this.sortKey = k; this.sortAsc = true; } },
        toggleSel(name, checked) {
            if (checked) this.selected.add(name); else this.selected.delete(name);
            this.selected = new Set(this.selected); // trigger reactivity
        },
        toggleAll(checked) {
            this.selected = checked ? new Set(this.filtered.map(t => t.name)) : new Set();
        },
        openBulkDelete() {
            if (!this.selected.size) return;
            this.bulkDeleteError = '';
            this.showBulkDelete = true;
        },
        async confirmBulkDelete() {
            this.bulkDeleting = true;
            this.bulkDeleteError = '';
            const qs = this.clusterId ? `?cluster=${this.clusterId}` : '';
            const errors = [];
            for (const name of [...this.selected]) {
                const r = await fetch(`/api/topics/${encodeURIComponent(name)}${qs}`, { method: 'DELETE' });
                if (!r.ok) {
                    const d = await r.json().catch(() => ({}));
                    errors.push(`${name}: ${d.error || r.status}`);
                }
            }
            this.bulkDeleting = false;
            if (errors.length) {
                this.bulkDeleteError = errors.join('\n');
                return;
            }
            this.showBulkDelete = false;
            this.selected = new Set();
            await this.fetch();
        },
        onCreated()  { this.showCreate = false; this.fetch(); },
        onDeleted()  { this.deleteTopic = null; this.fetch(); },
        async downloadConfig(t) {
            const qs = this.clusterId ? `?cluster=${this.clusterId}` : '';
            const r   = await fetch(`/api/topics/${encodeURIComponent(t.name)}/config${qs}`);
            const d   = await r.json();
            if (!r.ok) { alert('Failed to fetch config: ' + (d.error || r.status)); return; }
            const payload = {
                topic:      t.name,
                cluster_id: this.clusterId || 'default',
                partitions: t.partitions,
                replication_factor: t.replication_factor,
                exported_at: new Date().toISOString(),
                config: d.config,
            };
            const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
            const a    = document.createElement('a');
            a.href     = URL.createObjectURL(blob);
            a.download = `${t.name}-config.json`;
            a.click();
            URL.revokeObjectURL(a.href);
        },
        onUpdated()  { /* config modal handles its own refresh */ },
        fmtRet(ms) {
            if (!ms || ms <= 0) return '∞';
            const h = ms / 3600000;
            if (h < 24) return h + 'h';
            const d = h / 24;
            if (d < 30) return Math.round(d) + 'd';
            return Math.round(d / 30) + 'mo';
        },
        fmtBytes(b) {
            if (!b || b <= 0) return '';
            if (b < 1073741824) return Math.round(b / 1048576) + 'MB';
            return (b / 1073741824).toFixed(0) + 'GB';
        },
        statusBadge(t) {
            if (t.internal) return '<span class="bdg bdg-int">Internal</span>';
            if (t.error)    return '<span class="bdg bdg-warn">Error</span>';
            return '<span class="bdg bdg-ok">OK</span>';
        },
    },
    mounted() {
        this.fetch();
        this.refreshTimer = setInterval(() => {
            if (this.loading) return;
            this.countdown--;
            // `true` = this is the tab's own 30-second refresh, not a
            // person doing something. It travels as X-TM-Background so
            // the server does not treat it as activity and renew the
            // session; before v1.0.6 it did, and an open tab could never
            // reach its idle timeout.
            if (this.countdown <= 0) { this.fetch(true); this.countdown = 30; }
        }, 1000);
    },
    beforeUnmount() { clearInterval(this.refreshTimer); },
    template: `
<div>
  <!-- Stats -->
  <div class="stats-row">
    <div class="stat-card">
      <div class="lbl">Topics</div>
      <div class="val">{{ userTopics.length }}</div>
      <div class="sub" v-if="internalTopics.length">{{ internalTopics.length }} internal hidden</div>
    </div>
    <div class="stat-card">
      <div class="lbl">Partitions</div>
      <div class="val">{{ totalPartitions }}</div>
      <div class="sub">across user topics</div>
    </div>
    <div class="stat-card">
      <div class="lbl">Brokers</div>
      <div style="position:relative;display:inline-block">
        <div class="val"
             :style="brokerMeta ? 'color:var(--accent-green);cursor:default' : ''"
             @mouseenter="showBrokerPopup = !!brokerMeta"
             @mouseleave="showBrokerPopup = false">{{ brokerCount }}</div>
        <div v-if="showBrokerPopup"
             style="position:absolute;top:calc(100% + 8px);left:50%;transform:translateX(-50%);z-index:500;
                    background:var(--bg-card);border:1px solid var(--border-color);border-radius:8px;
                    padding:10px 14px;box-shadow:0 8px 24px rgba(0,0,0,.5);min-width:260px;
                    pointer-events:none;">
          <div style="font-size:.58rem;font-weight:700;text-transform:uppercase;letter-spacing:.08em;color:var(--text-muted);margin-bottom:8px">Connected Brokers</div>
          <div v-for="b in brokerMeta.brokers" :key="b.id"
               style="font-family:var(--mono);font-size:.68rem;color:var(--accent-green);padding:3px 0;border-bottom:1px solid var(--border-color);"
               :style="{ borderBottom: b === brokerMeta.brokers[brokerMeta.brokers.length-1] ? 'none' : '' }">
            <span style="color:var(--text-muted);margin-right:8px">#{{ b.id }}</span>{{ b.host }}
          </div>
        </div>
      </div>
      <div class="sub ok" v-if="brokerMeta">All online</div>
    </div>
    <div class="stat-card">
      <div class="lbl">Search Results</div>
      <div class="val">{{ filtered.length }}</div>
      <div class="sub">of {{ topics.length }} total</div>
    </div>
  </div>

  <!-- Toolbar -->
  <div class="toolbar">
    <div class="search-wrap">
      <span class="si">🔍</span>
      <input type="text" v-model="search" placeholder="Search topics…">
    </div>
    <label class="tog-label">
      <input type="checkbox" v-model="showInternal"> Show internal
    </label>
    <div class="tspacer"></div>
    <button class="btn btn-sm" v-if="selectedCount > 0" @click="openBulkDelete" style="color:var(--accent-red);border-color:rgba(248,113,113,.35)">
      🗑 Delete ({{ selectedCount }})
    </button>
    <button class="btn btn-sm" @click="fetch" :disabled="loading">
      <span v-if="loading" class="spinner" style="width:10px;height:10px"></span>
      <span v-else>↻</span>
      {{ loading ? 'Refreshing…' : 'Retrieve All' }}
      <span v-if="!loading" style="font-family:var(--mono);font-size:.58rem;color:var(--text-muted);margin-left:2px">{{ countdown }}s</span>
    </button>
    <button class="btn btn-cyan" @click="showCreate = true">+ Create Topic</button>
  </div>

  <div v-if="loading" style="text-align:center;padding:48px"><span class="spinner" style="width:20px;height:20px"></span></div>
  <div v-else-if="error" style="color:var(--accent-red);font-size:.75rem;padding:12px;background:rgba(248,113,113,.06);border:1px solid rgba(248,113,113,.2);border-radius:8px;margin-bottom:10px">{{ error }}</div>
  <div v-else-if="!filtered.length && !loading" class="empty-state">
    <div class="ei">📭</div>
    <div class="et">No topics found</div>
    <div v-if="search">No topics match "{{ search }}".</div>
    <div v-else>No topics on this cluster yet. Create one above.</div>
  </div>
  <div v-else class="twrap">
    <table class="dt">
      <thead>
        <tr>
          <th style="width:32px"><input type="checkbox" @change="toggleAll($event.target.checked)"></th>
          <th @click="sortBy('name')" :class="{ sorted: sortKey === 'name' }">Name ↕</th>
          <th @click="sortBy('partitions')" :class="{ sorted: sortKey === 'partitions' }" style="text-align:center">Partitions</th>
          <th @click="sortBy('replication_factor')" :class="{ sorted: sortKey === 'replication_factor' }" style="text-align:center">RF</th>
          <th>Status</th>
          <th style="width:90px">Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="t in filtered" :key="t.name">
          <td><input type="checkbox" :checked="selected.has(t.name)" @change="toggleSel(t.name, $event.target.checked)"></td>
          <td class="nc" :style="t.internal ? 'color:var(--text-muted)' : ''">{{ t.name }}</td>
          <td class="num">{{ t.partitions }}</td>
          <td class="num">{{ t.replication_factor }}</td>
          <td v-html="statusBadge(t)"></td>
          <td class="ac">
            <button class="btn btn-icon" @click="configTopic = t" title="View / Edit Config">⚙</button>
            <button class="btn btn-icon" @click="downloadConfig(t)" title="Download Config as JSON">⬇</button>
            <button class="btn btn-icon del" @click="deleteTopic = t" title="Delete Topic" v-if="!t.internal">🗑</button>
          </td>
        </tr>
      </tbody>
    </table>
  </div>

  <!-- Modals -->
  <CreateTopicModal v-if="showCreate" :cluster-id="clusterId" @close="showCreate = false" @created="onCreated" />
  <TopicConfigModal v-if="configTopic"
    :topic-name="configTopic.name"
    :partitions="configTopic.partitions"
    :rf="configTopic.replication_factor"
    :cluster-id="clusterId"
    @close="configTopic = null"
    @updated="onUpdated" />
  <DeleteTopicModal v-if="deleteTopic"
    :topic-name="deleteTopic.name"
    @close="deleteTopic = null"
    @confirmed="onDeleted" />

  <!-- Bulk Delete Modal -->
  <div v-if="showBulkDelete" class="mback open" @click.self="showBulkDelete = false">
    <div class="modal">
      <div class="mhdr">
        <div>
          <div class="mtitle" style="color:var(--accent-red)">⚠ Delete {{ selected.size }} Topic{{ selected.size !== 1 ? 's' : '' }}</div>
          <div class="msub">This action is irreversible</div>
        </div>
        <button class="mclose" @click="showBulkDelete = false">✕</button>
      </div>
      <div class="mbody">
        <div class="del-warn">
          <span class="wi">⚠️</span>
          <div class="wt">
            The following topics and <strong>all their messages</strong> will be permanently deleted.
            Active consumers will receive errors. <strong>This cannot be undone.</strong>
          </div>
        </div>
        <div style="background:var(--bg-secondary);border:1px solid var(--border-color);border-radius:7px;padding:10px 12px;max-height:200px;overflow-y:auto">
          <div v-for="name in [...selected]" :key="name"
               style="font-family:var(--mono);font-size:.7rem;color:var(--text-primary);padding:3px 0;border-bottom:1px solid var(--border-color)"
               :style="{ borderBottom: name === [...selected][[...selected].length-1] ? 'none' : '' }">
            {{ name }}
          </div>
        </div>
        <div v-if="bulkDeleteError" style="margin-top:10px;color:var(--accent-red);font-size:.7rem;white-space:pre-line">{{ bulkDeleteError }}</div>
      </div>
      <div class="mfoot">
        <button class="btn btn-secondary" @click="showBulkDelete = false" :disabled="bulkDeleting">Cancel</button>
        <button class="btn btn-danger" @click="confirmBulkDelete" :disabled="bulkDeleting">
          <span v-if="bulkDeleting" class="spinner"></span>
          <span v-else>Delete {{ selected.size }} Topic{{ selected.size !== 1 ? 's' : '' }}</span>
        </button>
      </div>
    </div>
  </div>
</div>
`,
};
