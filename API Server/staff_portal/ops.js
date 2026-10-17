'use strict';
// Customers, issue inbox and billing screens. Loaded before app.js; it uses the helpers and state defined there.
// Same rule as app.js: everything on screen is built with h() and textContent, never innerHTML.

// ---------- money helpers (the server speaks whole centavos) ----------
function money(centavos) {
  const n = Math.abs(centavos) / 100;
  return (centavos < 0 ? '-' : '') + '₱' + n.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function parsePesos(text) {
  const t = String(text || '').trim().replace(/,/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  const centavos = Math.round(parseFloat(t) * 100);
  return centavos > 0 ? centavos : null;
}

function balanceChip(balance) {
  if (balance > 0) return chip('warn', `Owes ${money(balance)}`);
  if (balance < 0) return chip('good', `Credit ${money(-balance)}`);
  return chip('good', 'Paid up');
}

const statusChip = (s) => chip(s === 'ACTIVE' ? 'good' : 'bad', s === 'ACTIVE' ? 'Active' : 'Suspended');
const fmtDate = (iso) => (iso ? new Date(iso + (iso.length === 10 ? 'T00:00:00' : '')).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }) : '-');
const field = (label, el, hint) => h('div', {}, hint ? h('div', { class: 'label-row' }, h('label', {}, label), hint) : h('label', {}, label), el);
const isAdmin = () => state.staff && state.staff.role === 'admin';

const ACTION_LABELS = {
  EXPORT_ACTIVITY: 'Exported the activity log', RECORD_PAYMENT: 'Recorded a payment', ADJUST_CREDIT: 'Applied a credit', ADJUST_CHARGE: 'Applied a charge',
  ISSUE_BILL: 'Issued a bill', CHANGE_PLAN: 'Changed the plan', SUSPEND: 'Suspended service',
  REACTIVATE: 'Restored service', EDIT_CONTACT: 'Edited account details', UNLINK_LOGIN: 'Unlinked a login',
  RESOLVE_ISSUE: 'Resolved a report', REOPEN_ISSUE: 'Reopened a report',
  APPROVE_LINK: 'Approved a link request', REJECT_LINK: 'Declined a link request',
  CREATE_STAFF: 'Added a staff member', UPDATE_STAFF: 'Changed a staff member',
  CHANGE_PASSWORD: 'Changed their password', RESET_PASSWORD: 'Reset their password', LOGIN: 'Signed in',
};

// ---------- customers: search ----------
let searchSeq = 0;

async function runSearch(more) {
  const mine = ++searchSeq;
  try {
    const params = new URLSearchParams({ q: state.q.trim() });
    if (state.searchKind === 'accounts') {
      for (const [k, v] of Object.entries(state.acctFilter)) if (v) params.set(k, v);
      params.set('sort', state.acctSort.key);
      params.set('dir', state.acctSort.dir);
      if (more) params.set('offset', String(state.results.length));
    }
    const rows = await api(`/${state.searchKind}?${params}`);
    if (mine !== searchSeq) return; // a newer search is already on its way
    state.results = more ? state.results.concat(rows) : rows;
    state.moreResults = state.searchKind === 'accounts' && rows.length === 50;
    state.searched = true;
    state.error = null;
  } catch (err) {
    if (err.message === 'signed out') return;
    toast(err.message);
  }
  paintResults();
}

function paintResults() {
  const box = document.getElementById('results');
  if (!box) return;
  const rows = state.results;
  if (!rows.length) {
    box.replaceChildren(h('div', { class: 'empty' }, state.searched ? 'Nothing matches that search.' : 'Loading...'));
    return;
  }
  let table;
  if (state.searchKind === 'accounts') {
    // Column headers with a sort key are clickable: first click sorts ascending, a second click flips it.
    const sortable = [['Account', 'account'], ['Holder', 'holder'], ['Mobile', null], ['Plan', 'plan'], ['Balance', 'balance'],
      ['Due', 'due'], ['Status', 'status'], ['Logins', null]];
    const head = sortable.map(([label, key]) => {
      if (!key) return h('th', {}, label);
      const on = state.acctSort.key === key;
      return h('th', { 'aria-sort': on ? (state.acctSort.dir === 'asc' ? 'ascending' : 'descending') : 'none' },
        h('button', { class: `sort-btn${on ? ' on' : ''}`, type: 'button', onclick: () => {
          state.acctSort = on ? { key, dir: state.acctSort.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: key === 'balance' ? 'desc' : 'asc' };
          runSearch();
        } }, label, on ? (state.acctSort.dir === 'asc' ? ' \u25B2' : ' \u25BC') : ''));
    });
    table = h('table', {},
      h('thead', {}, h('tr', {}, head)),
      h('tbody', {}, rows.map((a) => h('tr', { class: 'click', onclick: () => openAccount(a.id) },
        h('td', {}, h('button', { class: 'link-btn', onclick: (e) => { e.stopPropagation(); openAccount(a.id); } }, a.account_no)),
        h('td', {}, a.holder_name), h('td', {}, a.mobile), h('td', {}, a.plan || '-'),
        h('td', {}, balanceChip(a.balance)), h('td', {}, fmtDate(a.due_date)), h('td', {}, statusChip(a.status)), h('td', {}, a.linked_logins)))));
  } else {
    table = h('table', {},
      h('thead', {}, h('tr', {}, ['Email', 'Name', 'Mobile', 'Linked accounts'].map((t) => h('th', {}, t)))),
      h('tbody', {}, rows.map((u) => h('tr', {},
        h('td', {}, u.email, u.has_google ? h('div', { class: 'muted' }, 'Google sign-in') : null),
        h('td', {}, u.name || '-'), h('td', {}, u.mobile || '-'),
        h('td', {}, u.accounts.length
          ? h('div', { class: 'inline' }, u.accounts.map((a) => h('button', { class: 'btn small', onclick: () => openAccount(a.id) }, a.account_no)))
          : h('span', { class: 'muted' }, 'None yet'))))));
  }
  box.replaceChildren(h('div', { class: 'table-wrap' }, table),
    h('p', { class: 'muted hint' }, `${rows.length} shown`),
    state.moreResults ? h('button', { class: 'btn', type: 'button', onclick: () => runSearch(true) }, 'Load more') : null);
}

