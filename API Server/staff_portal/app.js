'use strict';
// NetPulse staff dashboard. Everything on screen is built with createElement/textContent (never innerHTML),
// so nothing a customer types (a name, an email) can ever run as code in a staff member's browser.

const API = '/api/v1/staff';
const TOKEN_KEY = 'np_staff_token'; // sessionStorage: gone when the tab closes
const app = document.getElementById('app');

const state = {
  token: null,
  staff: null,
  view: 'requests', // requests | staff | account
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
  if (state.token) headers.Authorization = `Bearer ${state.token}`;
  let res;
  try {
    res = await fetch(API + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  } catch {
    throw new Error("Can't reach the server. Check your connection.");
  }
  let data = null;
  try { data = await res.json(); } catch { /* no body */ }
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
function saveSession(token, staff) {
  state.token = token;
  state.staff = staff;
  try { sessionStorage.setItem(TOKEN_KEY, token); } catch { /* private mode: fine, just not remembered */ }
}

function signOut(message) {
  state.token = null;
  state.staff = null;
  state.open = null;
  try { sessionStorage.removeItem(TOKEN_KEY); } catch { /* ignore */ }
  state.error = message || null;
  render();
}

// ---------- sign in ----------
function renderLogin() {
  const email = h('input', { type: 'email', autocomplete: 'username', required: true, autofocus: true });
  const password = h('input', { type: 'password', autocomplete: 'current-password', required: true });
  const error = h('div', { class: 'error', role: 'alert' }, state.error);
  if (!state.error) error.classList.add('hidden');
  const submit = h('button', { class: 'btn primary block', type: 'submit' }, 'Sign in');
  const form = h('form', {
    onsubmit: async (e) => {
      e.preventDefault();
      submit.disabled = true;
      error.classList.add('hidden');
      try {
        const d = await api('/login', { method: 'POST', body: { email: email.value, password: password.value } });
        state.error = null;
        saveSession(d.token, d.staff);
        state.view = 'requests';
        render();
        loadRequests(true);
      } catch (err) {
        error.textContent = err.message;
        error.classList.remove('hidden');
        submit.disabled = false;
        password.value = '';
        password.focus();
      }
    },
  },
  h('label', {}, 'Email'), email,
  h('label', {}, 'Password'), password,
  error, submit);
  app.replaceChildren(h('div', { class: 'login-wrap' },
    h('div', { class: 'login-card' },
      h('div', { class: 'brand' }, h('span', { class: 'brand-mark' }), 'NetPulse'),
      h('h1', {}, 'Staff sign in'),
      h('p', {}, 'For the service provider team.'),
      form)));
  state.error = null;
}

// ---------- shell ----------
function renderShell(content) {
  const pending = state.requests.counts.PENDING;
  const tab = (view, label, extra) => h('button', {
    class: state.view === view ? 'active' : '',
    onclick: () => { state.view = view; state.open = null; render(); },
  }, label, extra);
  const nav = h('nav', { class: 'nav' },
    tab('requests', 'Link requests', pending ? h('span', { class: 'badge' }, pending) : null),
    state.staff.role === 'admin' ? tab('staff', 'Staff') : null,
    tab('account', 'My account'));
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
  if (state.view === 'requests' && !state.open) render();
  else if (state.view === 'requests') renderBadgeOnly();
}

// A refresh while someone is half-way through confirming a decision must not wipe their form: only the badge updates.
function renderBadgeOnly() {
  const badge = document.querySelector('.nav .badge');
  const n = state.requests.counts.PENDING;
  if (badge) badge.textContent = n;
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
    const act = async (path, payload, okMsg, btn) => {
      btn.disabled = true;
      try {
        await api(`/link-requests/${r.id}/${path}`, { method: 'POST', body: payload });
        state.open = null;
        toast(okMsg);
        await loadRequests();
      } catch (err) {
        btn.disabled = false;
        if (err.message !== 'signed out') toast(err.message);
        if (/already/.test(err.message)) { state.open = null; await loadRequests(); }
      }
    };
    if (!open) {
      body.push(h('div', { class: 'actions' },
        h('button', { class: 'btn primary', onclick: () => { state.open = { id: r.id, mode: 'approve' }; render(); } }, 'Approve'),
        h('button', { class: 'btn danger', onclick: () => { state.open = { id: r.id, mode: 'decline' }; render(); } }, 'Decline')));
    } else if (open === 'approve') {
      const go = h('button', { class: 'btn primary', onclick: () => act('approve', null, 'Approved. The customer was notified.', go) },
        'Yes, link this account');
      body.push(h('p', {}, `Link ${r.account.account_no} (${r.account.holder_name}) to ${r.requester.email}? They will be able to see the bills and make payments for it.`),
        h('div', { class: 'actions' }, go,
          h('button', { class: 'btn', onclick: () => { state.open = null; render(); } }, 'Back')));
    } else {
      const go = h('button', { class: 'btn danger solid', onclick: () => act('reject', { reason: reason.value }, 'Declined. The customer was notified.', go) },
        'Decline request');
      body.push(h('div', { class: 'decline-form' }, reason,
        h('div', { class: 'actions mt-s' }, go,
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
        const d = await api('/me/password', { method: 'POST', body: { current_password: current.value, new_password: next.value } });
        saveSession(d.token, state.staff);
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
  const view = state.view === 'staff' && state.staff.role !== 'admin' ? 'requests' : state.view;
  renderShell(view === 'requests' ? viewRequests() : view === 'staff' ? viewStaff() : viewAccount());
}

async function start() {
  try { state.token = sessionStorage.getItem(TOKEN_KEY); } catch { state.token = null; }
  if (state.token) {
    try { state.staff = await api('/me'); } catch { state.token = null; }
  }
  render();
  if (state.token) { loadRequests(true); }
}

// New requests show up on their own while the queue is on screen.
setInterval(() => {
  if (state.token && !document.hidden) {
    if (state.view === 'requests') loadRequests(true);
  }
}, 30000);

// Opening a tab also fetches what that tab needs.
document.addEventListener('click', (e) => {
  const btn = e.target.closest && e.target.closest('.nav button');
  if (!btn) return;
  queueMicrotask(() => {
    if (state.view === 'staff') loadStaff();
    if (state.view === 'requests') loadRequests(true);
  });
});

start();
