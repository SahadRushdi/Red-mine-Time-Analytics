// Pure computation + rendering helpers for the Team Dashboard's Activity "Grouped" tab and its
// session-only "Customize groups" popup. Kept framework-free and DOM-scoped-by-argument (no
// references to the page's other inline globals) so it loads safely in <head>, well before the
// big inline <script> block (further down team_analytics/index.html.erb) that defines
// TEAM_VIEW_CONFIG/showDetailedView/etc. That inline script wires these functions together with
// the rest of the page's existing view-toggle/chart infrastructure.
(function (window) {
  'use strict';

  var UNGROUPED_KEY = '__ungrouped__';

  // Re-buckets the raw per-activity matrix (from the embedded #team-activity-group-payload) into
  // a per-group matrix, mirroring TeamAnalyticsController#regroup_activity_pivot exactly so the
  // client can recompute an identical result after a session-only "Customize groups" edit.
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

    // Always shown, like named groups (mirrors TeamAnalyticsController#regroup_activity_pivot) —
    // otherwise the column vanishes whenever nobody has logged time to an unassigned activity yet.
    activities.push({ id: UNGROUPED_KEY, name: payload.ungroupedName || 'Ungrouped', color: payload.ungroupedColor || '#9CA3AF' });

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
        escapeHtml(a.name) + '</th>';
    }).join('');

    var rows = pagePeriods.map(function (periodKey, i) {
      var rowTotal = pivot.periodTotals[periodKey] || 0;
      var cells = pivot.activities.map(function (a) {
        var hours = (pivot.matrix[periodKey] && pivot.matrix[periodKey][a.id]) || 0;
        var percentage = rowTotal > 0 ? (hours / rowTotal * 100) : 0;
        var text = hours > 0 ? (formatHours(hours) + ' ' + Math.round(percentage) + '%') : '—';
        return '<td class="px-6 py-4 text-center text-gray-900">' +
          '<div class="flex flex-col items-center gap-1"><span>' + text + '</span>' +
          '<div class="h-1.5 w-full bg-gray-200 rounded-full overflow-hidden">' +
          '<div class="h-full rounded-full transition-all duration-300" style="width: ' + percentage + '%; background-color: ' + a.color + ';"></div>' +
          '</div></div></td>';
      }).join('');

      return '<tr class="bg-white border-b hover:bg-gray-50">' +
        '<td class="px-6 py-4 font-medium text-gray-900 whitespace-nowrap">' + escapeHtml(pageLabels[i]) + '</td>' +
        cells +
        '<td class="px-6 py-4 text-right font-semibold text-gray-900">' + formatHours(rowTotal) + '</td>' +
        '</tr>';
    }).join('');

    return '<table class="w-full text-sm text-left text-gray-500">' +
      '<thead class="text-sm text-gray-700 bg-gray-50"><tr>' +
      '<th scope="col" class="px-6 py-3 border-r-2 border-gray-300">' + escapeHtml(periodLabel) + '</th>' +
      theadCells +
      '<th scope="col" class="px-6 py-3 text-right border-l-2 border-gray-300 font-bold">Hours</th>' +
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

  window.TeamActivityGroups = {
    computeGroupedPivot: computeGroupedPivot,
    renderGroupedTableHtml: renderGroupedTableHtml,
    buildDonutDatasets: buildDonutDatasets,
    buildStackedBarChartData: buildStackedBarChartData
  };
})(window);
