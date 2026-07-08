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

  global.TaClientTable = TaClientTable;
  global.TaSortableTable = TaSortableTable;
  global.taHexToRgba = hexToRgba;
  global.taShareBadgeHtml = shareBadgeHtml;
  global.taLockedBadgeHtml = lockedBadgeHtml;
  global.taSortableThHtml = sortableThHtml;
  global.taFormatHours = formatHours;
  global.taEscapeHtml = escapeHtml;
})(window);