function viewCustomers() {
  if (state.accountId) return viewAccountDetail();
  const input = h('input', {
    type: 'search', value: state.q, autocomplete: 'off', 'aria-label': 'Search',
    placeholder: state.searchKind === 'accounts' ? 'Search by account number, name, mobile or address' : 'Search by email, name or mobile',
  });
  let timer;
  input.addEventListener('input', () => { state.q = input.value; clearTimeout(timer); timer = setTimeout(runSearch, 250); });
  const seg = h('div', { class: 'seg' },
    ...[['accounts', 'Accounts'], ['users', 'App logins']].map(([key, label]) => h('button', {
      class: state.searchKind === key ? 'active' : '',
      onclick: () => { state.searchKind = key; state.results = []; state.searched = false; render(); runSearch(); },
    }, label)));
  queueMicrotask(() => { paintResults(); if (!state.searched) runSearch(); });
  let filters = null;
  if (state.searchKind === 'accounts') {
    const f = state.acctFilter;
    const pick = (label, key, options) => {
      const sel = h('select', { 'aria-label': label, onchange: () => { f[key] = sel.value; runSearch(); } },
        h('option', { value: '' }, label), options.map(([v, t]) => h('option', { value: v, selected: String(f[key]) === String(v) }, t)));
      return sel;
    };
    if (!state.plans.length) api('/plans').then((p) => { state.plans = p; if (state.view === 'customers' && !state.accountId) render(); }).catch(() => {});
    filters = h('div', { class: 'filters' },
      pick('Any status', 'status', [['ACTIVE', 'Active'], ['SUSPENDED', 'Suspended']]),
      pick('Any balance', 'balance', [['owes', 'Owes money'], ['credit', 'Has credit'], ['settled', 'Settled']]),
      pick('Any plan', 'plan_id', state.plans.map((p) => [p.id, p.name])),
      h('button', { class: 'btn', type: 'button', onclick: () => {
        state.acctFilter = { status: '', balance: '', plan_id: '' }; state.acctSort = { key: 'account', dir: 'asc' }; state.q = ''; render(); runSearch();
      } }, 'Reset'));
  }
  return h('div', {},
    h('div', { class: 'page-title' }, h('h2', {}, 'Customers'), seg),
    h('div', { class: 'search' }, input),
    filters,
    h('div', { id: 'results' }));
}

// ---------- customers: one account ----------
async function loadAccount() {
  const id = state.accountId;
  try {
    const a = await api(`/accounts/${id}`);
    if (state.accountId !== id) return;
    state.account = a;
  } catch (err) {
    if (err.message === 'signed out') return;
    toast(err.message);
    if (state.accountId === id) { state.accountId = null; }
  }
  if (state.view === 'customers') render();
}

function openAccount(id) {
  state.view = 'customers';
  state.accountId = id;
  state.account = null;
  state.action = null;
  render();
  loadAccount();
  if (!state.plans.length) api('/plans').then((p) => { state.plans = p; }).catch(() => {});
}

function backToSearch() {
  state.accountId = null; state.account = null; state.action = null;
  render();
}

// Runs one change on the open account, then shows the account as the server now has it.
// Errors are thrown (not toasted) so the password pop-up can show them and stay open.
async function accountCall(path, payload, okMessage) {
  state.account = await api(`/accounts/${state.accountId}/${path}`, { method: 'POST', body: payload });
  state.action = null;
  toast(okMessage);
  render();
  loadSummary();
}

// The password pop-up. The password is typed twice (so a typo can't lock the check), the change only runs once both
// match, and a wrong password shows inside the pop-up, which stays open. Clicking outside it does nothing on purpose.
function passwordModal({ title, detail, confirmLabel = 'Confirm', danger = false, run }) {
  return new Promise((resolve) => {
    const first = h('input', { type: 'password', autocomplete: 'current-password', required: true, placeholder: 'Your staff password' });
    const second = h('input', { type: 'password', autocomplete: 'off', required: true, placeholder: 'Type it again' });
    const err = h('div', { class: 'error hidden', role: 'alert' });
    const ok = h('button', { class: `btn ${danger ? 'danger solid' : 'primary'}`, type: 'submit' }, confirmLabel);
    const opener = document.activeElement;
    let busy = false;
    const showError = (msg) => { err.textContent = msg; err.classList.toggle('hidden', !msg); };
    const onKey = (e) => { if (e.key === 'Escape' && !busy) close(); };
    function close() {
      document.removeEventListener('keydown', onKey);
      backdrop.remove();
      try { if (opener && document.contains(opener)) opener.focus(); } catch { /* ignore */ }
      resolve();
    }
    const form = h('form', {
      onsubmit: async (e) => {
        e.preventDefault();
        if (busy) return;
        showError('');
        if (first.value !== second.value) {
          showError("The two passwords don't match. Try again.");
          second.value = '';
          second.focus();
          return;
        }
        busy = true; ok.disabled = true;
        try {
          await run(first.value);
          close();
        } catch (e2) {
          if (e2.message === 'signed out') return close();
          showError(e2.message);
          first.value = ''; second.value = '';
          first.focus();
        } finally {
          busy = false; ok.disabled = false;
        }
      },
    },
    h('label', {}, 'Your password'), first,
    h('label', {}, 'Type your password again'), second,
    err,
    h('div', { class: 'actions mt-m modal-actions' }, ok, h('button', { class: 'btn', type: 'button', onclick: () => { if (!busy) close(); } }, 'Cancel')));
    const backdrop = h('div', { class: 'modal-backdrop' },
      h('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
        h('h3', {}, title),
        detail ? h('p', { class: 'modal-detail' }, detail) : null,
        h('p', { class: 'muted hint' }, 'Enter your password twice to make sure this wasn\'t a misclick.'),
        form));
    document.addEventListener('keydown', onKey);
    document.body.append(backdrop);
    first.focus();
  });
}

