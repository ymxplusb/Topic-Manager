// Jarvis Topic Manager — Login View
// Copyright (c) 2025-2026 James Rodman. All Rights Reserved.
const LoginView = {
    name: 'LoginView',
    emits: ['logged-in'],
    data() {
        return { username: '', password: '', loading: false, error: '' };
    },
    methods: {
        async submit() {
            if (!this.username || !this.password) { this.error = 'Username and password are required.'; return; }
            this.loading = true; this.error = '';
            try {
                const r = await fetch('/api/auth/login', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ username: this.username, password: this.password }),
                });
                const data = await r.json();
                if (!r.ok) { this.error = data.error || 'Login failed'; return; }
                this.$emit('logged-in', data.user);
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
      <span class="glyph">⚡</span>
      <span class="brand"><span>JARVIS</span> TOPIC MANAGER</span>
    </div>
    <h2 class="login-title">Sign In</h2>
    <p class="login-sub">Authenticate with your Active Directory credentials</p>
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
      <span>kafka-topics.int.crypticlight.com</span><br>
      <span style="color:var(--text-muted)">TLS 1.3 &nbsp;·&nbsp; 30 min session &nbsp;·&nbsp; All actions audit logged</span>
    </div>
  </div>
</div>
`,
};
