'use strict';
// NetPulse staff dashboard. Everything on screen is built with createElement/textContent (never innerHTML),
// so nothing a customer types (a name, an email) can ever run as code in a staff member's browser.

const API = '/api/v1/staff';
const TOKEN_KEY = 'np_staff_token'; // sessionStorage: gone when the tab closes
const app = document.getElementById('app');

const state = {
  token: null,
  staff: null,
  view: 'overview', // overview | requests | customers | issues | staff | account
  overview: null,
  activity: { items: [], next: null, staff: [], actions: [], loaded: false }, activityFilter: { staff_id: '', action: '', q: '', since: '', until: '', order: '' },
  summary: { pending_requests: 0, open_issues: 0 },
  remember: false, loginMode: 'signin', resetEmail: '', notice: null,
  q: '', searchKind: 'accounts', results: [], searched: false, // customers
  acctFilter: { status: '', balance: '', plan_id: '' }, acctSort: { key: 'account', dir: 'asc' }, moreResults: false,
  accountId: null, account: null, action: null, plans: [], // one customer's page, and which action panel is open
  issueFilter: 'OPEN', issueView: { category: '', q: '', order: '' }, issues: { counts: { OPEN: 0, RESOLVED: 0 }, items: [] }, issueOpen: null,
  filter: 'PENDING',
  requests: { counts: { PENDING: 0, APPROVED: 0, REJECTED: 0 }, items: [] },
  staffList: [],
  loading: false,
  error: null,
  open: null, // {id, mode: 'approve' | 'decline'}: a card with its confirm step showing
};

// ---------- tiny helpers ----------
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'value') el.value = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

let toastTimer;
function toast(message) {
  let el = document.getElementById('toast');
  if (!el) { el = h('div', { id: 'toast', role: 'status' }); document.body.append(el); }
  el.textContent = message;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 3200);
}

const fmtTime = (iso) => {
  if (!iso) return '';
  return new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' });
};

function ago(iso) {
  const mins = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 48) return `${hrs} hr ago`;
  return `${Math.round(hrs / 24)} days ago`;
}

