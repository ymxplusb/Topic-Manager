// Jarvis Topic Manager — Delete Topic Confirmation Modal
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const DeleteTopicModal = {
    name: 'DeleteTopicModal',
    props: ['topicName'],
    emits: ['close', 'confirmed'],
    data() {
        return { confirmInput: '', deleting: false, error: '' };
    },
    computed: {
        canDelete() { return this.confirmInput === this.topicName && !this.deleting; },
    },
    watch: {
        topicName() { this.confirmInput = ''; this.error = ''; },
    },
    methods: {
        async doDelete() {
            if (!this.canDelete) return;
            this.deleting = true; this.error = '';
            try {
                const params = new URLSearchParams(window.location.search);
                const cluster = params.get('cluster') || '';
                const url = `/api/topics/${encodeURIComponent(this.topicName)}${cluster ? '?cluster=' + cluster : ''}`;
                const r = await fetch(url, { method: 'DELETE' });
                const data = await r.json();
                if (!r.ok) { this.error = data.error || 'Delete failed'; return; }
                this.$emit('confirmed', this.topicName);
            } catch (e) {
                this.error = 'Network error';
            } finally {
                this.deleting = false;
            }
        },
    },
    template: `
<div class="mback open" @click.self="$emit('close')">
  <div class="modal">
    <div class="mhdr">
      <div>
        <div class="mtitle" style="color:var(--accent-red)">⚠ Delete Topic</div>
        <div class="msub">This action is irreversible</div>
      </div>
      <button class="mclose" @click="$emit('close')">✕</button>
    </div>
    <div class="mbody">
      <div class="del-warn">
        <span class="wi">⚠️</span>
        <div class="wt">
          You are about to permanently delete <strong>{{ topicName }}</strong>.<br>
          All messages in this topic will be lost immediately. Active consumers will receive errors.
          <strong>This cannot be undone.</strong>
        </div>
      </div>
      <div class="confirm-wrap">
        <label>Type the topic name to confirm: <code>{{ topicName }}</code></label>
        <input class="fc" type="text" v-model="confirmInput" placeholder="Type exact topic name…" style="font-family:var(--mono)" @keyup.enter="doDelete">
      </div>
      <div v-if="error" style="margin-top:10px;color:var(--accent-red);font-size:.72rem">{{ error }}</div>
    </div>
    <div class="mfoot">
      <button class="btn btn-secondary" @click="$emit('close')" :disabled="deleting">Cancel</button>
      <button class="btn btn-danger" :disabled="!canDelete" @click="doDelete">
        <span v-if="deleting" class="spinner"></span>
        <span v-else>Delete Topic</span>
      </button>
    </div>
  </div>
</div>
`,
};
