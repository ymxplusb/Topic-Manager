// Jarvis Topic Manager — Cluster Builder Modal
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
//
// Lives under modals/ deliberately: the frontend-syntax gate globs
// app/components/*.js and app/components/modals/*.js, and a NEW subdirectory
// would sit outside both. There is no build step here, so a syntax error in
// this file ships straight to the browser as a blank pane.
//
// Certificates are read as TEXT and posted as CONTENT. The API never accepts a
// path: a user-supplied ssl_cafile would make the cluster test a file-read
// oracle, because the test route hands librdkafka's error back verbatim and
// any authenticated user can download the audit CSV.
const ClusterModal = {
    name: 'ClusterModal',
    props: ['cluster', 'protocols', 'mechanisms'],
    emits: ['close', 'saved'],
    data() {
        const c = this.cluster || {};
        return {
            isEdit: !!this.cluster,
            id: c.id || '',
            name: c.name || '',
            bootstrapServers: c.bootstrap_servers || '',
            securityProtocol: c.security_protocol || 'PLAINTEXT',
            saslMechanism: c.sasl_mechanism || 'PLAIN',
            saslUsername: c.sasl_username || '',
            saslPassword: '',
            hasSaslPassword: !!c.has_sasl_password,
            active: !!c.active,
            // Existing material, by basename. The full path is never sent to
            // the browser — the directory is not the operator's business.
            existing: {
                ssl_cafile: c.ssl_cafile || '',
                ssl_certfile: c.ssl_certfile || '',
                ssl_keyfile: c.ssl_keyfile || '',
            },
            // PEM text staged for upload, keyed by the field it replaces.
            pem: { ssl_cafile: '', ssl_certfile: '', ssl_keyfile: '' },
            pemName: { ssl_cafile: '', ssl_certfile: '', ssl_keyfile: '' },
            cleared: { ssl_cafile: false, ssl_certfile: false, ssl_keyfile: false },
            certFields: [
                { key: 'ssl_cafile',   label: 'CA Certificate',     hint: 'PEM bundle that signs the broker certificates.' },
                { key: 'ssl_certfile', label: 'Client Certificate', hint: 'Only for mutual TLS.' },
                { key: 'ssl_keyfile',  label: 'Client Private Key', hint: 'Unencrypted PEM. Only for mutual TLS.' },
            ],
            saving: false,
            error: '',
        };
    },
    computed: {
        usesTls()  { return this.securityProtocol.indexOf('SSL')  !== -1; },
        usesSasl() { return this.securityProtocol.indexOf('SASL') !== -1; },
        protocolList()  { return this.protocols  && this.protocols.length  ? this.protocols  : ['PLAINTEXT', 'SSL', 'SASL_SSL']; },
        mechanismList() { return this.mechanisms && this.mechanisms.length ? this.mechanisms : ['PLAIN']; },
    },
    methods: {
        certState(key) {
            if (this.pemName[key]) return 'staged: ' + this.pemName[key];
            if (this.cleared[key]) return 'will be removed on save';
            if (this.existing[key]) return 'loaded: ' + this.existing[key];
            return 'none';
        },
        pickCert(key) {
            const input = document.createElement('input');
            input.type = 'file';
            input.accept = '.pem,.crt,.cer,.key,.txt';
            input.onchange = e => {
                const file = e.target.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = ev => {
                    this.pem[key] = ev.target.result;
                    this.pemName[key] = file.name;
                    this.cleared[key] = false;
                    this.error = '';
                };
                reader.onerror = () => { this.error = 'Could not read ' + file.name; };
                reader.readAsText(file);
            };
            input.click();
        },
        // A method rather than an inline expression: `&&` inside an attribute
        // value depends on the in-browser template compiler decoding entities,
        // and there is no build step here to catch it if it does not.
        canClear(key) {
            return !!(this.pemName[key] || this.existing[key]);
        },
        clearCert(key) {
            this.pem[key] = '';
            this.pemName[key] = '';
            this.cleared[key] = !!this.existing[key];
        },
        async submit() {
            const id = this.id.trim().toLowerCase();
            if (!id) { this.error = 'Cluster ID is required'; return; }
            if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(id)) {
                this.error = 'Cluster ID: lowercase letters, digits, dot, underscore or hyphen only, starting with a letter or digit';
                return;
            }
            if (!this.name.trim()) { this.error = 'Display name is required'; return; }
            if (!this.bootstrapServers.trim()) { this.error = 'Bootstrap servers are required'; return; }
            if (this.usesSasl && !this.saslUsername.trim()) {
                this.error = 'SASL username is required for ' + this.securityProtocol;
                return;
            }
            if (this.usesSasl && !this.saslPassword && !this.hasSaslPassword) {
                this.error = 'SASL password is required for ' + this.securityProtocol;
                return;
            }

            const body = {
                id: id,
                name: this.name.trim(),
                bootstrap_servers: this.bootstrapServers.trim(),
                security_protocol: this.securityProtocol,
                active: this.active,
            };
            if (this.usesSasl) {
                body.sasl_mechanism = this.saslMechanism;
                body.sasl_username = this.saslUsername.trim();
                // Omitted when blank, so re-saving a profile keeps the stored
                // credential rather than silently blanking it.
                if (this.saslPassword) body.sasl_password = this.saslPassword;
            }
            if (this.usesTls) {
                this.certFields.forEach(f => {
                    if (this.pem[f.key]) body[f.key + '_pem'] = this.pem[f.key];
                    else if (this.cleared[f.key]) body[f.key + '_clear'] = true;
                });
            }

            this.saving = true;
            this.error = '';
            try {
                const url = this.isEdit ? '/api/clusters/' + encodeURIComponent(this.cluster.id) : '/api/clusters';
                const r = await fetch(url, {
                    method: this.isEdit ? 'PUT' : 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body),
                });
                const data = await r.json();
                if (!r.ok) { this.error = data.error || 'Save failed'; return; }
                this.$emit('saved', data.cluster);
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
        <div class="mtitle">{{ isEdit ? 'Edit Cluster Profile' : 'Add Cluster Profile' }}</div>
        <div class="msub">Saved to /etc/topic-manager/clusters.d/clusters.yaml — no service restart needed</div>
      </div>
      <button class="mclose" @click="$emit('close')">✕</button>
    </div>
    <div class="mbody">
      <div class="fsect">Identity</div>
      <div class="frow">
        <div class="fg">
          <label>Cluster ID <span class="req">*</span></label>
          <input class="fc" type="text" v-model="id" :disabled="isEdit"
                 placeholder="e.g. bare-metal" style="font-family:var(--mono)">
          <div class="fhint">{{ isEdit ? 'The ID is fixed once created — it is the routing key for every topic view.' : 'Lowercase letters, digits, dot, underscore, hyphen.' }}</div>
        </div>
        <div class="fg">
          <label>Display Name <span class="req">*</span></label>
          <input class="fc" type="text" v-model="name" placeholder="e.g. Bare Metal — Legacy Jarvis">
          <div class="fhint">Shown in the cluster picker. Must be unique.</div>
        </div>
      </div>
      <div class="frow s1">
        <div class="fg">
          <label>Bootstrap Servers <span class="req">*</span></label>
          <input class="fc" type="text" v-model="bootstrapServers"
                 placeholder="broker1.example.com:9092,broker2.example.com:9092"
                 style="font-family:var(--mono)">
          <div class="fhint">host:port, comma separated. No scheme, no spaces.</div>
        </div>
      </div>

      <div class="fsect">Security</div>
      <div class="frow">
        <div class="fg">
          <label>Security Protocol</label>
          <select class="fc" v-model="securityProtocol">
            <option v-for="p in protocolList" :key="p" :value="p">{{ p }}</option>
          </select>
        </div>
        <div class="fg">
          <label>Active Cluster</label>
          <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-size:.72rem;padding-top:7px">
            <input type="checkbox" v-model="active" style="accent-color:var(--accent-cyan)">
            Make this the default cluster
          </label>
          <div class="fhint">Exactly one profile is the default; setting this clears the others.</div>
        </div>
      </div>

      <div v-if="usesSasl">
        <div class="frow">
          <div class="fg">
            <label>SASL Mechanism</label>
            <select class="fc" v-model="saslMechanism">
              <option v-for="m in mechanismList" :key="m" :value="m">{{ m }}</option>
            </select>
          </div>
          <div class="fg">
            <label>SASL Username <span class="req">*</span></label>
            <input class="fc" type="text" v-model="saslUsername" autocomplete="off">
          </div>
        </div>
        <div class="frow s1">
          <div class="fg">
            <label>SASL Password <span class="req" v-if="!hasSaslPassword">*</span></label>
            <input class="fc" type="password" v-model="saslPassword" autocomplete="new-password"
                   :placeholder="hasSaslPassword ? 'unchanged — type to replace' : ''">
            <div class="fhint">Write-only. It is never returned by the API and never written to the audit log.</div>
          </div>
        </div>
      </div>

      <div v-if="usesTls">
        <div class="fsect">TLS Material</div>
        <div class="fhint" style="margin-bottom:8px">
          Upload the PEM itself, not a path. The file is parsed before it is stored,
          the name is generated by the server, and it is written to
          /opt/topic-manager/data/cluster-certs.
        </div>
        <div class="frow s1" v-for="f in certFields" :key="f.key">
          <div class="fg">
            <label>{{ f.label }}</label>
            <div style="display:flex;align-items:center;gap:8px">
              <button class="btn btn-sm" @click="pickCert(f.key)">⬆ Choose PEM</button>
              <button class="btn btn-sm" @click="clearCert(f.key)"
                      :disabled="!canClear(f.key)">Clear</button>
              <span style="font-size:.66rem;color:var(--text-muted);font-family:var(--mono)">{{ certState(f.key) }}</span>
            </div>
            <div class="fhint">{{ f.hint }}</div>
          </div>
        </div>
      </div>

      <div v-if="error" style="margin-top:6px;color:var(--accent-red);font-size:.72rem">{{ error }}</div>
    </div>
    <div class="mfoot">
      <button class="btn btn-secondary" @click="$emit('close')" :disabled="saving">Cancel</button>
      <button class="btn btn-primary" @click="submit" :disabled="saving">
        <span v-if="saving" class="spinner"></span>
        <span v-else>{{ isEdit ? 'Save Changes' : 'Add Cluster' }}</span>
      </button>
    </div>
  </div>
</div>
`,
};
