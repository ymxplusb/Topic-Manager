const { createApp, ref, computed, onMounted, onUnmounted } = Vue;

// Fired when the idle timer signs the user out, so the login view can say
// why they are looking at it. A module-level constant rather than a magic
// string repeated at both ends.
const IDLE_NOTICE = 'You were signed out after 15 minutes of inactivity.';
// v1.3.0 (SRG-APP-000295): the absolute session lifetime. The server owns it
// (created_at + Settings > Security > Sessions); the browser signs out a few
// seconds before, so the sign-out is recorded rather than refused.
const ABSOLUTE_NOTICE = 'You were signed out because the session reached its maximum lifetime. Sign in again to continue.';
// Seconds of warning before the sign-out. The countdown runs INSIDE the
// session window - the browser signs out a few seconds EARLY (see
// LOGOUT_LEAD_MS) so the request that records the event still carries a
// session the server considers valid.
const IDLE_WARN_SECONDS = 60;
// Sign out this far before the server's own expiry. Without the lead the
// two clocks race: the browser posts /api/auth/logout at the same instant
// the row expires, require_auth answers 401, and the sign-out is never
// audited - the one event an auditor most wants to see would be the one
// event reliably missing.
const LOGOUT_LEAD_MS = 5000;
// A session the SERVER ended (an administrator's End sessions, a failed group
// re-check, a lifetime the browser's clock missed): the next request is a
// 401. Before WO-0006 the app kept its shell and each tab showed
// "Authentication required" inside it; now any 401 from a signed-in view
// returns to the sign-in page and says why.
const ENDED_NOTICE = 'Your session was ended. Sign in again to continue.';
let tmSessionEnded = null;      // set by App.setup: (reason, error) => void

// CROSS-SITE REQUEST FORGERY (v1.2.0). The backend refuses any request that
// changes something unless the browser marks it same-origin (Sec-Fetch-Site)
// or it carries X-TM-Request: 1 (tm/routes.py _refuse_cross_site). Every
// mutation this app makes goes through fetch(), so the header is added HERE,
// once, to every non-GET request for this origin's /api/ - not at a dozen call
// sites where the next one added would be the one that forgot it. The browser
// still sends Sec-Fetch-Site itself; the header covers a browser that does not.
// The same wrapper sees every /api/ answer, so a 401 is noticed HERE (not in
// each tab): the sign-in routes (/api/auth/*) answer 401 for their own
// reasons and are left to the views that called them.
const TM_REQUEST_HEADER = 'X-TM-Request';
function tmWatchSession(input, r) {
    if (r?.status === 401 && tmSessionEnded && !input.startsWith('/api/auth/')) {
        const body = typeof r.clone === 'function' ? r.clone().json().catch(() => ({})) : Promise.resolve({});
        body.then(d => tmSessionEnded(d?.reason || '', d?.error || ''));
    }
    return r;
}
function tmMarkRequests(win) {
    const send = win.fetch.bind(win);
    win.fetch = (input, init) => {
        if (typeof input !== 'string' || !input.startsWith('/api/')) return send(input, init);
        const opts = init || {};
        const method = String(opts.method || 'GET').toUpperCase();
        if (method === 'GET' || method === 'HEAD') {
            return send(input, init).then(r => tmWatchSession(input, r));
        }
        const headers = new Headers(opts.headers || {});
        headers.set(TM_REQUEST_HEADER, '1');
        return send(input, { ...opts, headers }).then(r => tmWatchSession(input, r));
    };
}
tmMarkRequests(window);

