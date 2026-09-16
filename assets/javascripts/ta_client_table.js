// Generic client-side sort + paginate + render helper.
//
// Used by the My Time / My Team Summary card lists and the Monthly avg table: the full
// dataset is embedded once (as JSON) when the page renders, and all sorting/paging happens
// in memory from then on — no page reloads, and nothing (e.g. a donut chart reading the same
// full dataset) is ever left looking only at whatever page happens to be on screen.
(function (global) {
  function hexToRgba(hex, alpha) {
    var c = (hex || '').replace('#', '');
    if (c.length === 3) { c = c.split('').map(function (ch) { return ch + ch; }).join(''); }
    if (c.length !== 6) { return 'rgba(100,116,139,' + alpha + ')'; }
    var r = parseInt(c.substr(0, 2), 16);
    var g = parseInt(c.substr(2, 2), 16);
    var b = parseInt(c.substr(4, 2), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
  }

  function shareBadgeHtml(hex, percentage) {
    return '<span class="inline-block rounded-full px-2.5 py-0.5 text-xs font-semibold" ' +
      'style="background:' + hexToRgba(hex, 0.14) + ';color:' + hex + ';">' +
      percentage.toFixed(1) + '%</span>';
  }

  // "Locked" badge (amber, lock icon) for a member who logged time in the selected period but
  // whose Redmine account is now locked. Mirrors ta_locked_badge (TimeAnalyticsHelper) exactly,
  // for the places this needs to be built client-side (Members Summary cards, the Team Members
  // period popup) instead of server-rendered.
  function lockedBadgeHtml(label) {
    return '<span class="inline-flex items-center gap-1 rounded-md border border-amber-200 bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-700">' +
      '<svg class="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0110 0v4"/></svg>' +
      (label || 'Locked') + '</span>';
  }

  // Mirrors TimeAnalyticsHelper#format_hours (app/helpers/time_analytics_helper.rb): a
  // fixed "H:MM" format, not dependent on any server Setting, so it's safe to reproduce here.
  function formatHours(hours) {
    if (hours === null || hours === undefined) { return ''; }
    var totalMinutes = Math.round(parseFloat(hours) * 60);
    var h = Math.floor(totalMinutes / 60);
    var m = totalMinutes % 60;
    return h + ':' + (m < 10 ? '0' + m : m);
  }

  var escapeEl = null;
  function escapeHtml(text) {
    if (text === null || text === undefined) { return ''; }
    if (!escapeEl) { escapeEl = document.createElement('div'); }
    escapeEl.textContent = String(text);
    return escapeEl.innerHTML;
  }

  // Chevron icon shared by every expandable row (Team Dashboard's Project/Activity row
  // drill-down). Deliberately a plain <svg>, never a <button> — Redmine's base theme paints
  // every real <button> blue on hover/focus (button:hover, button:focus { background-color:
  // #004dc2 } in the core theme), which is exactly what a <button>-based toggle picked up.
  // My Work Log's row-expand chevron (time_entry_panel/index.html.erb) uses this same
  // plain-svg-inside-a-clickable-row approach for the same reason. Rotates via the
  // .ts-row-chevron-open class (time_analytics.css) instead of a default-rotated state, so it
  // points right when collapsed and down when expanded — matching My Work Log exactly.
  function chevronIconHtml() {
    return '<svg class="ts-row-chevron w-4 h-4 text-gray-400 shrink-0 transition-transform duration-200" aria-hidden="true" fill="none" stroke="currentColor" viewBox="0 0 24 24">' +
      '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"></path>' +
    '</svg>';
  }

  // Reusable issue-row renderer for the Team/Individual dashboards' Project/Activity drill-down.
  // Tracker badge + clickable "#id: subject" opening in a new tab (same link style as the
  // Individual Dashboard's Issue tab) + hours. No distribution bar, no percentage pill, and the
  // only pill shown is Assignee (the Issue's own "Assigned to" field) — never Project/Activity/
  // Status: a project or activity is already implied by the row's place in the drill-down, one
  // issue can log time under several activities so an Activity pill would be misleading, and a
  // bare list of issues has no shared total for a bar/percentage to represent a share of.
  // item: { id, subject, trackerName, url, hours, assigneeName }
  function issueRowHtml(item) {
    var titleHtml = '<span class="ts-tracker-badge">' + escapeHtml(item.trackerName) + '</span> ' +
      '<a href="' + item.url + '" target="_blank" class="text-sm font-semibold !text-black hover:!text-blue-600 hover:!underline mr-1 transition-colors">#' + item.id + '</a>' +
      '<a href="' + item.url + '" target="_blank" class="text-sm font-normal !text-black hover:!text-blue-600 hover:!underline transition-colors">: ' + escapeHtml(item.subject) + '</a>' +
      (item.assigneeName ? ' <span class="ts-assignee-badge">' + escapeHtml(item.assigneeName) + '</span>' : '');
    return '<div class="bg-white hover:bg-gray-50 rounded-lg px-2 py-1 transition-colors duration-200" data-hours="' + item.hours + '">' +
      '<div class="flex items-center justify-between gap-3">' +
        '<h3 class="text-base font-medium text-gray-900 flex-1 mr-4">' + titleHtml + '</h3>' +
        '<span class="text-base font-semibold text-gray-900 flex-shrink-0">' + formatHours(item.hours) + '</span>' +
      '</div>' +
    '</div>';
  }

  // Renders a list of issue items (from issue_breakdown's JSON response) as a single HTML
  // string. No distribution bar/percentage here — those only apply one level up, where a row
  // represents a share of the project/activity total; a bare list of issues has no such total.
  function issueListHtml(items) {
    return items.map(issueRowHtml).join('');
  }

  // ── Project/Activity row drill-down engine (Team + Individual dashboards) ────────────────
  // Shared by both dashboards' Project/Activity Summary tables: a row expands (chevron, or a
  // click anywhere in its header — matching My Work Log's row-expand behavior) to lazy-load
  // either the issues under it (Project tab, or an Activity tab's project sub-row) or the
  // projects under it (Activity tab's top-level row). Nothing here is dashboard-specific — the
  // two endpoint URLs and the four label strings are supplied by the calling view, since this
  // file is a plain static asset and can't call Rails route helpers or l().
  function urlArrayParam(name) {
    try { return new URLSearchParams(window.location.search).getAll(name); } catch (e) { return []; }
  }

  // Unified Project/Activity Summary card: chevron + name + hours + share badge + distribution
  // bar, plus a hidden .ts-row-details container the row's own drill-down content lazy-loads
  // into. Branches only on which identifying field is present: item.projectIds (array — Project
  // tab rows, and an Activity tab's project sub-rows) or item.activityId (scalar or null —
  // Activity tab's top-level rows).
  function expandableSummaryCardHtml(item, index, grandTotal, colors) {
    var percentage = grandTotal > 0 ? (item.hours / grandTotal * 100) : 0;
    var color = colors[index % colors.length];
    var name = escapeHtml(item.name);
    var idAttr;
    if (item.projectIds !== undefined) {
      idAttr = " data-project-ids='" + escapeHtml(JSON.stringify(item.projectIds || [])) + "'";
    } else {
      var activityIdAttr = (item.activityId === null || item.activityId === undefined) ? '' : item.activityId;
      idAttr = ' data-activity-id="' + activityIdAttr + '"';
    }
    return '<div class="ts-expandable-row"' + idAttr + '>' +
      '<div class="ts-row-header bg-white hover:bg-gray-50 rounded-lg px-2 py-1 transition-colors duration-200 cursor-pointer" data-hours="' + item.hours + '" data-name="' + name + '">' +
        '<div class="flex items-center justify-between mb-1 gap-3">' +
          '<h3 class="text-base font-medium text-gray-900 flex items-center gap-2">' + chevronIconHtml() + '<span>' + name + '</span></h3>' +
          '<div class="flex items-center gap-3">' +
            '<span class="text-base font-semibold text-gray-900">' + formatHours(item.hours) + '</span>' +
            '<span class="min-w-[45px] text-right">' + shareBadgeHtml(color, percentage) + '</span>' +
          '</div>' +
        '</div>' +
        '<div class="h-2 bg-gray-200 rounded-full overflow-hidden">' +
          '<div class="h-full rounded-full transition-all duration-300" style="width: ' + percentage + '%; background-color: ' + color + ';"></div>' +
        '</div>' +
      '</div>' +
      '<div class="ts-row-details hidden"></div>' +
    '</div>';
  }

  // Mid-tier row (Activity tab only): plain name + hours, no bar/badge, matching the Figma.
  function subRowHtml(item) {
    var name = escapeHtml(item.name);
    var idsAttr = escapeHtml(JSON.stringify(item.ids || []));
    return '<div class="ts-expandable-row" data-project-ids=\'' + idsAttr + '\'>' +
      '<div class="ts-row-header flex items-center justify-between py-1 px-2 hover:bg-gray-50 rounded-lg cursor-pointer">' +
        '<span class="flex items-center gap-2 text-base font-medium text-gray-900">' + chevronIconHtml() + '<span>' + name + '</span></span>' +
        '<span class="text-base font-semibold text-gray-900">' + formatHours(item.hours) + '</span>' +
      '</div>' +
      '<div class="ts-row-details hidden"></div>' +
    '</div>';
  }

  // Figures out which endpoint/params a row's chevron should fetch, purely from the row's own
  // data attributes plus (for a nested project row under an Activity) its closest ancestor
  // activity id — so one handler serves both single-level (Project tab) and two-level (Activity
  // tab) drill-downs. `endpoints` is { issue, projects } — the two route paths.
  function rowFetchSpec(rowEl, endpoints) {
    var params = new URLSearchParams();
    urlArrayParam('temp_excluded_ids[]').forEach(function(id) { params.append('temp_excluded_ids[]', id); });

    if (rowEl.hasAttribute('data-project-ids')) {
      var ids = JSON.parse(rowEl.getAttribute('data-project-ids') || '[]');
      if (ids.length) {
        ids.forEach(function(id) { params.append('project_ids[]', id); });
      } else {
        params.append('no_project', '1');
      }
      var activityAncestor = rowEl.closest('[data-activity-id]');
      if (activityAncestor) {
        var activityId = activityAncestor.getAttribute('data-activity-id');
        if (activityId) { params.append('activity_ids[]', activityId); } else { params.append('no_activity', '1'); }
      }
      return { endpoint: endpoints.issue, params: params, kind: 'issues' };
    }

    if (rowEl.hasAttribute('data-activity-id')) {
      var activityId2 = rowEl.getAttribute('data-activity-id');
      if (activityId2) { params.append('activity_ids[]', activityId2); } else { params.append('no_activity', '1'); }
      return { endpoint: endpoints.projects, params: params, kind: 'projects' };
    }

    return null;
  }

  // Forwards a container's own data-* attributes as query params, camelCase -> snake_case
  // (data-team-id -> team_id, data-user-id -> user_id, data-filter -> filter, ...) so the same
  // function serves every dashboard's own filter-state attributes without hardcoding names.
  function rowRequestParams(containerEl, params) {
    var dataset = containerEl.dataset || {};
    Object.keys(dataset).forEach(function(key) {
      var val = dataset[key];
      if (!val) return;
      var paramName = key.replace(/[A-Z]/g, function(m) { return '_' + m.toLowerCase(); });
      params.append(paramName, val);
    });
    return params;
  }

  function loadRowDetails(rowEl, details, viewEl, endpoints, labels) {
    var spec = rowFetchSpec(rowEl, endpoints);
    if (!spec) return;

    details.innerHTML = '<div class="px-2 py-2 text-sm text-gray-500">' + escapeHtml(labels.loading) + '</div>';
    var params = rowRequestParams(viewEl, spec.params);

    fetch(spec.endpoint + '?' + params.toString(), {
      credentials: 'same-origin',
      headers: { 'X-Requested-With': 'XMLHttpRequest' }
    })
      .then(function(response) {
        if (!response.ok) { throw new Error('HTTP ' + response.status); }
        return response.json();
      })
      .then(function(data) {
        var items = data.items || [];
        if (!items.length) {
          var emptyLabel = spec.kind === 'projects' ? labels.emptyProjects : labels.emptyIssues;
          details.innerHTML = '<div class="px-2 py-2 text-sm text-gray-500">' + escapeHtml(emptyLabel) + '</div>';
        } else if (spec.kind === 'projects') {
          details.innerHTML = items.map(subRowHtml).join('');
        } else {
          details.innerHTML = issueListHtml(items);
        }
        details.setAttribute('data-loaded', '1');
        if (window.StatusColors) { window.StatusColors.apply(); }
      })
      .catch(function() {
        details.innerHTML = '<div class="px-2 py-2 text-sm text-red-500">' + escapeHtml(labels.error) + '</div>';
      });
  }

  // Delegated click handler for one Summary card container (e.g. #team-project-summary-cards
  // or #project-summary-view-cards). Rebinding is unnecessary across TaClientTable re-renders
  // since the listener lives on the container itself, not on the rows it replaces.
  // endpoints: { issue, projects } route paths. labels: { loading, error, emptyIssues,
  // emptyProjects } locale-backed strings — both supplied by the calling view.
  function initExpandableSummaryRows(containerId, viewId, endpoints, labels) {
    var container = document.getElementById(containerId);
    var viewEl = document.getElementById(viewId);
    if (!container || !viewEl) return;

    container.addEventListener('click', function(event) {
      // The whole row header is clickable (matching My Work Log's row-expand behavior) — not
      // just the chevron icon.
      var header = event.target.closest('.ts-row-header');
      if (!header) return;

      var rowEl = header.closest('.ts-expandable-row');
      var details = rowEl.querySelector(':scope > .ts-row-details');
      var chevron = header.querySelector('.ts-row-chevron');
      if (!details) return;

      var nowHidden = details.classList.toggle('hidden');
      var expanded = !nowHidden;
      if (chevron) chevron.classList.toggle('ts-row-chevron-open', expanded);

      if (expanded && details.getAttribute('data-loaded') !== '1') {
        loadRowDetails(rowEl, details, viewEl, endpoints, labels);
      }
    });
  }

  // Collapses every expanded row in a Summary card container, at any nesting depth — a nested
  // row (e.g. a Project sub-row under an Activity) is itself just another .ts-expandable-row,
  // so one flat querySelectorAll covers every level with no recursion needed. Already-fetched
  // .ts-row-details content is left in place (just hidden), matching the behavior of collapsing
  // a single row — re-expanding won't re-fetch.
  function collapseAllRows(containerId) {
    var container = document.getElementById(containerId);
    if (!container) return;
    container.querySelectorAll('.ts-expandable-row').forEach(function(rowEl) {
      var details = rowEl.querySelector(':scope > .ts-row-details');
      var chevron = rowEl.querySelector(':scope > .ts-row-header .ts-row-chevron');
      if (details) details.classList.add('hidden');
      if (chevron) chevron.classList.remove('ts-row-chevron-open');
    });
  }

  // options:
  //   getItems()          -> full array of plain data objects (already includes everything
  //                          renderRow needs, e.g. pre-rendered HTML fragments for links/badges)
  //   sortValue(item, field) -> comparable value for the given sort field
  //   renderRow(item, index) -> HTML string for one row/card (index = position in the full
  //                          sorted list, matches the pre-pagination bar-color cycling behavior)
  //   container            -> element whose innerHTML is replaced with the current page's rows
  //   paginationInfo       -> element to receive "(start-end/total)" text (optional)
  //   paginationLinks      -> element to receive prev/page/next controls (optional)
  //   perPage, sortField, sortDir -> initial state
  //   onRender(pageItems, allItems) -> called after each render (optional)
  //   dedupeKey(item)      -> optional; when given, items are reduced to one per key
  //                          (first occurrence wins) before sorting/paging, guarding
  //                          against any upstream data duplication
  function TaClientTable(options) {
    var state = {
      page: 1,
      perPage: options.perPage || 25,
      sortField: options.sortField || 'hours',
      sortDir: options.sortDir || 'desc'
    };

    function dedupedItems() {
      var items = options.getItems();
      if (!options.dedupeKey) { return items.slice(); }
      var seen = {};
      var result = [];
      items.forEach(function (item) {
        var key = options.dedupeKey(item);
        if (Object.prototype.hasOwnProperty.call(seen, key)) { return; }
        seen[key] = true;
        result.push(item);
      });
      return result;
    }

    function sortedItems() {
      var items = dedupedItems();
      items.sort(function (a, b) {
        var av = options.sortValue(a, state.sortField);
        var bv = options.sortValue(b, state.sortField);
        var r;
        if (typeof av === 'string' || typeof bv === 'string') {
          r = String(av == null ? '' : av).localeCompare(String(bv == null ? '' : bv), undefined, { sensitivity: 'base' });
        } else {
          r = (av || 0) - (bv || 0);
        }
        return state.sortDir === 'asc' ? r : -r;
      });
      return items;
    }

    function renderPaginationControls(total, totalPages, startIdx, endIdx) {
      if (options.paginationInfo) {
        options.paginationInfo.textContent = total ? ('(' + (startIdx + 1) + '-' + endIdx + '/' + total + ')') : '(0/0)';
      }
      var linksEl = options.paginationLinks;
      if (!linksEl) { return; }
      linksEl.innerHTML = '';
      if (totalPages <= 1) { return; }

      function addButton(label, page, isCurrent) {
        var el;
        if (isCurrent) {
          el = document.createElement('span');
          el.className = 'pagination-current';
        } else {
          el = document.createElement('a');
          el.href = 'javascript:void(0)';
          el.className = 'pagination-link';
          el.addEventListener('click', function () { state.page = page; render(); });
        }
        el.textContent = label;
        linksEl.appendChild(el);
        linksEl.appendChild(document.createTextNode(' '));
      }

      if (state.page > 1) { addButton('‹ Previous', state.page - 1, false); }
      var startPage = Math.max(state.page - 2, 1);
      var endPage = Math.min(state.page + 2, totalPages);
      for (var p = startPage; p <= endPage; p++) {
        addButton(String(p), p, p === state.page);
      }
      if (state.page < totalPages) { addButton('Next ›', state.page + 1, false); }
    }

    function render() {
      var items = sortedItems();
      var totalPages = Math.max(1, Math.ceil(items.length / state.perPage));
      state.page = Math.min(Math.max(state.page, 1), totalPages);
      var start = (state.page - 1) * state.perPage;
      var pageItems = items.slice(start, start + state.perPage);

      if (options.container) {
        options.container.innerHTML = pageItems.map(function (item, i) {
          return options.renderRow(item, start + i);
        }).join('');
      }
      if (options.onRender) { options.onRender(pageItems, items); }
      renderPaginationControls(items.length, totalPages, start, Math.min(start + state.perPage, items.length));
    }

    function setSort(field, defaultDir) {
      if (state.sortField === field) {
        state.sortDir = state.sortDir === 'asc' ? 'desc' : 'asc';
      } else {
        state.sortField = field;
        state.sortDir = defaultDir || 'desc';
      }
      state.page = 1;
      render();
    }

    function setPerPage(pp) {
      state.perPage = pp;
      state.page = 1;
      render();
    }

    return {
      render: render,
      setSort: setSort,
      setPerPage: setPerPage,
      getState: function () { return state; }
    };
  }

  function sortableThHtml(label, sortKey) {
    return '<button type="button" class="ta-col-sort inline-flex items-center gap-1" data-sort-key="' + sortKey + '">' +
      '<span>' + label + '</span><span class="ta-col-sort-ind text-[10px]"></span></button>';
  }

  // Client-side sort for a server-rendered (or already-in-DOM) <table> — no fetch, no full
  // re-render: reads each row's per-column data-sort-value and reorders the existing <tr>
  // elements in place. Pairs with the .ta-col-sort header buttons built by ta_sortable_th
  // (TimeAnalyticsHelper) / sortableThHtml above. Column identity is matched by data-sort-key,
  // so header and cell order don't need to line up positionally.
  function TaSortableTable(tableEl) {
    if (!tableEl) { return null; }
    // Rows already arrive in latest-to-oldest order (the existing default), so the period column
    // starts flagged as sorted "desc" without an initial sortBy() call actually reordering anything.
    var state = { key: 'period', dir: 'desc' };

    function headerButtons() {
      return Array.prototype.slice.call(tableEl.querySelectorAll('thead .ta-col-sort'));
    }

    function colIndexFor(key) {
      var ths = tableEl.querySelectorAll('thead th');
      for (var i = 0; i < ths.length; i++) {
        if (ths[i].querySelector('.ta-col-sort[data-sort-key="' + key + '"]')) { return i; }
      }
      return -1;
    }

    function updateIndicators() {
      headerButtons().forEach(function (btn) {
        var ind = btn.querySelector('.ta-col-sort-ind');
        if (!ind) { return; }
        ind.textContent = (btn.getAttribute('data-sort-key') === state.key) ? (state.dir === 'asc' ? '▲' : '▼') : '';
      });
    }

    function sortBy(key) {
      var idx = colIndexFor(key);
      if (idx === -1) { return; }

      if (state.key === key) {
        state.dir = state.dir === 'asc' ? 'desc' : 'asc';
      } else {
        state.key = key;
        state.dir = 'asc';
      }

      var tbody = tableEl.querySelector('tbody');
      if (!tbody) { return; }
      var rows = Array.prototype.slice.call(tbody.children);
      var dir = state.dir === 'asc' ? 1 : -1;

      // Strict numeric test (not parseFloat's lenient prefix-parsing) - parseFloat("2026-11-24")
      // silently returns 2026, which made every same-year date "equal" and never reorder.
      function isNumeric(v) { return v != null && /^-?\d+(\.\d+)?$/.test(String(v).trim()); }

      rows.sort(function (a, b) {
        var aCell = a.children[idx];
        var bCell = b.children[idx];
        var av = aCell ? aCell.getAttribute('data-sort-value') : null;
        var bv = bCell ? bCell.getAttribute('data-sort-value') : null;
        var cmp = (isNumeric(av) && isNumeric(bv))
          ? (parseFloat(av) - parseFloat(bv))
          : String(av == null ? '' : av).localeCompare(String(bv == null ? '' : bv), undefined, { numeric: true, sensitivity: 'base' });
        return cmp * dir;
      });

      rows.forEach(function (row) { tbody.appendChild(row); });
      updateIndicators();
    }

    headerButtons().forEach(function (btn) {
      btn.addEventListener('click', function () { sortBy(btn.getAttribute('data-sort-key')); });
    });

    updateIndicators();

    return { sortBy: sortBy };
  }

  // Auto-wires every sortable pivot table already in the page on load (My Time / My Team
  // Detailed tables). Tables rendered later client-side (the Activity "Grouped" tab, rebuilt on
  // every Customize-groups Apply) re-call TaSortableTable themselves after each re-render — see
  // team_activity_groups.js.
  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('.ta-sortable-table').forEach(function (table) { TaSortableTable(table); });
  });

  // Keeps each .ta-analysis-donut aside's height matched to its sibling .ta-analysis-table, so
  // a taller donut (chart + legend) never stretches the table box and leaves unused blank space
  // beneath the table's own (often shorter) content — the table drives the shared height, never
  // the donut (see .ta-analysis-layout { align-items: flex-start } in time_analytics.css).
  // Self-contained: found generically via class name, so neither dashboard's own script needs
  // to call this. ResizeObserver re-syncs automatically after anything that changes the table's
  // height (pagination, sort, expand/collapse, a per-page reload) with no per-call-site hook.
  function initDonutHeightSync() {
    var layouts = Array.prototype.slice.call(document.querySelectorAll('.ta-analysis-layout'));
    if (!layouts.length) return;

    var narrowQuery = window.matchMedia('(max-width: 1123px)');

    function sync(layoutEl) {
      var table = layoutEl.querySelector(':scope > .ta-analysis-table');
      var donut = layoutEl.querySelector(':scope > .ta-analysis-donut');
      if (!table || !donut) return;
      // Below the stacked-layout breakpoint, table and donut are separate rows, not
      // side-by-side, so let the donut use its own natural height instead.
      donut.style.height = narrowQuery.matches ? '' : table.offsetHeight + 'px';
    }

    function syncAll() { layouts.forEach(sync); }

    syncAll();

    if (typeof ResizeObserver !== 'undefined') {
      var observer = new ResizeObserver(function (entries) {
        entries.forEach(function (entry) {
          var layoutEl = entry.target.closest('.ta-analysis-layout');
          if (layoutEl) sync(layoutEl);
        });
      });
      layouts.forEach(function (layoutEl) {
        var table = layoutEl.querySelector(':scope > .ta-analysis-table');
        if (table) observer.observe(table);
      });
    }

    if (narrowQuery.addEventListener) { narrowQuery.addEventListener('change', syncAll); }
    else if (narrowQuery.addListener) { narrowQuery.addListener(syncAll); }
  }

  document.addEventListener('DOMContentLoaded', initDonutHeightSync);

  global.TaClientTable = TaClientTable;
  global.TaSortableTable = TaSortableTable;
  global.taHexToRgba = hexToRgba;
  global.taShareBadgeHtml = shareBadgeHtml;
  global.taLockedBadgeHtml = lockedBadgeHtml;
  global.taSortableThHtml = sortableThHtml;
  global.taFormatHours = formatHours;
  global.taEscapeHtml = escapeHtml;
  global.taChevronIconHtml = chevronIconHtml;
  global.taIssueRowHtml = issueRowHtml;
  global.taIssueListHtml = issueListHtml;
  global.taExpandableSummaryCardHtml = expandableSummaryCardHtml;
  global.taSubRowHtml = subRowHtml;
  global.taInitExpandableSummaryRows = initExpandableSummaryRows;
  global.taCollapseAllRows = collapseAllRows;
})(window);