function actionForm(title, intro, fields, submitLabel, onSubmit, danger) {
  const submit = h('button', { class: `btn ${danger ? 'danger solid' : 'primary'}`, type: 'submit' }, submitLabel);
  // Each panel validates its own fields, then calls ask(summary, run) to open the password pop-up.
  const ask = (detail, run) => passwordModal({ title: `Confirm: ${title.toLowerCase()}`, detail, confirmLabel: 'Confirm', danger, run });
  const form = h('form', {
    class: 'panel action-panel',
    onsubmit: async (e) => {
      e.preventDefault();
      submit.disabled = true;
      await onSubmit(ask);
      submit.disabled = false;
    },
  },
  h('h3', {}, title),
  intro ? h('p', { class: 'muted flush' }, intro) : null,
  h('div', { class: 'form-grid' }, ...fields),
  h('div', { class: 'actions mt-m' }, submit,
    h('button', { class: 'btn', type: 'button', onclick: () => { state.action = null; render(); } }, 'Cancel')));
  form.submitBtn = submit;
  return form;
}

function previewLine() { return h('span', { class: 'preview' }, ''); }

function actionPanel(a) {
  const kind = state.action;
  if (kind === 'payment') {
    const amount = h('input', { inputmode: 'decimal', required: true, placeholder: '0.00', autocomplete: 'off' });
    const method = h('select', {}, ['CASH', 'GCASH', 'BANK', 'OTHER'].map((m) => h('option', { value: m }, { CASH: 'Cash', GCASH: 'GCash', BANK: 'Bank transfer', OTHER: 'Other' }[m])));
    const note = h('input', { maxlength: '200', placeholder: 'e.g. receipt number', autocomplete: 'off' });
    const prev = previewLine();
    let form;
    amount.addEventListener('input', () => {
      const c = parsePesos(amount.value);
      prev.textContent = c ? `New balance ${money(a.balance - c)}${a.balance - c < 0 ? ' (credit)' : ''}` : '';
      form.submitBtn.textContent = c ? `Record ${money(c)} payment` : 'Record payment';
    });
    form = actionForm('Record a payment', 'For money received outside the app. The customer gets a "Payment received" notification.',
      [field('Amount (PHP)', amount, prev), field('Paid by', method), h('div', { class: 'span2' }, field('Note (optional)', note))],
      'Record payment', (ask) => {
        const c = parsePesos(amount.value);
        if (!c) return toast('Enter a valid amount, like 999.00');
        return ask(`Record a ${money(c)} payment (${method.options[method.selectedIndex].text}) on ${a.account_no}. New balance: ${money(a.balance - c)}.`,
          (password) => accountCall('payments', { amount: c, method: method.value, note: note.value, password }, 'Payment recorded.'));
      });
    return form;
  }
  if (kind === 'adjust') {
    const type = h('select', {}, h('option', { value: 'CREDIT' }, 'Credit (they owe less)'), h('option', { value: 'CHARGE' }, 'Charge (they owe more)'));
    const amount = h('input', { inputmode: 'decimal', required: true, placeholder: '0.00', autocomplete: 'off' });
    const reason = h('input', { required: true, maxlength: '200', placeholder: 'Shown to the customer', autocomplete: 'off' });
    const prev = previewLine();
    let form;
    const update = () => {
      const c = parsePesos(amount.value);
      prev.textContent = c ? `New balance ${money(a.balance + (type.value === 'CHARGE' ? c : -c))}` : '';
      const word = type.value === 'CHARGE' ? 'charge' : 'credit';
      form.submitBtn.textContent = c ? `Apply ${money(c)} ${word}` : 'Apply adjustment';
    };
    amount.addEventListener('input', update); type.addEventListener('change', update);
    form = actionForm('Adjust the balance', 'Use for outage credits, fees and corrections. The reason is shown to the customer.',
      [field('Type', type), field('Amount (PHP)', amount, prev), h('div', { class: 'span2' }, field('Reason', reason))],
      'Apply adjustment', (ask) => {
        const c = parsePesos(amount.value);
        if (!c) return toast('Enter a valid amount, like 250.00');
        const charge = type.value === 'CHARGE';
        return ask(`Apply a ${money(c)} ${charge ? 'charge' : 'credit'} to ${a.account_no}. New balance: ${money(a.balance + (charge ? c : -c))}.`,
          (password) => accountCall('adjustments', { kind: type.value, amount: c, reason: reason.value, password }, 'Adjustment applied.'));
      });
    return form;
  }
  if (kind === 'bill') {
    const due = new Date(Date.now() + 14 * 86400000);
    const iso = `${due.getFullYear()}-${String(due.getMonth() + 1).padStart(2, '0')}-${String(due.getDate()).padStart(2, '0')}`;
    const charges = h('input', { inputmode: 'decimal', required: true, value: (a.suggested_charges / 100).toFixed(2), autocomplete: 'off' });
    const dueIn = h('input', { type: 'date', required: true, value: iso });
    const prev = previewLine();
    let form;
    const update = () => {
      const c = parsePesos(charges.value);
      prev.textContent = c ? `New balance ${money(a.balance + c)}` : '';
      form.submitBtn.textContent = c ? `Issue ${money(c)} bill` : 'Issue bill';
    };
    charges.addEventListener('input', update);
    form = actionForm('Issue a bill', `Pre-filled with the plan fee${a.addons.length ? ' plus add-ons' : ''}. The customer is notified.`,
      [field('Charges (PHP)', charges, prev), field('Due date', dueIn)],
      'Issue bill', (ask) => {
        const c = parsePesos(charges.value);
        if (!c) return toast('Enter valid charges, like 999.00');
        return ask(`Issue a ${money(c)} bill to ${a.account_no}, due ${fmtDate(dueIn.value)}. New balance: ${money(a.balance + c)}.`,
          (password) => accountCall('bills', { charges: c, due_date: dueIn.value, password }, 'Bill issued.'));
      });
    update();
    return form;
  }
  if (kind === 'plan') {
    const sel = h('select', {}, state.plans.map((p) => h('option', { value: p.id, selected: p.id === a.plan_id }, `${p.name}: ${p.speed_mbps} Mbps, ${money(p.monthly_fee)}/mo`)));
    return actionForm('Change plan', 'Takes effect right away. It does not change the current balance.',
      [h('div', { class: 'span2' }, field('New plan', sel))],
      'Change plan', (ask) => ask(`Change ${a.account_no} from ${a.plan} to ${sel.options[sel.selectedIndex].text.split(':')[0]}.`,
        (password) => accountCall('plan', { plan_id: Number(sel.value), password }, 'Plan changed.')));
  }
  if (kind === 'status') {
    const suspending = a.status === 'ACTIVE';
    const reason = h('input', { maxlength: '200', placeholder: suspending ? 'e.g. unpaid for 60 days' : 'optional', autocomplete: 'off' });
    const auto = h('input', { type: 'checkbox', checked: a.balance > 0 });
    return actionForm(suspending ? 'Suspend service' : 'Restore service',
      suspending ? 'The customer is told their service was suspended.' : 'The customer is told their service is active again.',
      [h('div', { class: 'span2' }, field('Reason (optional)', reason)),
        suspending ? h('div', { class: 'span2' }, h('label', { class: 'check' }, auto, 'Restore automatically once the balance is paid in full')) : null],
      suspending ? 'Suspend service' : 'Restore service',
      (ask) => ask(`${suspending ? 'Suspend' : 'Restore'} service for ${a.account_no} (${a.holder_name}). The customer is notified.`,
        (password) => accountCall('status', { status: suspending ? 'SUSPENDED' : 'ACTIVE', reason: reason.value, auto_restore: suspending && auto.checked, password },
          suspending ? 'Service suspended.' : 'Service restored.')), suspending);
  }
  if (kind === 'contact') {
    const name = h('input', { required: true, value: a.holder_name, autocomplete: 'off' });
    const mobile = h('input', { required: true, value: a.mobile, autocomplete: 'off' });
    const addr = h('input', { required: true, value: a.service_address, autocomplete: 'off' });
    return actionForm('Edit account details', 'The mobile number receives this account\'s verification codes, so double-check it.',
      [field('Holder name', name), field('Mobile', mobile), h('div', { class: 'span2' }, field('Service address', addr))],
      'Save details', (ask) => ask(`Save new details for ${a.account_no}. The mobile number receives verification codes, so make sure it is right.`,
        (password) => accountCall('contact', { holder_name: name.value, mobile: mobile.value, service_address: addr.value, password }, 'Details saved.')));
  }
  return null;
}

