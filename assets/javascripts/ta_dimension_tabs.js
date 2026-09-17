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

  // ── Searchable dropdown ──────────────────────────────────────────────────────────────────
  // An anchored popover rather than a modal: the list is long, it is filtered as you type, and it
  // belongs visually to the "+" button it drops out of.
  var menuOpen = false;
  var menuSections = null;   // cached payload
  var filterText = '';
  var activeIndex = -1;      // keyboard highlight, index into the currently visible options

  function menuEl() { return document.getElementById('ta-dimension-menu'); }
  function bodyEl() { return document.getElementById('ta-dimension-menu-body'); }
  function searchEl() { return document.getElementById('ta-dimension-search'); }

  function visibleOptions() {
    var body = bodyEl();
    return body ? Array.prototype.slice.call(body.querySelectorAll('.ta-dim-option:not([disabled])')) : [];
  }

  function matches(label) {
    return !filterText || label.toLowerCase().indexOf(filterText) !== -1;
  }

  function renderMenu() {
    var body = bodyEl();
    if (!body) { return; }

    if (!menuSections) {
      body.innerHTML = '<p class="px-4 py-3 text-sm text-gray-500">…</p>';
      return;
    }

    var chosen = readTabs().map(function (t) { return t.key; });
    var html = '';

    menuSections.forEach(function (section) {
      var fields = section.fields.filter(function (f) { return matches(f.label); });
      if (!fields.length) { return; }

      html += '<p class="ta-dim-section px-4 pt-2 pb-1">' + escapeHtml(section.label) + '</p>';
      fields.forEach(function (field) {
        // A pinned field is already a permanent tab for everyone, so it can't be added again.
        var used = field.pinned || chosen.indexOf(field.key) !== -1;
        html += '<button type="button" role="option" aria-selected="false" class="ta-dim-option"' +
          (used ? ' disabled' : '') +
          ' data-ta-dim-pick="' + escapeHtml(field.key) + '"' +
          ' data-ta-dim-label="' + escapeHtml(field.label) + '">' +
            '<span>' + escapeHtml(field.label) + '</span>' +
            (used ? '<span class="ta-dim-used">' + escapeHtml(config.labels.alreadyUsed) + '</span>' : '') +
          '</button>';
      });
    });

    body.innerHTML = html || '<p class="px-4 py-3 text-sm text-gray-500">' +
      escapeHtml(filterText ? config.labels.noMatches : config.labels.empty) + '</p>';

    activeIndex = -1;
  }

  function highlight(delta) {
    var options = visibleOptions();
    if (!options.length) { return; }

    if (activeIndex >= 0 && options[activeIndex]) {
      options[activeIndex].classList.remove('ta-dim-active');
    }
    activeIndex += delta;
    if (activeIndex < 0) { activeIndex = options.length - 1; }
    if (activeIndex >= options.length) { activeIndex = 0; }

    var el = options[activeIndex];
    el.classList.add('ta-dim-active');
    el.scrollIntoView({ block: 'nearest' });
  }

  function choose(key, label) {
    addTab(key, label);
    closeMenu();
    navigateTo(key);
  }

  function openMenu() {
    var menu = menuEl();
    var btn = document.getElementById('ta-add-dimension-btn');
    if (!menu) { return; }

    menu.classList.remove('hidden');
    if (btn) { btn.setAttribute('aria-expanded', 'true'); }
    menuOpen = true;

    filterText = '';
    var search = searchEl();
    if (search) { search.value = ''; }
    renderMenu();

    fetchFields().then(function (sections) {
      menuSections = sections;
      if (menuOpen) { renderMenu(); }
    }).catch(function () {
      var body = bodyEl();
      if (body) {
        body.innerHTML = '<p class="px-4 py-3 text-sm text-red-500">' + escapeHtml(config.labels.empty) + '</p>';
      }
    });

    if (search) { search.focus(); }
  }

  function closeMenu() {
    var menu = menuEl();
    var btn = document.getElementById('ta-add-dimension-btn');
    if (!menu) { return; }
    menu.classList.add('hidden');
    if (btn) { btn.setAttribute('aria-expanded', 'false'); }
    menuOpen = false;
    activeIndex = -1;
  }

  function bindMenuEvents() {
    var btn = document.getElementById('ta-add-dimension-btn');
    if (btn) {
      btn.addEventListener('click', function (event) {
        event.stopPropagation();
        if (menuOpen) { closeMenu(); } else { openMenu(); }
      });
    }

    var search = searchEl();
    if (search) {
      search.addEventListener('input', function () {
        filterText = search.value.trim().toLowerCase();
        renderMenu();
      });
      search.addEventListener('keydown', function (event) {
        if (event.key === 'ArrowDown') { event.preventDefault(); highlight(1); }
        else if (event.key === 'ArrowUp') { event.preventDefault(); highlight(-1); }
        else if (event.key === 'Enter') {
          event.preventDefault();
          var options = visibleOptions();
          // Enter with nothing highlighted takes the first match, which is what a search box implies.
          var el = activeIndex >= 0 ? options[activeIndex] : options[0];
          if (el) { choose(el.getAttribute('data-ta-dim-pick'), el.getAttribute('data-ta-dim-label')); }
        }
      });
    }

    var body = bodyEl();
    if (body) {
      body.addEventListener('click', function (event) {
        var pick = event.target.closest('[data-ta-dim-pick]');
        if (!pick || pick.hasAttribute('disabled')) { return; }
        choose(pick.getAttribute('data-ta-dim-pick'), pick.getAttribute('data-ta-dim-label'));
      });
    }

    // Click-outside and Escape both dismiss, as expected of a dropdown.
    document.addEventListener('click', function (event) {
      if (!menuOpen) { return; }
      var menu = menuEl();
      if (menu && !menu.contains(event.target) && event.target.id !== 'ta-add-dimension-btn') {
        closeMenu();
      }
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && menuOpen) {
        closeMenu();
        var b = document.getElementById('ta-add-dimension-btn');
        if (b) { b.focus(); }
      }
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
      var pinnedKeys = {};
      sections.forEach(function (section) {
        section.fields.forEach(function (field) {
          known[field.key] = field.label;
          if (field.pinned) { pinnedKeys[field.key] = true; }
        });
      });

      // Drop anything the server no longer offers, and anything an administrator has since
      // pinned — a pinned field is rendered as a permanent tab, so keeping the chip would show
      // it twice.
      var next = tabs.filter(function (t) { return known[t.key] && !pinnedKeys[t.key]; })
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
    if (!config.activeKey || config.activeIsPinned) { return; }
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
    bindMenuEvents();
    reconcile();
    initTabBody();

    if (window.taDimensionTabBody) {
      var stored = null;
      try { stored = localStorage.getItem('ta_dimension_view_mode'); } catch (e) { stored = null; }
      window.taDimensionShowView(stored || window.taDimensionTabBody.viewState || 'summary');
    }
  });
}());