async function api(path, { method = 'GET', body } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  const usedToken = state.token;
  if (state.token) headers.Authorization = `Bearer ${state.token}`;
  let res;
  try {
    res = await fetch(API + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  } catch {
    throw new Error("Can't reach the server. Check your connection.");
  }
  let data = null;
  try { data = await res.json(); } catch { /* no body */ }
  if (res.status === 401 && usedToken && usedToken !== state.token) throw new Error('signed out'); // token was replaced meanwhile (password change)
  if (res.status === 401 && state.token) {
    signOut('Your session ended. Please sign in again.');
    throw new Error('signed out');
  }
  if (!res.ok) {
    const detail = data && typeof data.detail === 'string' ? data.detail : null;
    throw new Error(detail || `Something went wrong (${res.status}).`);
  }
  return data;
}

// ---------- session ----------
// "Keep me signed in" puts the token in localStorage (the server then makes it last 14 days); without it the token
// lives in sessionStorage and is gone when the tab closes (the server makes that one last 12 hours).
const EMAIL_KEY = 'np_staff_email'; // only saved when "keep me signed in" is ticked, to prefill the email box

function readStored(storage, key) {
  try { return window[storage].getItem(key); } catch { return null; }
}

function writeStored(storage, key, value) {
  try {
    if (value == null) window[storage].removeItem(key); else window[storage].setItem(key, value);
  } catch { /* private mode or blocked storage: it just won't be remembered */ }
}

function saveSession(token, staff, remember) {
  state.token = token;
  state.staff = staff;
  state.remember = !!remember;
  writeStored('sessionStorage', TOKEN_KEY, remember ? null : token);
  writeStored('localStorage', TOKEN_KEY, remember ? token : null);
}

function signOut(message) {
  state.token = null;
  state.staff = null;
  state.open = null;
  state.remember = false;
  state.loginMode = 'signin';
  writeStored('sessionStorage', TOKEN_KEY, null);
  writeStored('localStorage', TOKEN_KEY, null); // a real sign-out forgets this device too
  state.error = message || null;
  render();
}

// ---------- sign in / forgot password ----------
const PASSWORD_HINT = '10+ characters, with a capital letter and a number.';

function loginShell(title, subtitle, ...content) {
  app.replaceChildren(h('div', { class: 'login-wrap' },
    h('div', { class: 'login-card' },
      h('div', { class: 'brand' }, h('span', { class: 'brand-mark' }), 'NetPulse'),
      h('h1', {}, title),
      h('p', {}, subtitle),
      ...content)));
}

function errorBox(message) {
  const box = h('div', { class: 'error', role: 'alert' }, message);
  if (!message) box.classList.add('hidden');
  return {
    el: box,
    show(text) { box.textContent = text; box.classList.remove('hidden'); },
    hide() { box.classList.add('hidden'); },
  };
}

function renderLogin() {
  if (state.loginMode === 'forgot') return renderForgot();
  if (state.loginMode === 'reset') return renderReset();
  const email = h('input', { type: 'email', autocomplete: 'username', required: true, autofocus: true, value: readStored('localStorage', EMAIL_KEY) || '' });
  const password = h('input', { type: 'password', autocomplete: 'current-password', required: true });
  const keep = h('input', { type: 'checkbox', id: 'keep', checked: !!readStored('localStorage', EMAIL_KEY) });
  const error = errorBox(state.error);
  const notice = state.notice ? h('div', { class: 'notice', role: 'status' }, state.notice) : null;
  const submit = h('button', { class: 'btn primary block', type: 'submit' }, 'Sign in');
  const form = h('form', {
    onsubmit: async (e) => {
      e.preventDefault();
      submit.disabled = true;
      error.hide();
      try {
        const d = await api('/login', { method: 'POST', body: { email: email.value, password: password.value, remember: keep.checked } });
        state.error = null; state.notice = null;
        saveSession(d.token, d.staff, keep.checked);
        writeStored('localStorage', EMAIL_KEY, keep.checked ? email.value.trim() : null);
        state.view = 'overview';
        render();
        loadOverview(true);
        loadSummary();
        liveLoop();
      } catch (err) {
        error.show(err.message);
        submit.disabled = false;
        password.value = '';
        password.focus();
      }
    },
  },
  h('label', {}, 'Email'), email,
  h('label', {}, 'Password'), password,
  h('div', { class: 'login-extras' },
    h('label', { class: 'check', for: 'keep' }, keep, 'Keep me signed in'),
    h('button', { class: 'link-btn', type: 'button', onclick: () => { state.loginMode = 'forgot'; state.error = null; state.notice = null; state.resetEmail = email.value.trim(); render(); } }, 'Forgot password?')),
  h('p', { class: 'muted hint' }, 'Keeps you signed in for 14 days. Only tick it on your own device.'),
  error.el, submit);
  loginShell('Staff sign in', 'For the service provider team.', notice, form);
  state.error = null; state.notice = null;
}

function renderForgot() {
  const email = h('input', { type: 'email', autocomplete: 'username', required: true, autofocus: true, value: state.resetEmail || '' });
  const error = errorBox(null);
  const submit = h('button', { class: 'btn primary block', type: 'submit' }, 'Email me a code');
  const form = h('form', {
    onsubmit: async (e) => {
      e.preventDefault();
      submit.disabled = true;
      error.hide();
      try {
        await api('/forgot-password', { method: 'POST', body: { email: email.value } });
        state.resetEmail = email.value.trim();
        state.loginMode = 'reset';
        state.notice = 'If that email belongs to a staff account, a 6-digit code is on its way. It works for 3 minutes.';
        render();
      } catch (err) {
        error.show(err.message);
        submit.disabled = false;
      }
    },
  },
  h('label', {}, 'Your staff email'), email, error.el, submit,
  h('button', { class: 'btn block', type: 'button', onclick: () => { state.loginMode = 'signin'; render(); } }, 'Back to sign in'));
  loginShell('Forgot your password?', "We'll email you a code to set a new one.", form);
}

function renderReset() {
  const sub = state.notice; // shown once, as this screen's subtitle, so it can't reappear on the sign-in screen later
  state.notice = null;
  const code = h('input', { inputmode: 'numeric', autocomplete: 'one-time-code', maxlength: '6', required: true, autofocus: true, placeholder: '6-digit code' });
  const next = h('input', { type: 'password', autocomplete: 'new-password', required: true, minlength: '10' });
  const again = h('input', { type: 'password', autocomplete: 'new-password', required: true });
  const error = errorBox(null);
  const submit = h('button', { class: 'btn primary block', type: 'submit' }, 'Set new password');
  const resend = h('button', { class: 'link-btn', type: 'button', onclick: async () => {
    resend.disabled = true;
    try {
      await api('/forgot-password', { method: 'POST', body: { email: state.resetEmail } });
      error.hide();
      toast('A new code is on its way.');
    } catch (err) { error.show(err.message); }
    setTimeout(() => { resend.disabled = false; }, 15000); // a short pause, so it can't be mashed
  } }, 'Send a new code');
  const form = h('form', {
    onsubmit: async (e) => {
      e.preventDefault();
      error.hide();
      if (next.value !== again.value) { error.show("The two passwords don't match."); again.value = ''; again.focus(); return; }
      submit.disabled = true;
      try {
        await api('/reset-password', { method: 'POST', body: { email: state.resetEmail, code: code.value, new_password: next.value } });
        state.loginMode = 'signin';
        state.notice = 'Your password was changed. Sign in with the new one.';
        render();
      } catch (err) {
        error.show(err.message);
        submit.disabled = false;
        if (/code/i.test(err.message)) { code.value = ''; code.focus(); }
      }
    },
  },
  h('label', {}, `Code sent to ${state.resetEmail}`), code,
  h('label', {}, 'New password'), next,
  h('p', { class: 'muted hint' }, PASSWORD_HINT),
  h('label', {}, 'Type the new password again'), again,
  error.el, submit,
  h('div', { class: 'login-extras center' }, resend,
    h('button', { class: 'link-btn', type: 'button', onclick: () => { state.loginMode = 'signin'; render(); } }, 'Back to sign in')));
  loginShell('Enter your code', sub || 'Check your email for the 6-digit code.', form);
}

// ---------- shell ----------
function go(view) {
  state.view = view;
  state.open = null; state.action = null; state.issueOpen = null;
  if (view === 'customers') { state.accountId = null; state.account = null; }
  render();
  if (view === 'overview') loadOverview(true);
  if (view === 'requests') loadRequests(true);
  if (view === 'issues') loadIssues(true);
  if (view === 'staff') loadStaff();
  if (view === 'activity') loadActivity(true);
  loadSummary();
}

function renderShell(content) {
  const badge = (key) => h('span', { class: `badge${state.summary[key] ? '' : ' hidden'}`, 'data-badge': key }, state.summary[key]);
  const tab = (view, label, extra) => h('button', {
    class: state.view === view ? 'active' : '',
    onclick: () => go(view),
  }, label, extra);
  const nav = h('nav', { class: 'nav' },
    tab('overview', 'Overview'),
    tab('requests', 'Requests', badge('pending_requests')),
    tab('customers', 'Customers'),
    tab('issues', 'Issues', badge('open_issues')),
    state.staff.role === 'admin' ? tab('activity', 'Activity') : null,
    state.staff.role === 'admin' ? tab('staff', 'Staff') : null,
    tab('account', 'Account'));
  const top = h('header', { class: 'topbar' }, h('div', { class: 'topbar-inner' },
    h('div', { class: 'brand' }, h('span', { class: 'brand-mark' }), 'NetPulse Staff'),
    nav,
    h('div', { class: 'who' },
      h('span', {}, h('strong', {}, state.staff.name), ` (${state.staff.role})`),
      h('button', { class: 'btn small', onclick: () => signOut() }, 'Sign out'))));
  app.replaceChildren(top, h('main', {}, content));
}

// ---------- link requests ----------
async function loadRequests(quiet) {
  try {
    state.requests = await api(`/link-requests?status=${state.filter}`);
    state.error = null;
  } catch (err) {
    if (err.message === 'signed out') return;
    state.error = err.message;
    if (!quiet) toast(err.message);
  }
  state.summary.pending_requests = state.requests.counts.PENDING;
  // A refresh while someone is half-way through confirming a decision must not wipe their form: only the badges update.
  if (state.view === 'requests' && !state.open) render();
  else updateBadges();
}

function updateBadges() {
  for (const el of document.querySelectorAll('[data-badge]')) {
    const n = state.summary[el.dataset.badge] || 0;
    el.textContent = n;
    el.classList.toggle('hidden', !n);
  }
}

async function loadSummary() {
  try { state.summary = await api('/summary'); updateBadges(); } catch { /* the badges just stay as they were */ }
}

function chip(kind, text) { return h('span', { class: `chip ${kind}` }, text); }

function row(label, value) { return h('div', { class: 'row' }, h('span', {}, label), h('span', {}, value || '-')); }

function requestCard(r) {
  const s = r.signals;
  const chips = h('div', { class: 'chips' },
    s.mobile_match ? chip('good', 'Mobile number matches') : chip('warn', "Mobile number doesn't match"),
    s.name_match ? chip('good', 'Name matches the account holder') : chip('warn', "Name doesn't match the account holder"),
    s.already_linked_logins > 0 ? chip('warn', `Already linked to ${s.already_linked_logins} other login${s.already_linked_logins > 1 ? 's' : ''}`) : null,
    s.other_pending_for_account > 0 ? chip('warn', `${s.other_pending_for_account} other pending request${s.other_pending_for_account > 1 ? 's' : ''} for this account`) : null);

  const body = [
    h('div', { class: 'card-head' },
      h('h3', {}, `${r.account.account_no}`),
      h('span', { class: 'muted', title: fmtTime(r.requested_at) }, `Requested ${ago(r.requested_at)}`)),
    r.status === 'PENDING' ? chips : null,
    h('div', { class: 'cols' },
      h('div', { class: 'box' }, h('h4', {}, 'Requested by'),
        row('Name', r.requester.name), row('Email', r.requester.email), row('Mobile', r.requester.mobile)),
      h('div', { class: 'box' }, h('h4', {}, 'Account on file'),
        row('Holder', r.account.holder_name), row('Mobile', r.account.mobile),
        row('Address', r.account.service_address), row('Plan', r.account.plan), row('Status', r.account.status))),
  ];

  if (r.status === 'PENDING') {
    const open = state.open && state.open.id === r.id ? state.open.mode : null;
    const reason = h('textarea', { maxlength: '200', placeholder: 'Reason (optional). The customer sees it in the email and in the app.' });
    // Both decisions end in the password pop-up (defined in ops.js); an "already decided" answer refreshes the queue.
    const decide = (path, payload, okMsg) => async (password) => {
      try {
        await api(`/link-requests/${r.id}/${path}`, { method: 'POST', body: { ...payload, password } });
      } catch (err) {
        if (/already/.test(err.message)) { state.open = null; loadRequests(true); }
        throw err;
      }
      state.open = null;
      toast(okMsg);
      await loadRequests();
    };
    const askApprove = () => passwordModal({
      title: 'Confirm: approve link request', confirmLabel: 'Approve',
      detail: `Link ${r.account.account_no} (${r.account.holder_name}) to ${r.requester.email}. They will be able to see its bills and pay them.`,
      run: decide('approve', {}, 'Approved. The customer was notified.'),
    });
    const askDecline = () => passwordModal({
      title: 'Confirm: decline link request', confirmLabel: 'Decline', danger: true,
      detail: `Decline ${r.requester.email}'s request for ${r.account.account_no}.${reason.value.trim() ? ` Reason: ${reason.value.trim()}` : ''}`,
      run: decide('reject', { reason: reason.value }, 'Declined. The customer was notified.'),
    });
    if (!open) {
      body.push(h('div', { class: 'actions' },
        h('button', { class: 'btn primary', onclick: askApprove }, 'Approve'),
        h('button', { class: 'btn danger', onclick: () => { state.open = { id: r.id, mode: 'decline' }; render(); } }, 'Decline')));
    } else {
      body.push(h('div', { class: 'decline-form' }, reason,
        h('div', { class: 'actions mt-s' },
          h('button', { class: 'btn danger solid', onclick: askDecline }, 'Decline request'),
          h('button', { class: 'btn', onclick: () => { state.open = null; render(); } }, 'Back'))));
    }
  } else {
    const verdict = r.status === 'APPROVED' ? 'Approved' : 'Declined';
    body.push(h('div', { class: 'decided' },
      `${verdict} by ${r.decided_by || 'staff'} on ${fmtTime(r.decided_at)}`,
      r.reason ? ` · Reason: ${r.reason}` : ''));
  }
  return h('article', { class: 'card' }, body);
}

function viewRequests() {
  const c = state.requests.counts;
  const seg = h('div', { class: 'seg', role: 'tablist' },
    ...[['PENDING', `Pending (${c.PENDING})`], ['APPROVED', `Approved (${c.APPROVED})`], ['REJECTED', `Declined (${c.REJECTED})`]]
      .map(([key, label]) => h('button', {
        class: state.filter === key ? 'active' : '',
        role: 'tab',
        onclick: () => { state.filter = key; state.open = null; loadRequests(); },
      }, label)));
  const items = state.requests.items;
  const emptyText = { PENDING: 'No requests waiting. You are all caught up.', APPROVED: 'No approved requests yet.', REJECTED: 'No declined requests.' }[state.filter];
  return h('div', {},
    h('div', { class: 'page-title' }, h('h2', {}, 'Link requests'), seg),
    state.error ? h('div', { class: 'error' }, state.error) : null,
    items.length ? items.map(requestCard) : h('div', { class: 'empty' }, emptyText));
}

// ---------- staff management (admins) ----------
async function loadStaff() {
  try { state.staffList = await api('/staff'); } catch (err) { if (err.message !== 'signed out') toast(err.message); }
  if (state.view === 'staff') render();
}

function viewStaff() {
  const name = h('input', { required: true, autocomplete: 'off' });
  const email = h('input', { type: 'email', required: true, autocomplete: 'off' });
  const role = h('select', {}, h('option', { value: 'support' }, 'Support'), h('option', { value: 'admin' }, 'Admin'));
  const pw = h('input', { type: 'password', required: true, minlength: '10', autocomplete: 'new-password' });
  const add = h('form', {
    class: 'panel',
    onsubmit: async (e) => {
      e.preventDefault();
      try {
        await api('/staff', { method: 'POST', body: { name: name.value, email: email.value, role: role.value, password: pw.value } });
        toast('Staff member added.');
        await loadStaff();
      } catch (err) { if (err.message !== 'signed out') toast(err.message); }
    },
  },
  h('h3', {}, 'Add a staff member'),
  h('p', { class: 'muted flush' }, 'Give them a temporary password (10+ characters, with a capital letter and a number) and ask them to change it.'),
  h('div', { class: 'form-grid' },
    h('div', {}, h('label', {}, 'Name'), name),
    h('div', {}, h('label', {}, 'Email'), email),
    h('div', {}, h('label', {}, 'Role'), role),
    h('div', {}, h('label', {}, 'Temporary password'), pw)),
  h('button', { class: 'btn primary mt-m', type: 'submit' }, 'Add staff member'));

  const update = async (id, payload, okMsg) => {
    try { await api(`/staff/${id}/update`, { method: 'POST', body: payload }); toast(okMsg); await loadStaff(); }
    catch (err) { if (err.message !== 'signed out') toast(err.message); }
  };
  const rows = state.staffList.map((s) => {
    const me = s.id === state.staff.id;
    const newPw = h('input', { type: 'password', placeholder: 'New password', autocomplete: 'new-password' });
    return h('tr', {},
      h('td', {}, h('strong', {}, s.name), me ? ' (you)' : '', h('div', { class: 'muted' }, s.email)),
      h('td', {}, s.role === 'admin' ? 'Admin' : 'Support'),
      h('td', {}, s.active ? chip('good', 'Active') : chip('bad', 'Deactivated')),
      h('td', {}, h('div', { class: 'inline' },
        me ? null : h('button', { class: 'btn small', onclick: () => update(s.id, { role: s.role === 'admin' ? 'support' : 'admin' }, 'Role changed.') },
          s.role === 'admin' ? 'Make support' : 'Make admin'),
        me ? null : h('button', { class: `btn small${s.active ? ' danger' : ''}`, onclick: () => update(s.id, { active: !s.active }, s.active ? 'Deactivated.' : 'Reactivated.') },
          s.active ? 'Deactivate' : 'Reactivate'),
        newPw,
        h('button', { class: 'btn small', onclick: () => newPw.value ? update(s.id, { new_password: newPw.value }, 'Password set. They were signed out.') : toast('Type a new password first.') }, 'Set password'))));
  });
  return h('div', {},
    h('div', { class: 'page-title' }, h('h2', {}, 'Staff')),
    add,
    h('div', { class: 'table-wrap' }, h('table', {},
      h('thead', {}, h('tr', {}, h('th', {}, 'Person'), h('th', {}, 'Role'), h('th', {}, 'Status'), h('th', {}, 'Actions'))),
      h('tbody', {}, rows))));
}

// ---------- my account ----------
function viewAccount() {
  const current = h('input', { type: 'password', required: true, autocomplete: 'current-password' });
  const next = h('input', { type: 'password', required: true, minlength: '10', autocomplete: 'new-password' });
  const again = h('input', { type: 'password', required: true, autocomplete: 'new-password' });
  const form = h('form', {
    class: 'panel',
    onsubmit: async (e) => {
      e.preventDefault();
      if (next.value !== again.value) return toast("The new passwords don't match.");
      try {
        const d = await api('/me/password', { method: 'POST', body: { current_password: current.value, new_password: next.value, remember: state.remember } });
        saveSession(d.token, state.staff, state.remember);
        current.value = next.value = again.value = '';
        toast('Password changed.');
      } catch (err) { if (err.message !== 'signed out') toast(err.message); }
    },
  },
  h('h3', {}, 'Change your password'),
  h('label', {}, 'Current password'), current,
  h('label', {}, 'New password'), next,
  h('p', { class: 'muted hint' }, '10+ characters, with a capital letter and a number.'),
  h('label', {}, 'Confirm new password'), again,
  h('button', { class: 'btn primary mt-m', type: 'submit' }, 'Change password'));
  return h('div', {},
    h('div', { class: 'page-title' }, h('h2', {}, 'My account')),
    h('div', { class: 'panel' }, h('div', { class: 'row' }, h('span', {}, 'Name'), h('span', {}, state.staff.name)),
      h('div', { class: 'row' }, h('span', {}, 'Email'), h('span', {}, state.staff.email)),
      h('div', { class: 'row' }, h('span', {}, 'Role'), h('span', {}, state.staff.role))),
    form);
}

// ---------- render loop ----------
function render() {
  if (!state.token) return renderLogin();
  const adminOnly = state.view === 'staff' || state.view === 'activity';
  const view = adminOnly && state.staff.role !== 'admin' ? 'overview' : state.view;
  const views = { overview: viewOverview, requests: viewRequests, customers: viewCustomers, issues: viewIssues, activity: viewActivity, staff: viewStaff, account: viewAccount };
  renderShell((views[view] || viewOverview)());
}

async function start() {
  state.token = readStored('sessionStorage', TOKEN_KEY);
  state.remember = false;
  if (!state.token) { state.token = readStored('localStorage', TOKEN_KEY); state.remember = !!state.token; }
  if (state.token) {
    try { state.staff = await api('/me'); } catch { state.token = null; }
  }
  render();
  if (state.token) { loadOverview(true); loadRequests(true); loadSummary(); liveLoop(); }
}

// New requests and reports show up on their own while their queue is on screen.
setInterval(() => {
  if (!state.token || document.hidden) return;
  loadSummary();
  if (state.view === 'overview') loadOverview(true);
  if (state.view === 'requests') loadRequests(true);
  if (state.view === 'issues' && !state.issueOpen) loadIssues(true);
}, 30000);

// Customer page: quietly pick up changes (payments, status...) without wiping a form or password pop-up.
async function refreshAccountQuietly() {
  if (state.view !== 'customers' || !state.accountId || !state.account) return;
  if (state.action || document.querySelector('.modal-backdrop')) return;
  const id = state.accountId;
  try {
    const a = await api(`/accounts/${id}`);
    if (state.accountId !== id || state.action || document.querySelector('.modal-backdrop')) return;
    if (JSON.stringify(a) !== JSON.stringify(state.account)) { state.account = a; render(); }
  } catch (e) { /* the next change tries again */ }
}

// Live updates: the server answers /staff/sync the moment anything in the database changes (or after ~20s with
// "nothing new"), and we reload whatever page is open. If the connection drops we wait a few seconds and retry.
function refreshCurrentView() {
  loadSummary();
  if (state.view === 'overview') loadOverview(true);
  if (state.view === 'requests') loadRequests(true);
  if (state.view === 'issues' && !state.issueOpen) loadIssues(true);
  if (state.view === 'customers') { if (state.accountId) refreshAccountQuietly(); else if (state.results.length <= 50) runSearch(); }
  if (state.view === 'activity' && window.scrollY < 300) loadActivity(true);
}

let liveRunning = false;
async function liveLoop() {
  if (liveRunning) return;
  liveRunning = true;
  let since = -1;
  while (state.token) {
    try {
      const d = await api(`/sync?since=${since}`);
      if (since >= 0 && d.v !== since && !document.hidden) refreshCurrentView();
      since = d.v;
    } catch (e) {
      since = -1;
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
  liveRunning = false;
}
document.addEventListener('visibilitychange', () => { if (!document.hidden && state.token) refreshCurrentView(); });

start();