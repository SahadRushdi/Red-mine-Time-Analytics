// Shared Chart.js v2 helpers for the Time Analytics / Team Analytics dashboards:
// - monthYearSeparator: draws a dashed vertical line at daily-grouping month/year boundaries.
// - TaChartPlugins.applyHolidayLegend: adds a "Weekend / Leave" legend entry to Trend charts.
// - TaChartPlugins.renderChartLegend: renders a scrollable DOM legend for Stacked (bar) charts.
(function () {
  'use strict';

  if (typeof Chart !== 'undefined' && Chart.plugins && Chart.plugins.register) {
    Chart.plugins.register({
      id: 'monthYearSeparator',
      afterDraw: function (chart) {
        var opts = chart.options && chart.options.monthYearSeparator;
        var boundaries = opts && opts.boundaries;
        if (!boundaries || !boundaries.length) return;

        var scale = chart.scales && chart.scales['x-axis-0'];
        if (!scale || typeof scale.getPixelForTick !== 'function') return;

        var ctx = chart.ctx;
        var top = chart.chartArea.top;
        var bottom = chart.chartArea.bottom;

        ctx.save();
        boundaries.forEach(function (boundary) {
          var x = scale.getPixelForTick(boundary.index);
          if (typeof x !== 'number' || isNaN(x)) return;

          ctx.beginPath();
          ctx.setLineDash([4, 4]);
          ctx.lineWidth = 1;
          ctx.strokeStyle = '#1d4ed8';
          ctx.moveTo(x, top);
          ctx.lineTo(x, bottom);
          ctx.stroke();
        });
        ctx.restore();
      }
    });
  }

  function applyHolidayLegend(config) {
    if (!config || config.type !== 'line') return;
    var dataset = config.data && config.data.datasets && config.data.datasets[0];
    if (!dataset) return;

    config.options = config.options || {};
    config.options.legend = config.options.legend || {};
    config.options.legend.labels = config.options.legend.labels || {};

    // The Trend chart legend is purely informational - toggling the single "Hours" line (or
    // the synthetic "Weekend / Leave" swatch) off isn't a meaningful interaction, so disable
    // legend clicking (and the pointer-cursor hover feedback that implies it's clickable)
    // entirely for line charts.
    config.options.legend.onClick = function () {};
    config.options.legend.onHover = function () {};

    var hasHolidays = Array.isArray(dataset.holidayFlags) && dataset.holidayFlags.indexOf(true) !== -1;
    if (!hasHolidays) return;

    config.options.legend.display = true;

    config.options.legend.labels.generateLabels = function (chart) {
      var ds = chart.data.datasets[0];
      var color = ds.borderColor || '#36a2eb';
      return [
        {
          text: ds.label || 'Hours',
          fillStyle: color,
          strokeStyle: color,
          pointStyle: 'circle',
          hidden: false,
          datasetIndex: 0
        },
        {
          text: 'Weekend / Leave',
          fillStyle: '#f59e0b',
          strokeStyle: '#f59e0b',
          pointStyle: 'circle',
          hidden: false,
          datasetIndex: 1
        }
      ];
    };
  }

  // Renders a scrollable DOM legend (outside the canvas) for Stacked (bar) charts, so the
  // legend list can scroll vertically instead of squeezing the chart's plot area or getting
  // clipped by a fixed-height container. Mirrors the click-to-toggle-dataset behaviour of
  // Chart.js's own legend.
  function renderChartLegend(chart, containerId) {
    var legendContainer = document.getElementById(containerId);
    if (!legendContainer || !chart || !chart.data || !chart.data.datasets) return;

    legendContainer.innerHTML = '';
    var list = document.createElement('div');
    list.className = 'flex flex-wrap gap-x-4 gap-y-2 justify-start';

    chart.data.datasets.forEach(function (dataset, index) {
      var item = document.createElement('div');
      item.className = 'flex items-center gap-2 py-1 px-2 rounded-lg hover:bg-gray-50 cursor-pointer transition-all duration-200 group';
      item.style.border = '1px solid transparent';
      item.style.flex = '1 0 30%';
      item.style.minWidth = '140px';

      // dataset.backgroundColor may still be unset here when a chart relies on the
      // chartjs-plugin-colorschemes plugin for its colors (e.g. the Individual dashboard's
      // Stacked chart) rather than setting it directly in Ruby, so fall back to the actual
      // rendered color on the first bar/segment of this dataset.
      var meta = chart.getDatasetMeta(index);
      var renderedColor = meta && meta.data && meta.data[0] && meta.data[0]._model
        ? meta.data[0]._model.backgroundColor
        : null;
      var color = dataset.backgroundColor || renderedColor || '#6b7280';

      var colorBox = document.createElement('div');
      colorBox.className = 'w-3 h-3 rounded-sm flex-shrink-0 transition-opacity';
      colorBox.style.backgroundColor = color;

      var label = document.createElement('span');
      label.className = 'text-[12px] font-medium text-gray-700 truncate group-hover:text-blue-600 transition-colors';
      label.textContent = dataset.label;

      item.appendChild(colorBox);
      item.appendChild(label);

      item.onclick = function () {
        var meta = chart.getDatasetMeta(index);
        meta.hidden = meta.hidden === null ? !chart.data.datasets[index].hidden : null;

        if (meta.hidden) {
          item.classList.add('opacity-40');
          label.classList.add('line-through');
        } else {
          item.classList.remove('opacity-40');
          label.classList.remove('line-through');
        }

        chart.update();
      };

      if (meta.hidden) {
        item.classList.add('opacity-40');
        label.classList.add('line-through');
      }

      list.appendChild(item);
    });

    legendContainer.appendChild(list);
  }

  window.TaChartPlugins = {
    applyHolidayLegend: applyHolidayLegend,
    renderChartLegend: renderChartLegend
  };
})();
