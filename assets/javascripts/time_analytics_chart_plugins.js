// Shared Chart.js v2 helpers for the Time Analytics / Team Analytics dashboards:
// - monthYearSeparator: draws a dashed vertical line at daily-grouping month/year boundaries.
// - TaChartPlugins.applyHolidayLegend: adds a "Weekend / Leave" legend entry to Trend charts.
// - TaChartPlugins.renderChartLegend: renders a horizontally scrollable DOM legend for Stacked
//   (bar) charts, where clicking an entry highlights that dataset instead of hiding it.
(function () {
  'use strict';

  var DIMMED_ALPHA = 0.15;

  // Re-expresses a color as rgba() with the given alpha so non-highlighted datasets can be
  // faded while keeping their hue. Chart.js/colorschemes hand us either hex or rgb(a) strings;
  // anything else (named colors, gradients) is left untouched.
  function fadeColor(color, alpha) {
    if (typeof color !== 'string') return color;

    var hex = color.trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
    if (hex) {
      var digits = hex[1];
      if (digits.length === 3) {
        digits = digits[0] + digits[0] + digits[1] + digits[1] + digits[2] + digits[2];
      }
      var value = parseInt(digits, 16);
      return 'rgba(' + [(value >> 16) & 255, (value >> 8) & 255, value & 255].join(', ') + ', ' + alpha + ')';
    }

    var rgb = color.trim().match(/^rgba?\(([^)]+)\)$/i);
    if (rgb) {
      var parts = rgb[1].split(',');
      if (parts.length < 3) return color;
      return 'rgba(' + parts[0].trim() + ', ' + parts[1].trim() + ', ' + parts[2].trim() + ', ' + alpha + ')';
    }

    return color;
  }

  if (typeof Chart !== 'undefined' && Chart.plugins && Chart.plugins.register) {
    // Repaints bar colors on every draw from the base colors captured by renderChartLegend, so
    // the highlight survives hover-triggered re-renders (which redraw without recomputing the
    // element models). When nothing is highlighted the models are left alone, letting Chart.js
    // restore the original colors on its next update.
    Chart.plugins.register({
      id: 'taLegendHighlight',
      beforeDraw: function (chart) {
        var state = chart.$taLegendHighlight;
        if (!state || state.highlighted === null) return;

        chart.data.datasets.forEach(function (dataset, index) {
          var base = state.baseColors[index];
          if (!base) return;

          var meta = chart.getDatasetMeta(index);
          if (!meta || !meta.data) return;

          var color = index === state.highlighted ? base : fadeColor(base, DIMMED_ALPHA);
          meta.data.forEach(function (element) {
            if (element._model) element._model.backgroundColor = color;
          });
        });
      }
    });

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

  // Renders a single-row DOM legend (outside the canvas) for Stacked (bar) charts. The row
  // scrolls horizontally via the ‹/› buttons, which stay hidden when every entry already fits.
  // Clicking an entry highlights that dataset and fades the rest (click again to clear), which
  // reads better on a stacked bar than Chart.js's default hide-the-dataset behaviour.
  function renderChartLegend(chart, containerId) {
    var legendContainer = document.getElementById(containerId);
    if (!legendContainer || !chart || !chart.data || !chart.data.datasets) return;

    // dataset.backgroundColor may still be unset here when a chart relies on the
    // chartjs-plugin-colorschemes plugin for its colors (e.g. the Individual dashboard's
    // Stacked chart) rather than setting it directly in Ruby, so fall back to the actual
    // rendered color on the first bar/segment of this dataset.
    var baseColors = chart.data.datasets.map(function (dataset, index) {
      var meta = chart.getDatasetMeta(index);
      var renderedColor = meta && meta.data && meta.data[0] && meta.data[0]._model
        ? meta.data[0]._model.backgroundColor
        : null;
      return dataset.backgroundColor || renderedColor || '#6b7280';
    });

    chart.$taLegendHighlight = { highlighted: null, baseColors: baseColors };

    legendContainer.innerHTML = '';

    var track = document.createElement('div');
    track.className = 'ta-legend-track';

    var prev = buildNavButton('prev');
    var next = buildNavButton('next');
    var items = [];

    chart.data.datasets.forEach(function (dataset, index) {
      var item = document.createElement('button');
      item.type = 'button';
      item.className = 'ta-legend-item';

      var swatch = document.createElement('span');
      swatch.className = 'ta-legend-swatch';
      swatch.style.backgroundColor = baseColors[index];

      var label = document.createElement('span');
      label.className = 'ta-legend-label';
      label.textContent = dataset.label;

      item.appendChild(swatch);
      item.appendChild(label);

      item.onclick = function () {
        var state = chart.$taLegendHighlight;
        state.highlighted = state.highlighted === index ? null : index;
        items.forEach(function (other, otherIndex) {
          other.classList.toggle('is-active', state.highlighted === otherIndex);
          other.classList.toggle('is-dimmed', state.highlighted !== null && state.highlighted !== otherIndex);
        });
        chart.update();
      };

      items.push(item);
      track.appendChild(item);
    });

    legendContainer.appendChild(prev);
    legendContainer.appendChild(track);
    legendContainer.appendChild(next);

    setupLegendScrolling(legendContainer, track, prev, next);
  }

  function buildNavButton(direction) {
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'ta-legend-nav';
    button.hidden = true;
    button.setAttribute('aria-label', direction === 'prev' ? 'Scroll legend left' : 'Scroll legend right');
    button.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" ' +
      'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      (direction === 'prev' ? '<polyline points="15 18 9 12 15 6"/>' : '<polyline points="9 18 15 12 9 6"/>') +
      '</svg>';
    return button;
  }

  function setupLegendScrolling(legendContainer, track, prev, next) {
    function step() {
      return Math.max(track.clientWidth * 0.8, 120);
    }

    prev.onclick = function () { track.scrollBy({ left: -step(), behavior: 'smooth' }); };
    next.onclick = function () { track.scrollBy({ left: step(), behavior: 'smooth' }); };

    function sync() {
      // Sub-pixel track widths make an exact comparison report a 1px overflow on legends that
      // visually fit, so only treat a couple of pixels of overflow as scrollable.
      var scrollable = track.scrollWidth - track.clientWidth > 2;
      prev.hidden = !scrollable;
      next.hidden = !scrollable;
      if (!scrollable) return;

      prev.disabled = track.scrollLeft <= 1;
      next.disabled = track.scrollLeft >= track.scrollWidth - track.clientWidth - 1;
    }

    track.onscroll = sync;

    // A re-render replaces the buttons but not the container, so drop the previous listener
    // (which now points at detached nodes) before registering this render's.
    if (legendContainer.__taLegendResize) {
      window.removeEventListener('resize', legendContainer.__taLegendResize);
    }
    legendContainer.__taLegendResize = sync;
    window.addEventListener('resize', sync);

    sync();
    // The legend can be measured before layout settles (hidden tab, font swap), so re-check
    // once the browser has painted.
    window.requestAnimationFrame(sync);
  }

  window.TaChartPlugins = {
    applyHolidayLegend: applyHolidayLegend,
    renderChartLegend: renderChartLegend
  };
})();