function simpleTable(headers, rows, emptyText) {
  if (!rows.length) return h('p', { class: 'muted flush' }, emptyText);
  return h('div', { class: 'table-wrap flat' }, h('table', { class: 'compact' },
    h('thead', {}, h('tr', {}, headers.map((t) => h('th', {}, t)))),
    h('tbody', {}, rows.map((r) => h('tr', {}, r.map((c) => h('td', {}, c)))))));
}

function viewAccountDetail() {
  const back = h('button', { class: 'btn small', onclick: backToSearch }, '← Back to search');
  const a = state.account;
  if (!a) return h('div', {}, back, h('div', { class: 'empty mt-m' }, 'Loading...'));

  const buttons = isAdmin()
    ? h('div', { class: 'actions' },
      ...[['payment', 'Record payment'], ['adjust', 'Adjust balance'], ['bill', 'Issue bill'], ['plan', 'Change plan'],
        ['status', a.status === 'ACTIVE' ? 'Suspend' : 'Restore service'], ['contact', 'Edit details']]
        .map(([k, label]) => h('button', {
          class: `btn small${state.action === k ? ' primary' : ''}`,
          onclick: () => { state.action = state.action === k ? null : k; render(); },
        }, label)))
    : h('p', { class: 'muted flush' }, 'Changing money, plans and details is for admins. You can unlink logins and handle reports.');

  const logins = a.logins.length
    ? h('div', {}, a.logins.map((u) => {
      const open = state.action === `unlink:${u.id}`;
      const reason = h('input', { maxlength: '200', placeholder: 'Reason (optional, the customer is emailed)', autocomplete: 'off' });
      const go = h('button', { class: 'btn danger solid small', onclick: () => passwordModal({
        title: 'Confirm: unlink this login', danger: true, confirmLabel: 'Unlink',
        detail: `${u.email} will lose access to ${a.account_no} in the app, and is emailed about it.`,
        run: async (password) => {
          state.account = await api(`/accounts/${a.id}/unlink`, { method: 'POST', body: { user_id: u.id, reason: reason.value, password } });
          state.action = null; toast('Login unlinked.'); render();
        },
      }) }, 'Unlink');
      return h('div', { class: 'login-row' },
        h('div', {}, h('strong', {}, u.email), u.name ? h('span', { class: 'muted' }, ` · ${u.name}`) : null),
        open
          ? h('div', { class: 'inline' }, reason, go, h('button', { class: 'btn small', onclick: () => { state.action = null; render(); } }, 'Cancel'))
          : h('button', { class: 'btn small danger', onclick: () => { state.action = `unlink:${u.id}`; render(); } }, 'Unlink'));
    }))
    : h('p', { class: 'muted flush' }, 'No app logins are linked to this account.');

  const panel = state.action && !state.action.startsWith('unlink:') ? actionPanel(a) : null;
  return h('div', {},
    h('div', { class: 'page-title' }, h('div', { class: 'inline' }, back, h('h2', {}, a.account_no)),
      h('div', { class: 'chips flush' }, statusChip(a.status), balanceChip(a.balance))),
    h('div', { class: 'cols' },
      h('div', { class: 'box' }, h('h4', {}, 'Account'),
        row('Holder', a.holder_name), row('Mobile', a.mobile), row('Address', a.service_address), row('Due date', fmtDate(a.due_date)),
        a.status === 'SUSPENDED' ? row('Suspended for', (a.status_reason || 'No reason given') + (a.auto_restore ? ' (restores itself when paid in full)' : '')) : null),
      h('div', { class: 'box' }, h('h4', {}, 'Plan'),
        row('Plan', a.plan), row('Monthly fee', money(a.plan_fee)),
        row('Add-ons', a.addons.length ? a.addons.map((x) => `${x.name} (${money(x.monthly_fee)})`).join(', ') : 'None'),
        row('Balance', a.balance > 0 ? `${money(a.balance)} due` : a.balance < 0 ? `${money(-a.balance)} credit` : 'Paid up'))),
    h('section', { class: 'card actions-card' }, h('h3', {}, 'Actions'), buttons, panel),
    h('section', { class: 'card' }, h('h3', {}, 'Linked logins'), logins),
    h('section', { class: 'card' }, h('h3', {}, 'Bills'),
      simpleTable(['Statement', 'Period', 'Previous', 'Charges', 'Total'],
        a.bills.map((b) => [fmtDate(b.statement_date), `${fmtDate(b.period_start)} to ${fmtDate(b.period_end)}`, money(b.previous_balance), money(b.charges), money(b.total)]), 'No bills yet.')),
    h('section', { class: 'card' }, h('h3', {}, 'Payments'),
      simpleTable(['When', 'Amount', 'Method', 'Status', 'Note'],
        a.payments.map((p) => [fmtTime(p.paid_at || p.created_at), money(p.amount), p.method === 'ONLINE' ? 'Online' : p.method,
          p.status === 'PAID' ? chip('good', 'Paid') : chip('warn', 'Pending'), p.note || '']), 'No payments yet.')),
    h('section', { class: 'card' }, h('h3', {}, 'Reports from the customer'),
      simpleTable(['When', 'Type', 'Message', 'Status'],
        a.issues.map((i) => [fmtTime(i.created_at), i.category, i.message, i.status === 'OPEN' ? chip('warn', 'Open') : chip('good', 'Resolved')]), 'No reports.')),
    h('section', { class: 'card' }, h('h3', {}, 'Staff activity'),
      simpleTable(['When', 'Who', 'What'],
        a.activity.map((x) => [fmtTime(x.at), x.by, h('span', {}, h('strong', {}, ACTION_LABELS[x.action] || x.action), x.detail ? ` · ${x.detail}` : '')]), 'Nothing done from the dashboard yet.')));
}

