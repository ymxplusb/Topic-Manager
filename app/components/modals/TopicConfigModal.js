// Jarvis Topic Manager — Topic Config Retrieve / Update Modal
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const TopicConfigModal = {
    name: 'TopicConfigModal',
    props: ['topicName', 'partitions', 'rf', 'clusterId'],
    emits: ['close', 'updated'],
    data() {
        return {
            config: {},
            editMode: false,
            edits: {},
            loading: false,
            saving: false,
            error: '',
            saveError: '',
        };
    },
    computed: {
        configEntries() {
            return Object.entries(this.config).sort((a, b) => a[0].localeCompare(b[0]));
        },
        hasEdits() {
            return Object.keys(this.edits).length > 0;
        },
    },
    watch: {
        topicName: { immediate: true, handler() { this.retrieve(); } },
    },
    methods: {
        async retrieve() {
            this.loading = true; this.error = ''; this.editMode = false; this.edits = {};
            try {
                const qs = this.clusterId ? `?cluster=${this.clusterId}` : '';
                const r = await fetch(`/api/topics/${encodeURIComponent(this.topicName)}/config${qs}`);
                const data = await r.json();
                if (!r.ok) { this.error = data.error || 'Failed to retrieve config'; return; }
                this.config = data.config || {};
            } catch (e) {
                this.error = 'Network error';
            } finally {
                this.loading = false;
            }
        },
        startEdit() {
            this.editMode = true;
            this.edits = {};
            // Pre-populate edits with current values for non-read-only entries
            for (const [key, entry] of Object.entries(this.config)) {
                if (!entry.is_read_only) this.edits[key] = entry.value ?? '';
            }
        },
        cancelEdit() { this.editMode = false; this.edits = {}; this.saveError = ''; },
        async saveEdits() {
            // Only send keys where value actually changed
            const updates = {};
            for (const [key, val] of Object.entries(this.edits)) {
                if (val !== (this.config[key]?.value ?? '')) updates[key] = val;
            }
            if (!Object.keys(updates).length) { this.cancelEdit(); return; }
            this.saving = true; this.saveError = '';
            try {
                const qs = this.clusterId ? `?cluster=${this.clusterId}` : '';
                const r = await fetch(`/api/topics/${encodeURIComponent(this.topicName)}/config${qs}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ updates }),
                });
                const data = await r.json();
                if (!r.ok) { this.saveError = data.error || 'Update failed'; return; }
                this.$emit('updated', this.topicName);
                await this.retrieve();    // refresh config from Kafka after update
            } catch (e) {
                this.saveError = 'Network error';
            } finally {
                this.saving = false;
            }
        },
    },
    template: `
<div class="mback open" @click.self="$emit('close')">
  <div class="modal xl">
    <div class="mhdr">
      <div>
        <div class="mtitle" style="font-family:var(--mono);font-size:.82rem">{{ topicName }}</div>
        <div class="msub">{{ partitions }} partitions &nbsp;·&nbsp; RF {{ rf }} &nbsp;·&nbsp; Live configuration from Kafka</div>
      </div>
      <button class="mclose" @click="$emit('close')">✕</button>
    </div>
    <div class="mbody">

      <!-- toolbar row -->
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:14px">
        <button class="btn btn-cyan" @click="retrieve" :disabled="loading || saving">
          <span v-if="loading" class="spinner"></span>
          <span v-else>↻ Retrieve</span>
        </button>
        <template v-if="!editMode">
          <button class="btn btn-sm" @click="startEdit" :disabled="loading">Edit Config</button>
        </template>
        <template v-else>
          <button class="btn btn-primary" style="font-size:.68rem;padding:5px 14px" @click="saveEdits" :disabled="saving">
            <span v-if="saving" class="spinner"></span>
            <span v-else>✓ Update</span>
          </button>
          <button class="btn btn-sm" @click="cancelEdit" :disabled="saving">Cancel</button>
        </template>
        <span v-if="editMode" style="font-size:.62rem;color:var(--accent-amber);margin-left:4px">Edit mode — modified values will be pushed to Kafka</span>
      </div>

      <div v-if="error" style="color:var(--accent-red);font-size:.72rem;margin-bottom:10px">{{ error }}</div>
      <div v-if="saveError" style="color:var(--accent-red);font-size:.72rem;margin-bottom:10px">{{ saveError }}</div>

      <div v-if="loading" style="text-align:center;padding:32px 0">
        <span class="spinner" style="width:20px;height:20px"></span>
      </div>
      <div v-else-if="!configEntries.length && !error" style="text-align:center;padding:24px;color:var(--text-muted);font-size:.72rem">No config data returned.</div>
      <table v-else class="ctbl">
        <tbody>
          <tr v-for="[key, entry] in configEntries" :key="key">
            <td class="kc">
              {{ key }}
              <span v-if="entry.is_read_only" class="def-tag">read-only</span>
            </td>
            <td class="vc">
              <template v-if="editMode && !entry.is_read_only">
                <input v-model="edits[key]" :placeholder="entry.value">
              </template>
              <template v-else>
                {{ entry.value }}
                <span v-if="entry.is_default" class="def-tag">default</span>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    <div class="mfoot">
      <button class="btn btn-secondary" @click="$emit('close')">Close</button>
    </div>
  </div>
</div>
`,
};
