// Jarvis Topic Manager — Login View
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const LoginView = {
    name: 'LoginView',
    // `notice` says WHY the login view is on screen when it is not simply the
    // start of a visit - today, that the idle timeout signed them out. Being
    // returned to a login screen with no explanation reads as a fault.
    props: { notice: { type: String, default: '' } },
    emits: ['logged-in'],
    data() {
        return {
            username: '', password: '', loading: false, error: '',
            host: window.location.hostname,
            showConsent: false,
        };
    },
    methods: {
        async submit() {
            if (!this.username || !this.password) { this.error = 'Username and password are required.'; return; }
            this.error = '';
            try {
                const r = await fetch('/api/settings/public');
                const s = r.ok ? await r.json() : {};
                if (s.dow_enabled === 'true') {
                    this.showConsent = true;
                    return;
                }
            } catch (_) {}
            this.doLogin();
        },
        cancelConsent() {
            this.showConsent = false;
        },
        agreeConsent() {
            this.showConsent = false;
            this.doLogin();
        },
        async doLogin() {
            this.loading = true; this.error = '';
            try {
                const r = await fetch('/api/auth/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: this.username, password: this.password }),
                });
                const data = await r.json();
                if (!r.ok) { this.error = data.error || 'Login failed'; return; }
                // The server's own timeout travels with the user, so the idle
                // clock the browser arms is the one the session dies on.
                this.$emit('logged-in', data.user, data.timeout_minutes);
            } catch (e) {
                this.error = 'Network error — is the server reachable?';
            } finally {
                this.loading = false;
            }
        },
    },
    template: `
<div id="login-view">
  <div class="login-card">
    <div class="login-logo">
      <img src="/jarvis-logo.png" alt="Jarvis" style="height:56px;width:auto;object-fit:contain;margin-bottom:8px;display:block;margin-left:auto;margin-right:auto">
      <span class="brand"><span>JARVIS</span> TOPIC MANAGER</span>
    </div>
    <h2 class="login-title">Sign In</h2>
    <p class="login-sub">Authenticate with your Active Directory credentials</p>
    <div v-if="notice && !error" class="login-notice">{{ notice }}</div>
    <div class="login-err" :class="{show: error}">{{ error }}</div>
    <div class="fg" style="margin-bottom:12px">
      <label>Username</label>
      <input class="fc" type="text" v-model="username" placeholder="username or domain\\username" autocomplete="username" @keyup.enter="submit">
    </div>
    <div class="fg" style="margin-bottom:14px">
      <label>Password</label>
      <input class="fc" type="password" v-model="password" placeholder="AD password" autocomplete="current-password" @keyup.enter="submit">
    </div>
    <button class="btn btn-primary btn-full" @click="submit" :disabled="loading">
      <span v-if="loading" class="spinner"></span>
      <span v-else>Sign In</span>
    </button>
    <div class="login-meta">
      <span>{{ host }}</span>
    </div>
  </div>

  <!-- DoW Consent Modal — no @click.self handler, no way to dismiss without a button -->
  <div v-if="showConsent" class="mback open" style="backdrop-filter:blur(5px)">
    <div class="modal lg" style="max-height:80vh;display:flex;flex-direction:column">
      <div class="mhdr" style="flex-shrink:0">
        <div>
          <div class="mtitle" style="color:var(--accent-amber)">⚠ WARNING — Consent to Monitor</div>
          <div class="msub">U.S. Government Information System Notice</div>
        </div>
      </div>
      <div class="mbody" style="overflow-y:auto;flex:1;font-size:.78rem;color:var(--text-secondary);line-height:1.7">
        <p style="margin-bottom:12px">
          You are accessing a U.S. Government (USG) Information System (IS) that is provided for
          USG-authorized use only.
        </p>
        <p style="margin-bottom:12px">
          By using this IS (which includes any device attached to this IS), you consent to the
          following conditions:
        </p>
        <ul style="margin:0 0 12px 18px;display:flex;flex-direction:column;gap:8px">
          <li>The USG routinely intercepts and monitors communications on this IS for purposes
              including, but not limited to, penetration testing, COMSEC monitoring, network
              operations and defense, personnel misconduct (PM), law enforcement (LE), and
              counterintelligence (CI) investigations.</li>
          <li>At any time, the USG may inspect and seize data stored on this IS.</li>
          <li>Communications using, or data stored on, this IS are not private, are subject to
              routine monitoring, interception, and search, and may be disclosed or used for any
              USG-authorized purpose.</li>
          <li>This IS includes security measures (e.g., authentication and access controls) to
              protect USG interests — not for your personal benefit or privacy.</li>
          <li>Notwithstanding the above, using this IS does not constitute consent to PM, LE, or
              CI investigative searching or monitoring of the content of privileged communications
              or work product related to personal representation or services by attorneys,
              psychotherapists, or clergy and their assistants. Such communications and work
              product are private and confidential.</li>
        </ul>
        <p style="color:var(--text-muted);font-size:.72rem">
          Unauthorized use of this system is prohibited and subject to criminal and civil
          penalties. By clicking <strong style="color:var(--text-primary)">I Agree</strong>,
          you acknowledge that you have read and understand this notice and consent to the
          conditions above.
        </p>
      </div>
      <div class="mfoot" style="flex-shrink:0;padding-top:16px;border-top:1px solid var(--border-color)">
        <button class="btn btn-secondary" @click="cancelConsent">Cancel</button>
        <button class="btn btn-primary" @click="agreeConsent">I Agree</button>
      </div>
    </div>
  </div>
</div>
`,
};