// ---------- issue inbox ----------
async function loadIssues(quiet) {
  try {
    state.issues = await api(`/issues?status=${state.issueFilter}`);
    state.summary.open_issues = state.issues.counts.OPEN;
    state.error = null;
  } catch (err) {
    if (err.message === 'signed out') return;
    state.error = err.message;
    if (!quiet) toast(err.message);
  }
  if (state.view === 'issues' && !state.issueOpen) {
    // Don't rebuild the page under someone who is typing in the search box: just refresh the list.
    if (document.activeElement && document.activeElement.type === 'search') { paintIssueList(); updateBadges(); } else render();
  } else updateBadges();
}

function issueCard(i) {
  const open = state.issueOpen === i.id;
  const body = [
    h('div', { class: 'card-head' },
      h('h3', {}, i.account.account_no, h('span', { class: 'muted' }, ` · ${i.account.holder_name}`)),
      h('span', { class: 'muted', title: fmtTime(i.created_at) }, `Reported ${ago(i.created_at)}`)),
    h('div', { class: 'chips' }, chip('warn', i.category),
      i.logins.length ? chip('good', i.logins.join(', ')) : chip('warn', 'No app login linked')),
    h('p', { class: 'message' }, i.message),
  ];
  if (i.status === 'OPEN') {
    const reply = h('textarea', { maxlength: '500', placeholder: 'Reply to the customer (optional). They see it in the app and by email.' });
    const done = h('button', { class: 'btn primary', onclick: async () => {
      done.disabled = true;
      try {
        await api(`/issues/${i.id}/resolve`, { method: 'POST', body: { reply: reply.value } });
        state.issueOpen = null; toast('Marked resolved. The customer was told.'); await loadIssues();
      } catch (err) { done.disabled = false; if (err.message !== 'signed out') toast(err.message); }
    } }, 'Mark resolved');
    body.push(open
      ? h('div', { class: 'decline-form' }, reply, h('div', { class: 'actions mt-s' }, done,
        h('button', { class: 'btn', onclick: () => { state.issueOpen = null; render(); } }, 'Back')))
      : h('div', { class: 'actions' },
        h('button', { class: 'btn primary', onclick: () => { state.issueOpen = i.id; render(); } }, 'Resolve...'),
        h('button', { class: 'btn', onclick: () => openAccount(i.account.id) }, 'Open account')));
  } else {
    body.push(h('div', { class: 'decided' }, `Resolved by ${i.resolved_by || 'staff'} on ${fmtTime(i.resolved_at)}`, i.reply ? ` · Reply: ${i.reply}` : ''),
      h('div', { class: 'actions mt-s' },
        h('button', { class: 'btn small', onclick: async () => {
          try { await api(`/issues/${i.id}/reopen`, { method: 'POST' }); toast('Reopened.'); await loadIssues(); }
          catch (err) { if (err.message !== 'signed out') toast(err.message); }
        } }, 'Reopen'),
        h('button', { class: 'btn small', onclick: () => openAccount(i.account.id) }, 'Open account')));
  }
  return h('article', { class: 'card' }, body);
}

