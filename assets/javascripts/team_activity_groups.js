// Pure computation + rendering helpers, plus a reusable page-wiring factory, for the Activity
// "Grouped" tab and its session-only "Customize groups" popup — shared by the Team Dashboard
// (team_analytics/index.html.erb) and the Individual Dashboard (individual_dashboard.html.erb).
// Kept framework-free and DOM-scoped-by-argument (no references to either page's other inline
// globals) so it loads safely in <head>, well before each page's big inline <script> block that
// wires it together with that page's existing view-toggle/chart infrastructure.
(function (window) {
  'use strict';

  var UNGROUPED_KEY = '__ungrouped__';

  // Re-buckets the raw per-activity matrix (from the embedded payload) into a per-group matrix,
  // mirroring TaActivityGroup.regroup_activity_pivot exactly so the client can recompute an
  // identical result after a session-only "Customize groups" edit.
  //
  // groupsInOrder: [{ id, name, color }] in the desired column order (server defaults, or the
  //                Customize-groups popup's working copy after Apply)
  // assignments:   { activityId(string): groupId(string)|null }
  function computeGroupedPivot(payload, groupsInOrder, assignments) {
    var matrix = {};
    payload.rawPeriods.forEach(function (period) { matrix[period] = {}; });

    payload.rawPeriods.forEach(function (period) {
      var byActivity = payload.matrix[period] || {};
      Object.keys(byActivity).forEach(function (activityName) {
        var hours = byActivity[activityName] || 0;
        var activityId = payload.activityIds[activityName];
        var groupId = activityId !== null && activityId !== undefined ? assignments[String(activityId)] : null;
        var bucket = (groupId !== null && groupId !== undefined) ? String(groupId) : UNGROUPED_KEY;
        matrix[period][bucket] = (matrix[period][bucket] || 0) + hours;
      });
    });

    var activities = groupsInOrder.map(function (g) {
      return { id: String(g.id), name: g.name, color: g.color };
    });

    // Only shown when it actually has hours in it (mirrors TaActivityGroup.regroup_activity_pivot) —
    // an empty Ungrouped column is just noise.
    var ungroupedTotal = 0;
    payload.rawPeriods.forEach(function (period) {
      ungroupedTotal += (matrix[period] && matrix[period][UNGROUPED_KEY]) || 0;
    });
    if (ungroupedTotal > 0) {
      activities.push({ id: UNGROUPED_KEY, name: payload.ungroupedName || 'Ungrouped', color: payload.ungroupedColor || '#9CA3AF' });
    }

    var periodTotals = {};
    var groupTotals = {};
    activities.forEach(function (a) { groupTotals[a.id] = 0; });

    payload.rawPeriods.forEach(function (period) {
      var total = 0;
      activities.forEach(function (a) {
        var hours = matrix[period][a.id] || 0;
        total += hours;
        groupTotals[a.id] += hours;
      });
      periodTotals[period] = total;
    });

    return { activities: activities, matrix: matrix, periodTotals: periodTotals, groupTotals: groupTotals };
  }

  function escapeHtml(str) {
    return String(str == null ? '' : str).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  // Rebuilds the Grouped pivot table's full <table> markup client-side, in the same visual shape
  // as the server-rendered partial (_activity_period_pivot_table.html.erb, show_bars: true).
  // Uses the payload's most-recent-first arrays (displayRawPeriods/displayPeriodDisplay) — not
  // rawPeriods/periodDisplay, which stay chronological for the Stacked chart (buildStackedBarChartData).
  function renderGroupedTableHtml(pivot, payload, periodLabel, formatHours) {
    var displayRawPeriods = payload.displayRawPeriods || payload.rawPeriods;
    var displayPeriodDisplay = payload.displayPeriodDisplay || payload.periodDisplay;
    var offset = payload.offset || 0;
    var limit = payload.limit || displayRawPeriods.length;
    var pagePeriods = displayRawPeriods.slice(offset, offset + limit);
    var pageLabels = displayPeriodDisplay.slice(offset, offset + limit);

    var theadCells = pivot.activities.map(function (a) {
      return '<th scope="col" class="px-6 py-3 text-center border-r border-gray-200">' +
        '<span style="display:inline-block;width:8px;height:8px;border-radius:9999px;margin-right:6px;background-color:' + a.color + ';"></span>' +
        window.taSortableThHtml(escapeHtml(a.name), a.name) + '</th>';
    }).join('');

    var rows = pagePeriods.map(function (periodKey, i) {
      var rowTotal = pivot.periodTotals[periodKey] || 0;
      var cells = pivot.activities.map(function (a) {
        var hours = (pivot.matrix[periodKey] && pivot.matrix[periodKey][a.id]) || 0;
        var percentage = rowTotal > 0 ? (hours / rowTotal * 100) : 0;
        var cellHtml = hours > 0
          ? '<div class="flex items-center justify-center gap-2"><span class="font-bold text-gray-900">' +
            formatHours(hours) + '</span>' + window.taShareBadgeHtml(a.color, percentage) + '</div>'
          : '<span class="text-gray-400">—</span>';
        return '<td class="px-6 py-4 text-center text-gray-900" data-sort-value="' + hours + '">' + cellHtml + '</td>';
      }).join('');

      return '<tr class="bg-white border-b hover:bg-gray-50">' +
        '<td class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap" data-sort-value="' + escapeHtml(periodKey) + '">' + escapeHtml(pageLabels[i]) + '</td>' +
        cells +
        '<td class="px-6 py-4 text-right font-semibold text-gray-900" data-sort-value="' + rowTotal + '">' + formatHours(rowTotal) + '</td>' +
        '</tr>';
    }).join('');

    return '<table class="w-full text-sm text-left text-gray-500 ta-sortable-table">' +
      '<thead class="text-sm text-gray-700 bg-gray-50"><tr>' +
      '<th scope="col" class="px-6 py-3 border-r-2 border-gray-300">' + window.taSortableThHtml(escapeHtml(periodLabel), 'period') + '</th>' +
      theadCells +
      '<th scope="col" class="px-6 py-3 text-right border-l-2 border-gray-300 font-bold">' + window.taSortableThHtml('Hours', 'total') + '</th>' +
      '</tr></thead><tbody>' + rows + '</tbody></table>';
  }

  // labels/values/colors for the donut chart, ordered by descending hours (matches
  // initTeamDonutChart's existing activity/project sort convention).
  function buildDonutDatasets(pivot, formatHours) {
    var entries = pivot.activities
      .map(function (a) { return { name: a.name, hours: pivot.groupTotals[a.id] || 0, color: a.color }; })
      .filter(function (e) { return e.hours > 0; })
      .sort(function (a, b) { return b.hours - a.hours; });

    return {
      labels: entries.map(function (e) { return e.name; }),
      values: entries.map(function (e) { return e.hours; }),
      colors: entries.map(function (e) { return e.color; }),
      total: entries.reduce(function (sum, e) { return sum + e.hours; }, 0)
    };
  }

  // Chart.js v2 stacked-bar dataset, one series per group, matching
  // TeamAnalyticsController#generate_stacked_bar_chart_from_matrix's shape (stack: 'stack0').
  function buildStackedBarChartData(pivot, payload) {
    var offset = payload.offset || 0;
    var limit = payload.limit || payload.rawPeriods.length;
    var pagePeriods = payload.rawPeriods; // Trend/Stacked chart always plots the full range, not just the current page
    var pageLabels = payload.periodDisplay;

    var datasets = pivot.activities.map(function (a) {
      return {
        label: a.name,
        data: pagePeriods.map(function (p) { return (pivot.matrix[p] && pivot.matrix[p][a.id]) || 0; }),
        backgroundColor: a.color,
        stack: 'stack0'
      };
    });

    return { labels: pageLabels, datasets: datasets };
  }

  // Chart.js v2 callback used by both dashboards when the Grouped tab rebuilds the stacked
  // chart in the browser. The rebuilt datasets contain decimal hours for plotting, so format
  // only the tooltip text to match the H:MM convention used throughout the dashboards.
  function buildStackedBarTooltipCallbacks(formatHours) {
    return {
      label: function (tooltipItem, data) {
        if (!tooltipItem || !data || !data.datasets) return '';

        var dataset = data.datasets[tooltipItem.datasetIndex];
        if (!dataset) return '';

        var label = dataset.label || '';
        var value = tooltipItem.yLabel !== undefined
          ? tooltipItem.yLabel
          : (dataset.data && dataset.data[tooltipItem.index]);

        return value === undefined ? label : label + ': ' + formatHours(value);
      }
    };
  }

  // Wires up the Activity "Grouped" tab + "Customize groups" popup for a page, on top of the pure
  // functions above. Both the Team Dashboard and Individual Dashboard call this with their own
  // element ids/callbacks (chart internals — canvas ids, Chart.js instance globals — differ per
  // page, so chart (re)rendering itself is always delegated back to the caller).
  //
  // config:
  //   payloadElementId, groupedViewElementId, detailedViewElementId, summaryViewElementId,
  //   groupedButtonId, detailedButtonId, summaryButtonId, customizeWrapperId,
  //   paginationBarId, sortButtonsId (optional), hiddenFieldId, localStorageKey,
  //   modalElementId (default 'customize-groups-modal'), boardElementId (default 'customize-groups-board'),
  //   resetButtonId (default 'customize-groups-reset-btn'), applyButtonId (default 'customize-groups-apply-btn'),
  //   formatHours(hours), setButtonActive(buttonEl, isActive),
  //   renderCharts(pivot, payload) — update donut/bar charts for the grouped totals,
  //   showNoGroupsCharts() — swap chart area to the "no groups configured" empty state,
  //   restoreDefaultCharts() — re-show the original (ungrouped) charts, called when leaving Grouped.
  function createGroupedActivityController(config) {
    var modalElementId = config.modalElementId || 'customize-groups-modal';
    var boardElementId = config.boardElementId || 'customize-groups-board';
    var resetButtonId = config.resetButtonId || 'customize-groups-reset-btn';
    var applyButtonId = config.applyButtonId || 'customize-groups-apply-btn';

    var payloadEl = document.getElementById(config.payloadElementId);
    var payload = payloadEl ? JSON.parse(payloadEl.getAttribute('data-payload')) : null;
    var customGroupState = null;
    var modal = null;
    var board = null;

    function currentGroupsAndAssignments() {
      if (customGroupState) { return customGroupState; }
      return { groups: payload.groups, assignments: payload.assignments };
    }

    function computeCurrentPivot() {
      var gs = currentGroupsAndAssignments();
      return computeGroupedPivot(payload, gs.groups, gs.assignments);
    }

    function renderTableFromPivot(pivot) {
      var container = document.getElementById(config.groupedViewElementId);
      if (!container || !payload) return;
      var periodLabel = payload.periodColumnLabel || '';
      container.innerHTML = renderGroupedTableHtml(pivot, payload, periodLabel, config.formatHours);
      // Replacing innerHTML drops any previous TaSortableTable listeners, so re-wire the fresh table.
      if (window.TaSortableTable) { window.TaSortableTable(container.querySelector('table')); }
    }

    function renderNoGroupsState() {
      var tableContainer = document.getElementById(config.groupedViewElementId);
      if (tableContainer) {
        tableContainer.innerHTML = '<div class="px-6 py-8 text-center"><p class="text-sm text-gray-500">' +
          escapeHtml(config.noGroupsMessage || 'No activity groups have been set up yet.') + '</p></div>';
      }
      if (config.showNoGroupsCharts) { config.showNoGroupsCharts(); }
      var paginationBar = config.paginationBarId && document.getElementById(config.paginationBarId);
      if (paginationBar) paginationBar.style.display = 'none';
    }

    function rebuildForGroups() {
      if (!payload) return;
      var gs = currentGroupsAndAssignments();

      if (!gs.groups.length) {
        renderNoGroupsState();
        return;
      }

      var paginationBar = config.paginationBarId && document.getElementById(config.paginationBarId);
      if (paginationBar) paginationBar.style.display = '';

      var pivot = computeCurrentPivot();
      renderTableFromPivot(pivot);
      if (config.renderCharts) { config.renderCharts(pivot, payload); }
    }

    function hide() {
      var gv = document.getElementById(config.groupedViewElementId);
      if (gv) gv.style.display = 'none';
      config.setButtonActive(document.getElementById(config.groupedButtonId), false);
      var wrapper = document.getElementById(config.customizeWrapperId);
      if (wrapper) wrapper.style.display = 'none';
      if (config.onHide) { config.onHide(); }
    }

    function show(options) {
      var grouped = document.getElementById(config.groupedViewElementId);
      if (!grouped) return;
      var detailed = document.getElementById(config.detailedViewElementId);
      var summary = document.getElementById(config.summaryViewElementId);
      if (detailed) detailed.style.display = 'none';
      if (summary) summary.style.display = 'none';
      grouped.style.display = 'block';

      config.setButtonActive(document.getElementById(config.summaryButtonId), false);
      config.setButtonActive(document.getElementById(config.detailedButtonId), false);
      config.setButtonActive(document.getElementById(config.groupedButtonId), true);

      if (config.sortButtonsId) {
        var sortButtons = document.getElementById(config.sortButtonsId);
        if (sortButtons) sortButtons.style.display = 'none';
      }

      var wrapper = document.getElementById(config.customizeWrapperId);
      if (wrapper) wrapper.style.display = '';

      var hiddenField = document.getElementById(config.hiddenFieldId);
      if (hiddenField) hiddenField.value = 'grouped';
      if (!(options && options.persist === false) && config.localStorageKey) {
        localStorage.setItem(config.localStorageKey, 'grouped');
      }

      if (config.onShow) { config.onShow(); }

      rebuildForGroups();
    }

    function restoreIfSaved() {
      if (!config.localStorageKey) return false;
      if (localStorage.getItem(config.localStorageKey) !== 'grouped') return false;
      show({ persist: false });
      return true;
    }

    function openCustomizeModal() {
      if (!payload || !modal) return;

      var gs = currentGroupsAndAssignments();
      var activities = payload.allActivities || [];

      var boardEl = document.getElementById(boardElementId);
      boardEl.innerHTML = '';
      board = TaActivityGroupBoard(boardEl, {
        groups: gs.groups,
        activities: activities,
        assignments: gs.assignments,
        ungroupedColor: payload.ungroupedColor,
        persistImmediately: false
      });

      modal.show();
    }

    document.addEventListener('DOMContentLoaded', function () {
      var modalEl = document.getElementById(modalElementId);
      if (modalEl && typeof Modal !== 'undefined') {
        modal = new Modal(modalEl, {
          placement: 'center',
          backdrop: 'dynamic',
          backdropClasses: 'bg-gray-900/50 fixed inset-0 z-40',
          closable: true
        });
      }

      var resetBtn = document.getElementById(resetButtonId);
      if (resetBtn) {
        resetBtn.addEventListener('click', function () {
          if (!board || !payload) return;
          board.reset(payload.groups, payload.assignments);
        });
      }

      var applyBtn = document.getElementById(applyButtonId);
      if (applyBtn) {
        applyBtn.addEventListener('click', function () {
          if (!board) return;
          customGroupState = board.getState();
          rebuildForGroups();
          if (modal) modal.hide();
        });
      }

      var closeBtn = document.getElementById('customize-groups-close-btn');
      if (closeBtn) {
        closeBtn.addEventListener('click', function () {
          if (modal) modal.hide();
        });
      }
    });

    return {
      show: show,
      hide: hide,
      restoreIfSaved: restoreIfSaved,
      openCustomizeModal: openCustomizeModal
    };
  }

  window.TeamActivityGroups = {
    computeGroupedPivot: computeGroupedPivot,
    renderGroupedTableHtml: renderGroupedTableHtml,
    buildDonutDatasets: buildDonutDatasets,
    buildStackedBarChartData: buildStackedBarChartData,
    buildStackedBarTooltipCallbacks: buildStackedBarTooltipCallbacks,
    createGroupedActivityController: createGroupedActivityController
  };
})(window);
