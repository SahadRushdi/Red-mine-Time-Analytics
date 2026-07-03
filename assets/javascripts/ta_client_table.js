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
  function TaClientTable(options) {
    var state = {
      page: 1,
      perPage: options.perPage || 25,
      sortField: options.sortField || 'hours',
      sortDir: options.sortDir || 'desc'
    };

    function sortedItems() {
      var items = options.getItems().slice();
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

  global.TaClientTable = TaClientTable;
  global.taHexToRgba = hexToRgba;
  global.taShareBadgeHtml = shareBadgeHtml;
  global.taFormatHours = formatHours;
  global.taEscapeHtml = escapeHtml;
})(window);