// The list under the filter bar is repainted on its own, so typing in the search box never loses focus.
function paintIssueList() {
  const box = document.getElementById('issue-list');
  if (!box) return;
  const v = state.issueView;
  const needle = v.q.trim().toLowerCase();
  let items = state.issues.items.filter((i) => (!v.category || i.category === v.category)
    && (!needle || `${i.account.account_no} ${i.account.holder_name} ${i.message}`.toLowerCase().includes(needle)));
  // Default order: open = oldest first (longest waiting), resolved = newest first. The picker overrides it.
  const oldestFirst = v.order ? v.order === 'asc' : state.issueFilter === 'OPEN';
  items = items.slice().sort((a, b) => (oldestFirst ? 1 : -1) * (new Date(a.created_at) - new Date(b.created_at)));
  const filtered = v.category || needle;
  box.replaceChildren(...(items.length ? items.map(issueCard)
    : [h('div', { class: 'empty' }, filtered ? 'No reports match these filters.'
      : (state.issueFilter === 'OPEN' ? 'No open reports. Nice.' : 'Nothing resolved yet.'))]));
}

function viewIssues() {
  const c = state.issues.counts, v = state.issueView;
  const seg = h('div', { class: 'seg', role: 'tablist' },
    ...[['OPEN', `Open (${c.OPEN})`], ['RESOLVED', `Resolved (${c.RESOLVED})`]].map(([key, label]) => h('button', {
      class: state.issueFilter === key ? 'active' : '', role: 'tab',
      onclick: () => { state.issueFilter = key; state.issueOpen = null; loadIssues(); },
    }, label)));
  const categories = [...new Set(state.issues.items.map((i) => i.category))].sort();
  const catSel = h('select', { 'aria-label': 'Category', onchange: () => { v.category = catSel.value; paintIssueList(); } },
    h('option', { value: '' }, 'All categories'),
    categories.map((x) => h('option', { value: x, selected: x === v.category }, x)));
  const search = h('input', { type: 'search', placeholder: 'Search account, name or message', value: v.q, autocomplete: 'off', 'aria-label': 'Search' });
  search.addEventListener('input', () => { v.q = search.value; paintIssueList(); });
  const orderSel = h('select', { 'aria-label': 'Order', onchange: () => { v.order = orderSel.value; paintIssueList(); } },
    h('option', { value: '' }, state.issueFilter === 'OPEN' ? 'Oldest first' : 'Newest first'),
    h('option', { value: state.issueFilter === 'OPEN' ? 'desc' : 'asc', selected: v.order !== '' }, state.issueFilter === 'OPEN' ? 'Newest first' : 'Oldest first'));
  const clear = h('button', { class: 'btn', type: 'button', onclick: () => { state.issueView = { category: '', q: '', order: '' }; render(); } }, 'Clear');
  queueMicrotask(paintIssueList);
  return h('div', {},
    h('div', { class: 'page-title' }, h('h2', {}, 'Issues'), seg),
    state.error ? h('div', { class: 'error' }, state.error) : null,
    h('div', { class: 'filters' }, catSel, orderSel, search, clear),
    h('div', { id: 'issue-list' }));
}


// ---------- overview (the home page) ----------
async function loadOverview(quiet) {
  try {
    state.overview = await api('/overview');
    state.summary.pending_requests = state.overview.pending_requests.count;
    state.summary.open_issues = state.overview.open_issues.count;
    state.error = null;
  } catch (err) {
    if (err.message === 'signed out') return;
    state.error = err.message;
    if (!quiet) toast(err.message);
  }
  if (state.view === 'overview') render();
  else updateBadges();
}

function waiting(iso) {
  return iso ? `Oldest waiting ${ago(iso).replace(' ago', '')}` : 'Nothing waiting';
}

function tile({ label, value, sub, tone, onclick }) {
  return h(onclick ? 'button' : 'div', { class: `tile${tone ? ` ${tone}` : ''}${onclick ? ' click' : ''}`, type: onclick ? 'button' : null, onclick },
    h('span', { class: 'tile-label' }, label),
    h('span', { class: 'tile-value' }, value),
    sub ? h('span', { class: 'tile-sub' }, sub) : null);
}

