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
            // v1.3.0 (NGNX-APP-000180): the notice is shown BEFORE the sign-in
            // form, and the server refuses a sign-in without the acceptance.
            showConsent: false, consentRequired: false, consentAccepted: false,
            consentText: '', consentError: '',
        };
    },
    computed: {
        // The operator replacement text, one paragraph per blank-line block;
        // empty means the standard DoD wording in the template below.
        consentParagraphs() {
            return this.consentText.split(/\n\s*\n/).map(p => p.trim()).filter(Boolean);
        },
    },
    async mounted() { await this.loadConsent(); },
    methods: {
        async loadConsent() {
            try {
                const r = await fetch('/api/settings/public');
                const s = r.ok ? await r.json() : {};
                this.consentRequired = s.dow_enabled === 'true';
                this.consentText = typeof s.dow_text === 'string' ? s.dow_text : '';
            } catch (_) { /* the server decides at sign-in either way */ }
            this.showConsent = this.consentRequired && !this.consentAccepted;
        },
        async submit() {
            if (!this.username || !this.password) { this.error = 'Username and password are required.'; return; }
            this.error = '';
            if (this.consentRequired && !this.consentAccepted) { this.showConsent = true; return; }
            this.doLogin();
        },
        cancelConsent() {
            this.showConsent = false;
            this.error = 'You must accept the notice to sign in.';
        },
        async agreeConsent() {
            this.consentError = '';
            try {
                const r = await fetch('/api/auth/consent', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    // The text this page DISPLAYED ('' = the standard wording):
                    // the server refuses an acceptance of a notice it no longer has.
                    body: JSON.stringify({ accepted: true, notice: this.consentText }),
                });
                if (r.status === 409) {
                    await this.loadConsent();
                    this.consentError = 'The notice changed while this page was open. Read the notice now shown and accept it again.';
                    return;
                }
                if (!r.ok) { this.consentError = 'The acceptance could not be recorded (HTTP ' + r.status + '). Try again.'; return; }
            } catch {
                // Unreachable server: nothing was recorded, so say so and stay on the notice.
                this.consentError = 'Network error: the acceptance could not be recorded. Try again.';
                return;
            }
            this.consentAccepted = true;
            this.showConsent = false;
            this.error = '';
        },
        async doLogin() {
            this.loading = true; this.error = '';
            try {
                const r = await fetch('/api/auth/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: this.username, password: this.password }),
                });
                // v1.2.0: nginx rate-limits sign-in. Its 429 is JSON when the
                // site config is current, but a response that is NOT JSON
                // (an older site file, a proxy in between) must not land in
                // the catch below and be reported as a network error.
                let data = {};
                try { data = await r.json(); } catch (_) { data = {}; }
                if (r.status === 403 && data.code === 'consent_required') {
                    // The acceptance expired (or another tab signed in with it).
                    this.consentAccepted = false;
                    this.showConsent = true;
                    this.error = data.error || 'Accept the notice before signing in.';
                    return;
                }
                if (r.status === 429 && data.code === 'rate_limited') {
                    this.error = 'Too many sign-in attempts from this address. Wait a minute and try again.';
                    return;
                }
                if (!r.ok) {
                    if (r.status === 503 && data.error === 'audit_unavailable') {
                        this.error = 'Sign-in was blocked because the audit trail is unavailable. No sign-in session was issued. Ask an administrator to restore audit logging before retrying.';
                        return;
                    }
                    if (r.status === 500 && data.error === 'audit_write_failed') {
                        this.error = 'The sign-in change WAS made, but its audit record could not be written. Ask an administrator to check the audit database and AUDIT_WRITE_FAILED in the host syslog before signing in again.';
                        return;
                    }
                    this.error = data.error || (r.status === 429
                        ? 'Too many sign-in attempts from this address. Wait a minute and try again.'
                        : 'Login failed (HTTP ' + r.status + ')');
                    return;
                }
                // The server's own timeout travels with the user, so the idle
                // clock the browser arms is the one the session dies on.
                this.$emit('logged-in', data.user, data.timeout_minutes, data.session_ends_at);
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
        <div v-if="consentParagraphs.length" class="consent-custom">
          <p v-for="(para, i) in consentParagraphs" :key="i" style="margin-bottom:12px;white-space:pre-wrap">{{ para }}</p>
        </div>
        <template v-else>
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
        </template>
        <p v-if="consentError" class="login-err show">{{ consentError }}</p>
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