const App = {
    components: { LoginView, TopBar, TopicsTab, ConsumerGroupsTab, AuditTab, SettingsTab, AboutModal },
    // ClusterModal is registered by SettingsTab, which is the only component
    // that renders it. Naming it here too would add a second definition-time
    // reference to the same global for no benefit.
    setup() {
        const user        = ref(null);
        const currentTab  = ref('topics');
        const clusters    = ref([]);
        const activeCluster = ref('');
        // Served by /api/clusters so the Cluster Builder offers exactly what
        // the backend will accept, rather than a second hardcoded list that
        // drifts from tm/clusters.py.
        const protocols   = ref([]);
        const mechanisms  = ref([]);
        const brokerMeta  = ref(null);
        const topicCount  = ref(0);
        const showAbout   = ref(false);
        // Not a version literal: this is the value shown BEFORE /api/version
        // answers. A hardcoded fallback asserts a specific version, so a host
        // that cannot reach its own API displays a confident wrong number —
        // exactly how this system showed 1.0.2 while running 1.0.0 for months.
        // 'unknown' renders literally in the Settings > Version row, which is
        // the truth when the API has not answered.
        const version     = ref('unknown');
        // Minutes of inactivity before sign-out. SERVED BY THE SERVER on
        // login and whoami; this is the value shown before either answers.
        // It is not policy - the server enforces `expires_at` regardless -
        // it is the clock the person watches, and it must be the same one.
        const timeoutMinutes = ref(15);
        const idleWarning    = ref(0);      // seconds left, 0 = not warning
        const loginNotice    = ref('');     // why the login view is showing
        // ISO time the session ends however active (served by login and
        // whoami); '' = not known.
        const sessionEndsAt  = ref('');
        let idleTimer = null, warnTimer = null, absoluteTimer = null;

        async function fetchVersion() {
            try {
                const r = await fetch('/api/version');
                if (r.ok) { const d = await r.json(); version.value = d.version || 'unknown'; }
            } catch { /* network unavailable — UI stays in previous state */ }
        }

        async function fetchClusters() {
            try {
                const r = await fetch('/api/clusters');
                if (r.ok) {
                    const d = await r.json();
                    clusters.value = d.clusters || [];
                    protocols.value = d.protocols || [];
                    mechanisms.value = d.sasl_mechanisms || [];
                    const active = clusters.value.find(c => c.active);
                    // The selected cluster can be deleted by the Cluster
                    // Builder while it is selected. Leaving activeCluster
                    // pointing at a profile that no longer exists makes every
                    // topic and consumer-group view fail with "cluster not
                    // found", so fall back to whichever profile is active now.
                    const stillThere = clusters.value.some(c => c.id === activeCluster.value);
                    if (!stillThere) activeCluster.value = active ? active.id
                        : (clusters.value[0] ? clusters.value[0].id : '');
                }
            } catch { /* network unavailable — UI stays in previous state */ }
        }

        async function checkSession() {
            try {
                const r = await fetch('/api/auth/whoami');
                if (r.ok) {
                    const d = await r.json();
                    user.value = d.user;
                    // A RELOAD MUST RE-ARM FROM THE SERVER'S NUMBER. Taking the
                    // frontend default here would run a 15-minute clock against
                    // a session configured for something else.
                    if (d.timeout_minutes) timeoutMinutes.value = d.timeout_minutes;
                    sessionEndsAt.value = d.session_ends_at || '';
                    armIdleTimer();
                    armAbsoluteTimer();
                }
            } catch { /* network unavailable — UI stays in previous state */ }
        }

        // ── the idle session ────────────────────────────────────────────
        //
        // James, 2026-09-02: "When session expires, it should automatically
        // log the user out. this should be after 15 minutes." Before this,
        // nothing in the browser watched the clock at all: an expired session
        // was discovered only when some later request happened to 401, and
        // until then the application sat on screen looking signed in.
        //
        // This is the layer a PERSON experiences. It is not the enforcement:
        // the server owns `expires_at` and refuses an expired session whether
        // or not any of this runs.
        function clearIdleTimers() {
            if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
            if (warnTimer) { clearInterval(warnTimer); warnTimer = null; }
            idleWarning.value = 0;
        }

        // Activity does NOT move this one. A timer longer than a setTimeout
        // can hold (about 24.8 days) is never armed: the lifetime is at most
        // 24 hours, so such a value is not one this server sent.
        function armAbsoluteTimer() {
            if (absoluteTimer) { clearTimeout(absoluteTimer); absoluteTimer = null; }
            const end = Date.parse(sessionEndsAt.value || '');
            if (!user.value || !Number.isFinite(end)) return;
            const wait = end - Date.now() - LOGOUT_LEAD_MS;
            if (wait > 2147483647) return;
            absoluteTimer = setTimeout(() => logout('absolute'), Math.max(0, wait));
        }

        function armIdleTimer() {
            clearIdleTimers();
            if (!user.value) return;
            const totalMs = Math.max(60000, timeoutMinutes.value * 60000) - LOGOUT_LEAD_MS;
            const warnAt  = Math.max(0, totalMs - IDLE_WARN_SECONDS * 1000);
            idleTimer = setTimeout(() => {
                idleWarning.value = IDLE_WARN_SECONDS;
                warnTimer = setInterval(() => {
                    idleWarning.value -= 1;
                    if (idleWarning.value <= 0) logout('idle');
                }, 1000);
            }, warnAt);
        }

        // Any real interaction is activity. The tab's own 30-second refresh
        // is NOT - it sends X-TM-Background so the server does not count it
        // either, and the two ends agree about what idle means.
        const ACTIVITY = ['mousedown', 'keydown', 'scroll', 'touchstart'];
        function onActivity() { if (user.value) armIdleTimer(); }

        async function logout(reason) {
            clearIdleTimers();
            if (absoluteTimer) { clearTimeout(absoluteTimer); absoluteTimer = null; }
            const why = ['idle', 'absolute'].includes(reason) ? reason : 'explicit';
            try {
                await fetch('/api/auth/logout', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ reason: why }),
                });
            } catch { /* the session still ends locally; the row may be missed */ }
            user.value = null; currentTab.value = 'topics'; sessionEndsAt.value = '';
            loginNotice.value = { idle: IDLE_NOTICE, absolute: ABSOLUTE_NOTICE }[why] || '';
        }

        // The server ended the session (see tmWatchSession): no sign-out is
        // posted - there is no session left to record it against, and the
        // server recorded the end (SESSION_EXPIRED / SESSION_REVOKED /
        // SESSIONS_ENDED) when it happened.
        function sessionEnded(reason, error) {
            if (!user.value) return;
            clearIdleTimers();
            if (absoluteTimer) { clearTimeout(absoluteTimer); absoluteTimer = null; }
            user.value = null; currentTab.value = 'topics'; sessionEndsAt.value = '';
            loginNotice.value = { idle: IDLE_NOTICE, absolute: ABSOLUTE_NOTICE }[reason]
                || (reason === 'revoked' && error) || ENDED_NOTICE;
        }
        tmSessionEnded = sessionEnded;

        // Pressing "Stay signed in" is itself activity: it re-arms the timer
        // and, because it is a real request, slides the server's row too.
        function staySignedIn() {
            armIdleTimer();
            fetch('/api/auth/whoami').catch(() => {});
        }

        function onLoggedIn(u, timeout, endsAt) {
            user.value = u;
            if (timeout) timeoutMinutes.value = timeout;
            sessionEndsAt.value = endsAt || '';
            loginNotice.value = '';
            armIdleTimer();
            armAbsoluteTimer();
            fetchClusters();
            fetchVersion();
        }

        function onClusterChanged(id) {
            activeCluster.value = id;
            fetch('/api/clusters/active', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ cluster_id: id }),
            });
        }

        // Classification banner colours. EXEMPT from the theme on purpose:
        // they are chosen in Settings and carry meaning, so no theme token may
        // reach them. SettingsTab.bannerColors holds the same values.
        const colorMap = { green:'#16a34a', blue:'#2563eb', purple:'#7c3aed',
                           red:'#dc2626', orange:'#ea580c', yellow:'#ca8a04' };
        const fgMap    = { white:'#ffffff', black:'#000000', grey:'#d1d5db' };

        function applyBannerFromSettings(s) {
            const enabled = s.banner_enabled === 'true';
            const bg  = colorMap[s.banner_bg]  || '#16a34a';
            const fg  = fgMap[s.banner_fg]     || '#ffffff';
            const txt = s.banner_text          || 'UNCLASSIFIED';
            ['banner-top', 'banner-bot'].forEach(id => {
                const el = document.getElementById(id);
                if (!el) return;
                el.style.display    = enabled ? 'block' : 'none';
                el.style.background = bg;
                el.style.color      = fg;
                el.textContent      = txt;
            });
            const pad = enabled ? '26px' : '0px';
            document.body.style.paddingTop    = pad;
            document.body.style.paddingBottom = pad;
        }

        onMounted(async () => {
            // The only theme path that runs BEFORE login. tmReadTheme and
            // tmApplyTheme live in TopBar.js (loaded first by index.html): one
            // validated reader, so a malformed saved value or an unavailable
            // localStorage can neither pick a class nor throw out of here.
            tmApplyTheme(tmReadTheme());

            try {
                const r = await fetch('/api/settings/public');
                if (r.ok) applyBannerFromSettings(await r.json());
            } catch { /* network unavailable — UI stays in previous state */ }

            checkSession().then(() => {
                if (user.value) { fetchClusters(); fetchVersion(); }
            });
            ACTIVITY.forEach(e => document.addEventListener(e, onActivity,
                                                           { passive: true }));
        });

        onUnmounted(() => {
            clearIdleTimers();
            if (absoluteTimer) clearTimeout(absoluteTimer);
            if (tmSessionEnded === sessionEnded) tmSessionEnded = null;
            ACTIVITY.forEach(e => document.removeEventListener(e, onActivity));
        });

        return { user, currentTab, clusters, activeCluster, protocols, mechanisms,
                 brokerMeta, topicCount, showAbout, version,
                 idleWarning, loginNotice, staySignedIn,
                 onLoggedIn, logout, onClusterChanged, fetchClusters };
    },
    template: `
<div id="app-shell" v-if="user">
  <TopBar
    :user="user"
    :clusters="clusters"
    :active-cluster-id="activeCluster"
    :broker-meta="brokerMeta"
    @logout="logout"
    @cluster-changed="onClusterChanged"
    @open-about="showAbout = true"
  />
  <nav class="app-nav">
    <button class="ntab" :class="{ act: currentTab === 'topics' }"   @click="currentTab = 'topics'">
      Topics
    </button>
    <button class="ntab" :class="{ act: currentTab === 'cgroups' }"  @click="currentTab = 'cgroups'">Consumer Groups</button>
    <button class="ntab" :class="{ act: currentTab === 'audit' }"    @click="currentTab = 'audit'">Audit Log</button>
    <button class="ntab" :class="{ act: currentTab === 'settings' }" @click="currentTab = 'settings'">Settings</button>
  </nav>
  <div class="app-content">
    <TopicsTab          v-if="currentTab === 'topics'"   :cluster-id="activeCluster" @topic-count="topicCount = $event" />
    <ConsumerGroupsTab  v-if="currentTab === 'cgroups'"  :cluster-id="activeCluster" />
    <AuditTab           v-if="currentTab === 'audit'" />
    <SettingsTab        v-if="currentTab === 'settings'"
      :clusters="clusters"
      :active-cluster-id="activeCluster"
      :version="version"
      :protocols="protocols"
      :mechanisms="mechanisms"
      @open-about="showAbout = true"
      @cluster-changed="onClusterChanged"
      @clusters-changed="fetchClusters"
    />
  </div>
  <AboutModal v-if="showAbout" @close="showAbout = false" />
  <div v-if="idleWarning > 0" class="idle-warn" role="alertdialog" aria-live="assertive">
    <div class="idle-warn-card">
      <h3>Still there?</h3>
      <p>You will be signed out in <b>{{ idleWarning }}</b> second{{ idleWarning === 1 ? '' : 's' }} because of inactivity.</p>
      <div class="idle-warn-actions">
        <button class="btn btn-primary" @click="staySignedIn">Stay signed in</button>
        <button class="btn" @click="logout('explicit')">Sign out now</button>
      </div>
    </div>
  </div>
</div>
<LoginView v-else :notice="loginNotice" @logged-in="onLoggedIn" />
`,
};

createApp(App).mount('#app-mount');
