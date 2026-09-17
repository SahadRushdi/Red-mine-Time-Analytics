// User-added "group by" tabs, shared by the My Time and My Team dashboards.
//
// The pinned tabs are server-rendered; so is an added tab's content. The only thing that lives in
// the browser is the *list* of added tabs, kept in sessionStorage so it belongs to one browser tab
// and disappears when that tab is closed — matching how this plugin already scopes the My Time
// custom date range and the scroll-restore flags.
//
// Switching to an added tab is the same navigation the pinned tabs do: set view_mode in the URL
// and reload. The server is the only authority on whether a key is still groupable, so a stale
// entry can never render anything — at worst it redirects back with ta_dim_invalid and gets pruned.
(function () {
  var STORAGE_VERSION = 1;
  var MAX_TABS = 8;

  var config = null;
  var fieldsPromise = null;

  function readConfig() {
    var el = document.getElementById('ta-dimension-config');
    if (!el) { return null; }
    try { return JSON.parse(el.textContent); } catch (e) { return null; }
  }

  function storageKey() {
    return 'ta_dim_tabs_' + config.storageScope;
  }

  function readTabs() {
    try {
      var raw = sessionStorage.getItem(storageKey());
      if (!raw) { return []; }
      var parsed = JSON.parse(raw);
      if (!parsed || parsed.v !== STORAGE_VERSION || !Array.isArray(parsed.tabs)) { return []; }
      return parsed.tabs.filter(function (t) { return t && t.key; });
    } catch (e) {
      return [];
    }
  }

  function writeTabs(tabs) {
    try {
      sessionStorage.setItem(storageKey(), JSON.stringify({ v: STORAGE_VERSION, tabs: tabs.slice(0, MAX_TABS) }));
    } catch (e) {
      // Private browsing / blocked storage: the tabs simply don't persist. Everything else still works.
    }
  }

  // Same URL mutation the pinned tabs' toggleViewMode does, kept separate so that function is
  // untouched. `page` is dropped because row counts differ between dimensions.
  function navigateTo(viewMode) {
    var params = new URLSearchParams();
    Object.keys(config.carryParams || {}).forEach(function (name) {
      var value = config.carryParams[name];
      if (value !== null && value !== undefined && value !== '') { params.set(name, value); }
    });
    params.set('view_mode', viewMode);
    window.location.href = config.basePath + '?' + params.toString();
  }

  function fetchFields() {
    if (fieldsPromise) { return fieldsPromise; }
    fieldsPromise = fetch(config.fieldsPath, {
      credentials: 'same-origin',
      headers: { 'X-Requested-With': 'XMLHttpRequest' }
    })
      .then(function (response) {
        if (!response.ok) { throw new Error('HTTP ' + response.status); }
        return response.json();
      })
      .then(function (data) { return data.sections || []; });
    return fieldsPromise;
  }

  function escapeHtml(text) {
    return window.taEscapeHtml ? window.taEscapeHtml(text) : String(text === null || text === undefined ? '' : text);
  }

  // ── Tab chips ────────────────────────────────────────────────────────────────────────────
  function renderChips() {
    var host = document.getElementById('ta-dimension-chips');
    if (!host) { return; }

    host.innerHTML = readTabs().map(function (tab) {
      var active = tab.key === config.activeKey;
      var classes = 'ta-view-tab inline-block p-4 rounded-t-lg ' +
        (active ? 'ta-view-tab-active' : 'text-gray-500 hover:text-gray-600 hover:bg-gray-50');
      return '<li class="me-2">' +
        '<span class="' + classes + '" data-ta-dim-key="' + escapeHtml(tab.key) + '">' +
          '<span class="flex items-center gap-2">' +
            '<span class="cursor-pointer" data-ta-dim-open="1">' + escapeHtml(tab.label) + '</span>' +
            '<span class="material-symbols-outlined cursor-pointer opacity-60 hover:opacity-100" ' +
              'style="font-size: 16px;" data-ta-dim-remove="1" role="button" tabindex="0" ' +
              'title="' + escapeHtml(config.labels.remove) + '" aria-label="' + escapeHtml(config.labels.remove) + '">close</span>' +
          '</span>' +
        '</span>' +
      '</li>';
    }).join('');
  }

  function addTab(key, label) {
    var tabs = readTabs().filter(function (t) { return t.key !== key; });
    tabs.push({ key: key, label: label });
    writeTabs(tabs);
  }

  function removeTab(key) {
    writeTabs(readTabs().filter(function (t) { return t.key !== key; }));
    renderChips();
    if (key === config.activeKey) { navigateTo(config.defaultViewMode); }
  }

  function bindChipEvents() {
    var host = document.getElementById('ta-dimension-chips');
    if (!host) { return; }

    host.addEventListener('click', function (event) {
      var chip = event.target.closest('[data-ta-dim-key]');
      if (!chip) { return; }
      var key = chip.getAttribute('data-ta-dim-key');

      if (event.target.closest('[data-ta-dim-remove]')) {
        event.preventDefault();
        removeTab(key);
        return;
      }
      if (key !== config.activeKey) { navigateTo(key); }
    });
  }

  // ── Picker ───────────────────────────────────────────────────────────────────────────────
  function openPicker() {
    var modal = document.getElementById('ta-dimension-picker');
    var body = document.getElementById('ta-dimension-picker-body');
    if (!modal || !body) { return; }

    modal.classList.remove('hidden');
    modal.classList.add('flex');
    body.innerHTML = '<p class="text-gray-500">' + escapeHtml(config.labels.pickerTitle) + '…</p>';

    fetchFields().then(function (sections) {
      var chosen = readTabs().map(function (t) { return t.key; });
      var html = sections.map(function (section) {
        var rows = section.fields.map(function (field) {
          var already = chosen.indexOf(field.key) !== -1;
          return '<button type="button" class="w-full text-left px-3 py-2 rounded-md hover:bg-gray-50 ' +
            (already ? 'text-gray-400' : 'text-gray-800') + '" ' +
            'data-ta-dim-pick="' + escapeHtml(field.key) + '" ' +
            'data-ta-dim-label="' + escapeHtml(field.label) + '">' +
            escapeHtml(field.label) + (already ? ' <span class="text-xs">✓</span>' : '') +
          '</button>';
        }).join('');
        return '<div class="mb-3">' +
          '<p class="px-3 pb-1 text-xs font-semibold text-gray-500">' + escapeHtml(section.label) + '</p>' +
          rows +
        '</div>';
      }).join('');

      body.innerHTML = html || '<p class="text-gray-500">' + escapeHtml(config.labels.empty) + '</p>';
    }).catch(function () {
      body.innerHTML = '<p class="text-red-500">' + escapeHtml(config.labels.empty) + '</p>';
    });
  }

  function closePicker() {
    var modal = document.getElementById('ta-dimension-picker');
    if (!modal) { return; }
    modal.classList.add('hidden');
    modal.classList.remove('flex');
  }

  function bindPickerEvents() {
    var addBtn = document.getElementById('ta-add-dimension-btn');
    if (addBtn) { addBtn.addEventListener('click', openPicker); }

    var closeBtn = document.getElementById('ta-dimension-picker-close');
    if (closeBtn) { closeBtn.addEventListener('click', closePicker); }

    var modal = document.getElementById('ta-dimension-picker');
    if (modal) {
      modal.addEventListener('click', function (event) {
        if (event.target === modal) { closePicker(); }
      });
    }

    var body = document.getElementById('ta-dimension-picker-body');
    if (body) {
      body.addEventListener('click', function (event) {
        var pick = event.target.closest('[data-ta-dim-pick]');
        if (!pick) { return; }
        var key = pick.getAttribute('data-ta-dim-pick');
        addTab(key, pick.getAttribute('data-ta-dim-label'));
        closePicker();
        navigateTo(key);
      });
    }

    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') { closePicker(); }
    });
  }

  // ── Reconciliation ───────────────────────────────────────────────────────────────────────
  // The cached list is rendered first so there's no flash, then checked against the server: a
  // field that was deleted, un-ticked as "Used as a filter", or hidden from this user's roles is
  // dropped, and a renamed one gets its new label.
  function reconcile() {
    var tabs = readTabs();
    if (!tabs.length) { return; }

    fetchFields().then(function (sections) {
      var known = {};
      sections.forEach(function (section) {
        section.fields.forEach(function (field) { known[field.key] = field.label; });
      });

      var next = tabs.filter(function (t) { return known[t.key]; })
                     .map(function (t) { return { key: t.key, label: known[t.key] }; });

      if (JSON.stringify(next) !== JSON.stringify(tabs)) {
        writeTabs(next);
        renderChips();
      }
    }).catch(function () {
      // Offline or a failed request: keep whatever is cached rather than wiping the user's tabs.
    });
  }

  // A shared link lands on a tab this browser tab has never seen — materialise it rather than
  // showing an active tab with no chip.
  function adoptActiveKey() {
    if (!config.activeKey) { return; }
    var known = readTabs().some(function (t) { return t.key === config.activeKey; });
    if (known) { return; }
    addTab(config.activeKey, config.activeLabel || config.activeKey);
    renderChips();
  }

  // The server bounced us off a tab whose field is gone. Drop it and clean the URL so a refresh
  // doesn't repeat the redirect.
  function pruneInvalidKey() {
    var params = new URLSearchParams(window.location.search);
    var invalid = params.get('ta_dim_invalid');
    if (!invalid) { return; }

    writeTabs(readTabs().filter(function (t) { return t.key !== invalid; }));
    params.delete('ta_dim_invalid');
    var query = params.toString();
    window.history.replaceState({}, '', window.location.pathname + (query ? '?' + query : ''));
  }

  // ── Active tab body: Summary cards, drill-down, sorting, view toggle ─────────────────────
  var summaryTable = null;

  function initTabBody() {
    var body = window.taDimensionTabBody;
    if (!body) { return; }

    var viewId = body.viewId;
    var payloadEl = document.getElementById(viewId + '-payload');
    var cards = document.getElementById(viewId + '-cards');
    if (!payloadEl || !cards) { return; }

    var payload = JSON.parse(payloadEl.getAttribute('data-payload'));
    var colors = window.TA_DIMENSION_COLORS || [
      '#4E79A7', '#F28E2B', '#E15759', '#76B7B2', '#59A14F',
      '#EDC948', '#B07AA1', '#FF9DA7', '#9C755F', '#BAB0AC'
    ];

    summaryTable = window.TaClientTable({
      getItems: function () { return payload.items || []; },
      sortValue: function (item, field) { return field === 'name' ? item.name : item.hours; },
      renderRow: function (item, index) {
        return window.taExpandableSummaryCardHtml(item, index, payload.grandTotal, colors);
      },
      container: cards,
      paginationInfo: document.getElementById(viewId + '-pagination-info'),
      paginationLinks: document.getElementById(viewId + '-pagination-links'),
      perPage: body.perPage || 25,
      sortField: 'hours',
      sortDir: 'desc'
    });
    summaryTable.render();

    // Same drill-down engine the Project/Activity tabs use; only the endpoint differs.
    window.taInitExpandableSummaryRows(viewId + '-cards', viewId + '-summary-view',
      { group: body.breakdownPath },
      {
        loading: body.labels.loading,
        error: body.labels.error,
        emptyIssues: body.labels.emptyIssues,
        emptyProjects: body.labels.emptyIssues
      });

    cards.addEventListener('click', function () { window.taDimensionUpdateCollapseAll(); });
  }

  // ── Globals used by _dimension_tab_body.html.erb ─────────────────────────────────────────
  window.taDimensionShowView = function (mode) {
    var body = window.taDimensionTabBody;
    if (!body) { return; }
    var viewId = body.viewId;
    var summary = mode === 'summary';

    var summaryEl = document.getElementById(viewId + '-summary-view');
    var detailedEl = document.getElementById(viewId + '-detailed-view');
    var paginationBar = document.getElementById(viewId + '-detailed-pagination-bar');
    var sortButtons = document.getElementById('ta-dimension-sort-buttons');

    if (summaryEl) { summaryEl.style.display = summary ? 'block' : 'none'; }
    if (detailedEl) { detailedEl.style.display = summary ? 'none' : 'block'; }
    if (paginationBar) { paginationBar.style.display = summary ? 'none' : 'flex'; }
    if (sortButtons) { sortButtons.style.display = summary ? 'flex' : 'none'; }

    var activeStyle = 'background-color: #3b82f6 !important; color: white !important;';
    var summaryBtn = document.getElementById('show-summary-btn-' + viewId);
    var detailedBtn = document.getElementById('show-detailed-btn-' + viewId);
    if (summaryBtn) { summaryBtn.setAttribute('style', summary ? activeStyle : ''); }
    if (detailedBtn) { detailedBtn.setAttribute('style', summary ? '' : activeStyle); }

    window.taDimensionUpdateCollapseAll();

    // Matches how the pinned tabs remember Summary vs Detailed.
    try { localStorage.setItem('ta_dimension_view_mode', mode); } catch (e) { /* storage blocked */ }
  };

  window.taDimensionSortClick = function (field) {
    var body = window.taDimensionTabBody;
    if (!summaryTable || !body) { return; }

    summaryTable.setSort(field, field === 'name' ? 'asc' : 'desc');
    var state = summaryTable.getState();
    var viewId = body.viewId;

    var nameBtn = document.getElementById('sort-name-' + viewId);
    var hoursBtn = document.getElementById('sort-hours-' + viewId);
    var arrow = state.sortDir === 'asc' ? ' ↑' : ' ↓';

    if (nameBtn) {
      var nameActive = state.sortField === 'name';
      nameBtn.setAttribute('style', nameActive
        ? 'background:#eff6ff;color:#1d4ed8;border-color:#93c5fd;'
        : 'background:#fff;color:#6b7280;border-color:#d1d5db;');
      nameBtn.textContent = 'A–Z' + (nameActive ? arrow : ' ↑');
    }
    if (hoursBtn) {
      var hoursActive = state.sortField === 'hours';
      hoursBtn.setAttribute('style', hoursActive
        ? 'background:#eff6ff;color:#1d4ed8;border-color:#93c5fd;'
        : 'background:#fff;color:#6b7280;border-color:#d1d5db;');
      hoursBtn.textContent = 'Hours' + (hoursActive ? arrow : ' ↓');
    }
  };

  window.taDimensionCollapseAll = function () {
    var body = window.taDimensionTabBody;
    if (!body) { return; }
    window.taCollapseAllRows(body.viewId + '-cards');
    window.taDimensionUpdateCollapseAll();
  };

  // The "Collapse all" control only appears once something is actually expanded, matching the
  // pinned Activity/Project tabs.
  window.taDimensionUpdateCollapseAll = function () {
    var body = window.taDimensionTabBody;
    if (!body) { return; }
    var wrapper = document.getElementById(body.viewId + '-collapse-all-wrapper');
    var cards = document.getElementById(body.viewId + '-cards');
    if (!wrapper || !cards) { return; }
    wrapper.style.display = cards.querySelector('.ts-row-details:not(.hidden)') ? '' : 'none';
  };

  document.addEventListener('DOMContentLoaded', function () {
    config = readConfig();
    if (!config) { return; }

    pruneInvalidKey();
    adoptActiveKey();
    renderChips();
    bindChipEvents();
    bindPickerEvents();
    reconcile();
    initTabBody();

    if (window.taDimensionTabBody) {
      var stored = null;
      try { stored = localStorage.getItem('ta_dimension_view_mode'); } catch (e) { stored = null; }
      window.taDimensionShowView(stored || window.taDimensionTabBody.viewState || 'summary');
    }
  });
}());
