// Jarvis Topic Manager — Create Topic Modal
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const CreateTopicModal = {
    name: 'CreateTopicModal',
    props: ['clusterId'],
    emits: ['close', 'created'],
    data() {
        return {
            name: '', partitions: 3, rf: 3,
            retentionMs: '604800000', retentionBytes: '-1',
            cleanupPolicy: 'delete', compressionType: 'producer',
            minIsr: 2, maxMsgBytes: 1048588,
            saving: false, error: '',
        };
    },
    methods: {
        reset() {
            Object.assign(this.$data, { name:'', partitions:3, rf:3, retentionMs:'604800000', retentionBytes:'-1', cleanupPolicy:'delete', compressionType:'producer', minIsr:2, maxMsgBytes:1048588, saving:false, error:'' });
        },
        async submit() {
            const n = this.name.trim();
            if (!n) { this.error = 'Topic name is required'; return; }
            if (!/^[a-zA-Z0-9._-]+$/.test(n)) { this.error = 'Only alphanumeric, dots, hyphens, underscores allowed'; return; }
            this.saving = true; this.error = '';
            try {
                const qs = this.clusterId ? `?cluster=${this.clusterId}` : '';
                const r = await fetch(`/api/topics${qs}`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        name: n,
                        partitions: +this.partitions,
                        replication_factor: +this.rf,
                        retention_ms: +this.retentionMs,
                        retention_bytes: +this.retentionBytes,
                        cleanup_policy: this.cleanupPolicy,
                        compression_type: this.compressionType,
                        min_insync_replicas: +this.minIsr,
                        max_message_bytes: +this.maxMsgBytes,
                    }),
                });
                const data = await r.json();
                if (!r.ok) { this.error = data.error || 'Create failed'; return; }
                this.$emit('created', data.name);
            } catch (e) {
                this.error = 'Network error';
            } finally {
                this.saving = false;
            }
        },
    },
    template: `
<div class="mback open" @click.self="$emit('close')">
  <div class="modal lg">
    <div class="mhdr">
      <div>
        <div class="mtitle">Create New Topic</div>
        <div class="msub">New topic will be created on the active cluster</div>
      </div>
      <button class="mclose" @click="$emit('close')">✕</button>
    </div>
    <div class="mbody">
      <div class="fsect">Basic Configuration</div>
      <div class="frow s1">
        <div class="fg">
          <label>Topic Name <span class="req">*</span></label>
          <input class="fc" type="text" v-model="name" placeholder="e.g. nifi.events.inbound" style="font-family:var(--mono)" @keyup.enter="submit">
          <div class="fhint">Dot-notation namespacing. Alphanumeric, dots, hyphens, underscores only.</div>
        </div>
      </div>
      <div class="frow">
        <div class="fg">
          <label>Partitions <span class="req">*</span></label>
          <input class="fc" type="number" v-model="partitions" min="1" max="200">
          <div class="fhint">Cannot decrease after creation.</div>
        </div>
        <div class="fg">
          <label>Replication Factor <span class="req">*</span></label>
          <input class="fc" type="number" v-model="rf" min="1" max="10">
          <div class="fhint">Must not exceed broker count.</div>
        </div>
      </div>

      <div class="fsect">Retention &amp; Storage</div>
      <div class="frow">
        <div class="fg">
          <label>Retention Time</label>
          <select class="fc" v-model="retentionMs">
            <option value="3600000">1 hour</option>
            <option value="21600000">6 hours</option>
            <option value="86400000">24 hours</option>
            <option value="604800000">7 days</option>
            <option value="1209600000">14 days</option>
            <option value="2592000000">30 days</option>
            <option value="7776000000">90 days</option>
            <option value="31536000000">1 year</option>
            <option value="-1">Unlimited</option>
          </select>
        </div>
        <div class="fg">
          <label>Retention Bytes</label>
          <select class="fc" v-model="retentionBytes">
            <option value="-1">Unlimited</option>
            <option value="104857600">100 MB</option>
            <option value="536870912">512 MB</option>
            <option value="1073741824">1 GB</option>
            <option value="5368709120">5 GB</option>
            <option value="10737418240">10 GB</option>
            <option value="53687091200">50 GB</option>
          </select>
        </div>
      </div>

      <div class="fsect">Advanced</div>
      <div class="frow">
        <div class="fg">
          <label>Cleanup Policy</label>
          <select class="fc" v-model="cleanupPolicy">
            <option value="delete">delete</option>
            <option value="compact">compact</option>
            <option value="compact,delete">compact + delete</option>
          </select>
        </div>
        <div class="fg">
          <label>Compression</label>
          <select class="fc" v-model="compressionType">
            <option value="producer">producer (inherit)</option>
            <option value="gzip">gzip</option>
            <option value="snappy">snappy</option>
            <option value="lz4">lz4</option>
            <option value="zstd">zstd</option>
            <option value="uncompressed">uncompressed</option>
          </select>
        </div>
      </div>
      <div class="frow">
        <div class="fg">
          <label>Min In-Sync Replicas</label>
          <input class="fc" type="number" v-model="minIsr" min="1" max="10">
          <div class="fhint">Must be ≤ Replication Factor</div>
        </div>
        <div class="fg">
          <label>Max Message Bytes</label>
          <input class="fc" type="number" v-model="maxMsgBytes" min="1">
          <div class="fhint">Default ≈ 1 MB</div>
        </div>
      </div>

      <div v-if="error" style="margin-top:6px;color:var(--accent-red);font-size:.72rem">{{ error }}</div>
    </div>
    <div class="mfoot">
      <button class="btn btn-secondary" @click="$emit('close')" :disabled="saving">Cancel</button>
      <button class="btn btn-primary" @click="submit" :disabled="saving">
        <span v-if="saving" class="spinner"></span>
        <span v-else>Create Topic</span>
      </button>
    </div>
  </div>
</div>
`,
};