const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

function viewOverview() {
  const o = state.overview;
  if (!o) return h('div', {}, h('div', { class: 'page-title' }, h('h2', {}, 'Overview')), state.error ? h('div', { class: 'error' }, state.error) : h('div', { class: 'empty' }, 'Loading...'));
  const pr = o.pending_requests, oi = o.open_issues;
  const tiles = (title, items) => h('section', {}, h('h3', { class: 'tiles-title' }, title), h('div', { class: 'tiles' }, items));

  const owing = o.top_owing.length
    ? h('div', { class: 'table-wrap flat' }, h('table', { class: 'compact' },
      h('thead', {}, h('tr', {}, ['Account', 'Holder', 'Due', 'Owes'].map((t) => h('th', {}, t)))),
      h('tbody', {}, o.top_owing.map((a) => h('tr', { class: 'click', onclick: () => openAccount(a.id) },
        h('td', {}, h('button', { class: 'link-btn', onclick: (e) => { e.stopPropagation(); openAccount(a.id); } }, a.account_no)),
        h('td', {}, a.holder_name),
        h('td', {}, fmtDate(a.due_date), a.overdue ? ' ' : null, a.overdue ? chip('bad', 'Overdue') : null),
        h('td', {}, h('strong', {}, money(a.balance))))))))
    : h('p', { class: 'muted flush' }, 'Nobody owes anything right now.');

  const activity = o.recent_activity.length
    ? h('div', {}, o.recent_activity.map((x) => h('div', { class: 'feed-row' },
      h('div', {}, h('strong', {}, ACTION_LABELS[x.action] || x.action),
        x.account_no ? h('span', {}, ' on ', h('button', { class: 'link-btn', onclick: () => openAccount(x.account_id) }, x.account_no)) : null,
        x.detail ? h('div', { class: 'muted' }, x.detail) : null),
      h('div', { class: 'muted feed-meta', title: fmtTime(x.at) }, `${x.by} · ${ago(x.at)}`))))
    : h('p', { class: 'muted flush' }, 'Nothing done from the dashboard yet.');

  return h('div', {},
    h('div', { class: 'page-title' }, h('h2', {}, 'Overview'), h('span', { class: 'muted', title: fmtTime(o.as_of) }, `Updated ${ago(o.as_of)}`)),
    state.error ? h('div', { class: 'error' }, state.error) : null,
    tiles('Needs attention', [
      tile({ label: 'Link requests waiting', value: pr.count, sub: waiting(pr.oldest), tone: pr.count ? 'alert' : 'calm', onclick: () => go('requests') }),
      tile({ label: 'Open issues', value: oi.count, sub: waiting(oi.oldest), tone: oi.count ? 'alert' : 'calm', onclick: () => go('issues') }),
      tile({ label: 'Overdue', value: money(o.overdue.amount), sub: plural(o.overdue.accounts, 'account') + ' past their due date', tone: o.overdue.accounts ? 'alert' : 'calm' }),
    ]),
    tiles('Money', [
      tile({ label: 'Total outstanding', value: money(o.outstanding.amount), sub: `Owed by ${plural(o.outstanding.accounts, 'account')}` }),
      tile({ label: 'Collected this month', value: money(o.collected_month.amount), sub: `${plural(o.collected_month.count, 'payment')} · ${money(o.collected_today.amount)} today` }),
      tile({ label: 'Customer credit', value: money(o.credit.amount), sub: `Held on ${plural(o.credit.accounts, 'account')}` }),
    ]),
    tiles('Customers', [
      tile({ label: 'Accounts', value: o.accounts.total, sub: `${o.accounts.active} active · ${o.accounts.suspended} suspended`, onclick: () => go('customers') }),
      tile({ label: 'App logins', value: o.accounts.logins, sub: 'People with a NetPulse login' }),
    ]),
    h('div', { class: 'cols' },
      h('section', { class: 'card' }, h('h3', {}, 'Biggest balances'), owing),
      h('section', { class: 'card' }, h('h3', {}, 'Recent staff activity'), activity)));
}


// ---------- activity log (admins) ----------
function activityQuery(extra) {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries({ ...state.activityFilter, ...extra })) if (v) params.set(k, v);
  return params.toString();
}

// Loads the first page (or, with `more`, the next one). The filter bar is built once and left alone, so typing in
// it never loses focus: only the list underneath is repainted.
let activitySeq = 0;

async function loadActivity(quiet, more) {
  const a = state.activity;
  const mine = ++activitySeq; // if the filters change while a request is in flight, the older answer is thrown away
  try {
    const d = await api(`/activity?${activityQuery(more && a.next ? { before_id: a.next } : {})}`);
    if (mine !== activitySeq) return;
    a.items = more ? a.items.concat(d.items) : d.items;
    a.next = d.next_before_id;
    a.staff = d.staff;
    a.actions = d.actions;
    state.error = null;
  } catch (err) {
    if (err.message === 'signed out') return;
    if (!quiet) toast(err.message); else state.error = err.message;
  }
  const first = !a.loaded;
  a.loaded = true;
  if (state.view !== 'activity') return;
  if (first) render(); else paintActivity();
}

