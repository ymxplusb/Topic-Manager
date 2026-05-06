// Jarvis Topic Manager — About / Third-Party Modal
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const AboutModal = {
    name: 'AboutModal',
    emits: ['close'],
    data() {
        return {
            version: '1.0.0',
            frontend: [
                { name: 'Vue.js',          version: '3.5.13',   license: 'MIT',       url: 'vuejs.org' },
            ],
            backend: [
                { name: 'Flask',           version: '3.1.0',    license: 'BSD-3',     url: 'flask.palletsprojects.com' },
                { name: 'gunicorn',        version: '23.0.0',   license: 'MIT',       url: 'gunicorn.org' },
                { name: 'ldap3',           version: '2.9.1',    license: 'LGPL-3.0',  url: 'ldap3.readthedocs.io' },
                { name: 'confluent-kafka', version: '2.6.1',    license: 'Apache-2.0',url: 'confluent.io' },
                { name: 'PyYAML',          version: '6.0.2',    license: 'MIT',       url: 'pyyaml.org' },
                { name: 'cryptography',    version: '44.0.2',   license: 'Apache-2.0 / BSD', url: 'cryptography.io' },
                { name: 'Werkzeug',        version: '3.1.3',    license: 'BSD-3',     url: 'werkzeug.palletsprojects.com' },
            ],
            infra: [
                { name: 'nginx',           version: 'latest',   license: 'BSD-2',     url: 'nginx.org' },
                { name: 'Ubuntu',          version: '24.04 LTS',license: 'Various',   url: 'ubuntu.com' },
                { name: 'Python',          version: '3.12',     license: 'PSF-2.0',   url: 'python.org' },
                { name: 'Apache Kafka',    version: '3.8.x',    license: 'Apache-2.0',url: 'kafka.apache.org' },
            ],
        };
    },
    template: `
<div class="mback open" @click.self="$emit('close')">
  <div class="modal xl">
    <div class="mhdr">
      <div>
        <div class="mtitle">⚡ Jarvis Topic Manager</div>
        <div class="msub">Version {{ version }} &nbsp;·&nbsp; Copyright &copy; 2025–2026 James Rodman. All Rights Reserved.</div>
      </div>
      <button class="mclose" @click="$emit('close')">✕</button>
    </div>
    <div class="mbody">
      <div style="font-size:.72rem;color:var(--text-secondary);margin-bottom:18px;line-height:1.6">
        Standalone Kafka Topic Management frontend for the Jarvis ecosystem.<br>
        Designed for offline-capable deployment on Ubuntu 24.04 with AD authentication.
      </div>

      <div class="ssec" style="padding:0;overflow:hidden">
        <div class="about-sect">Frontend</div>
        <table class="about-tbl">
          <thead><tr><th>Component</th><th>Version</th><th>License</th><th>Source</th></tr></thead>
          <tbody>
            <tr v-for="p in frontend" :key="p.name">
              <td>{{ p.name }}</td>
              <td class="mono" style="font-size:.65rem">{{ p.version }}</td>
              <td class="lic">{{ p.license }}</td>
              <td style="font-size:.63rem;color:var(--text-muted)">{{ p.url }}</td>
            </tr>
          </tbody>
        </table>
        <div class="about-sect">Backend</div>
        <table class="about-tbl">
          <thead><tr><th>Component</th><th>Version</th><th>License</th><th>Source</th></tr></thead>
          <tbody>
            <tr v-for="p in backend" :key="p.name">
              <td>{{ p.name }}</td>
              <td class="mono" style="font-size:.65rem">{{ p.version }}</td>
              <td class="lic">{{ p.license }}</td>
              <td style="font-size:.63rem;color:var(--text-muted)">{{ p.url }}</td>
            </tr>
          </tbody>
        </table>
        <div class="about-sect">Infrastructure</div>
        <table class="about-tbl">
          <thead><tr><th>Component</th><th>Version</th><th>License</th><th>Source</th></tr></thead>
          <tbody>
            <tr v-for="p in infra" :key="p.name">
              <td>{{ p.name }}</td>
              <td class="mono" style="font-size:.65rem">{{ p.version }}</td>
              <td class="lic">{{ p.license }}</td>
              <td style="font-size:.63rem;color:var(--text-muted)">{{ p.url }}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div style="margin-top:14px;font-size:.65rem;color:var(--text-muted);line-height:1.6">
        Third-party licenses are reproduced in <strong style="color:var(--text-secondary)">NOTICES.md</strong> in the repository root.<br>
        This product includes software developed by third parties under the licenses listed above.
      </div>
    </div>
    <div class="mfoot">
      <button class="btn btn-secondary" @click="$emit('close')">Close</button>
    </div>
  </div>
</div>
`,
};
