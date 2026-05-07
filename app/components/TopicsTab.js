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
            loading: false, error: '',
            search: '', showInternal: false,
            sortKey: 'name', sortAsc: true,
            selected: new Set(),
            // modals
            showCreate: false,
            configTopic: null,
            deleteTopic: null,
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
                return this.sortAsc ? (av > bv ? 1 : -1) : (av < bv ? 1 : -1);
            });
        },
        totalPartitions() { return this.userTopics.reduce((s, t) => s + t.partitions, 0); },
        brokerCount()     { return this.brokerMeta?.broker_count ?? '—'; },
        selectedCount()   { return this.selected.size; },
    },
    watch: { clusterId() { this.fetch(); } },
    methods: {
        async fetch() {
            this.loading = true; this.error = ''; this.selected = new Set();
            try {
                const qs = this.clusterId ? `?cluster=${this.clusterId}&internal=true` : '?internal=true';
                const [tr, mr] = await Promise.all([
                    window.fetch(`/api/topics${qs}`),
                    window.fetch(`/api/broker/metadata${this.clusterId ? `?cluster=${this.clusterId}` : ''}`),
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
        async bulkDelete() {
            if (!this.selected.size) return;
            const names = [...this.selected];
            if (!confirm(`Permanently delete ${names.length} topic(s)?\n\n${names.join('\n')}\n\nThis cannot be undone.`)) return;
            const qs = this.clusterId ? `?cluster=${this.clusterId}` : '';
            for (const name of names) {
                await window.fetch(`/api/topics/${encodeURIComponent(name)}${qs}`, { method: 'DELETE' });
            }
            await this.fetch();
        },
        onCreated()  { this.showCreate = false; this.fetch(); },
        onDeleted()  { this.deleteTopic = null; this.fetch(); },
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
    mounted() { this.fetch(); },
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
      <div class="val" :style="brokerMeta ? 'color:var(--accent-green)' : ''">{{ brokerCount }}</div>
      <template v-if="brokerMeta">
        <div class="sub ok" v-for="b in brokerMeta.brokers" :key="b.id">{{ b.host }}</div>
      </template>
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
    <button class="btn btn-sm" v-if="selectedCount > 0" @click="bulkDelete" style="color:var(--accent-red);border-color:rgba(248,113,113,.35)">
      🗑 Delete ({{ selectedCount }})
    </button>
    <button class="btn btn-sm" @click="fetch" :disabled="loading">↻ Retrieve All</button>
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
</div>
`,
};