function paintActivity() {
  const box = document.getElementById('activity-list');
  if (!box) return;
  const a = state.activity;
  if (!a.items.length) { box.replaceChildren(h('div', { class: 'empty' }, 'No activity matches those filters.')); return; }
  const table = h('div', { class: 'table-wrap' }, h('table', { class: 'compact' },
    h('thead', {}, h('tr', {}, ['When', 'Who', 'What', 'Account'].map((t) => h('th', {}, t)))),
    h('tbody', {}, a.items.map((x) => h('tr', {},
      h('td', { class: 'nowrap' }, fmtTime(x.at)),
      h('td', {}, x.by),
      h('td', {}, h('strong', {}, ACTION_LABELS[x.action] || x.action), x.detail ? h('div', { class: 'muted' }, x.detail) : null),
      h('td', {}, x.account_id ? h('button', { class: 'link-btn', onclick: () => openAccount(x.account_id) }, x.account_no) : h('span', { class: 'muted' }, '-')))))));
  box.replaceChildren(table,
    h('div', { class: 'more-row' },
      h('span', { class: 'muted' }, `Showing ${a.items.length}${a.next ? '+' : ''} ${a.items.length === 1 ? 'entry' : 'entries'}`),
      a.next ? h('button', { class: 'btn', onclick: (e) => { e.target.disabled = true; loadActivity(false, true); } }, 'Load more') : null));
}

// ---- CSV export of the activity log: every row matching the current filters, not just what is on screen ----
const EXPORT_MAX_ROWS = 20000;

// A cell that starts with = + - @ (or a tab/CR) would be run as a formula by Excel/Sheets; a leading apostrophe stops that.
function csvCell(v) {
  let t = v == null ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(t)) t = "'" + t;
  return /[",\n\r]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
}

function phTime(iso) { // "2026-10-18 05:46:12" in Philippine time (UTC+8)
  const d = new Date(new Date(iso).getTime() + 8 * 3600 * 1000);
  return d.toISOString().slice(0, 19).replace('T', ' ');
}

async function exportActivityCsv(button) {
  const label = button.textContent;
  button.disabled = true;
  try {
    const rows = [];
    let before = null, truncated = false;
    for (;;) {
      button.textContent = `Exporting... ${rows.length}`;
      const d = await api(`/activity?${activityQuery(before ? { before_id: before } : { export: '1' })}`); // the server logs the export on this first request
      rows.push(...d.items);
      if (!d.next_before_id) break;
      if (rows.length >= EXPORT_MAX_ROWS) { truncated = true; break; }
      before = d.next_before_id;
    }
    if (!rows.length) { toast('Nothing to export for these filters.'); return; }
    const lines = [['Date and time (PH)', 'Staff', 'Action', 'Account', 'Details'].map(csvCell).join(',')];
    for (const r of rows) {
      lines.push([phTime(r.at), r.by, ACTION_LABELS[r.action] || r.action, r.account_no || '', r.detail || ''].map(csvCell).join(','));
    }
    // The BOM makes Excel read the file as UTF-8 (so the peso sign and accents come out right).
    const blob = new Blob(['\ufeff' + lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = h('a', { href: url, download: `netpulse-activity-${phTime(new Date().toISOString()).slice(0, 10)}.csv` });
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
    toast(truncated ? `Exported the newest ${rows.length} rows (the limit). Narrow the dates to get older ones.` : `Exported ${rows.length} rows.`);
  } catch (err) {
    if (err.message !== 'signed out') toast(err.message);
  } finally {
    button.disabled = false;
    button.textContent = label;
  }
}

function viewActivity() {
  const a = state.activity, f = state.activityFilter;
  const reload = () => loadActivity(false);
  const staffSel = h('select', { 'aria-label': 'Staff member', onchange: () => { f.staff_id = staffSel.value; reload(); } },
    h('option', { value: '' }, 'All staff'),
    a.staff.map((x) => h('option', { value: x.id, selected: String(x.id) === String(f.staff_id) }, x.name)));
  const actSel = h('select', { 'aria-label': 'Type of action', onchange: () => { f.action = actSel.value; reload(); } },
    h('option', { value: '' }, 'All actions'),
    a.actions.map((x) => h('option', { value: x, selected: x === f.action }, ACTION_LABELS[x] || x)));
  const search = h('input', { type: 'search', placeholder: 'Search account number or details', value: f.q, autocomplete: 'off', 'aria-label': 'Search' });
  let timer;
  search.addEventListener('input', () => { f.q = search.value; clearTimeout(timer); timer = setTimeout(reload, 300); });
  const since = h('input', { type: 'date', value: f.since, 'aria-label': 'From date', onchange: () => { f.since = since.value; reload(); } });
  const until = h('input', { type: 'date', value: f.until, 'aria-label': 'To date', onchange: () => { f.until = until.value; reload(); } });
  const exportBtn = h('button', { class: 'btn', type: 'button', onclick: () => exportActivityCsv(exportBtn) }, 'Export CSV');
  const orderSel = h('select', { 'aria-label': 'Order', onchange: () => { f.order = orderSel.value; reload(); } },
    h('option', { value: '' }, 'Newest first'), h('option', { value: 'asc', selected: f.order === 'asc' }, 'Oldest first'));
  const clear = h('button', { class: 'btn', onclick: () => { state.activityFilter = { staff_id: '', action: '', q: '', since: '', until: '', order: '' }; render(); loadActivity(false); } }, 'Clear');
  queueMicrotask(paintActivity);
  return h('div', {},
    h('div', { class: 'page-title' }, h('h2', {}, 'Activity'), h('span', { class: 'muted' }, 'Everything staff have done.')),
    state.error ? h('div', { class: 'error' }, state.error) : null,
    h('div', { class: 'filters' }, staffSel, actSel, orderSel, h('label', { class: 'date-field' }, 'From', since), h('label', { class: 'date-field' }, 'To', until), search, clear, exportBtn),
    h('div', { id: 'activity-list' }));
}