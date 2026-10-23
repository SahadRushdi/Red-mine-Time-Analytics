'use strict';

// Capture cases with TA_TEAM_LAYOUT_CASES while running multiple_value_grouping_test.rb.
// This checks real Rails markup, production CSS/Chart.js, and the page's chart-switch function.
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const cases = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.strictEqual(cases.length, 18, 'Capture all grouping, period, and chart-type combinations');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ta-team-layout-'));
const source = name => fs.readFileSync(path.join(__dirname, '../assets/javascripts', name), 'utf8');
const css = name => fs.readFileSync(path.join(__dirname, '../assets/stylesheets', name), 'utf8');
const file = path.join(dir, 'team.html');
fs.writeFileSync(file, `<!doctype html><html><head>
<script>window.addEventListener('error', function(e) { var result = document.getElementById('result'); if (result) result.textContent = 'FAIL ' + e.message; });</script>
<style>${css('tailwind.output.css')}${css('time_analytics.css')}</style>
<script>${source('chart.min.js')}</script>
<script>${source('chartjs-plugin-colorschemes.min.js')}</script>
<script>${source('time_analytics_chart_plugins.js')}</script>
<style>#host{width:1400px}</style>
</head><body><div id="host"></div><pre id="result">pending</pre><script>
var teamChart = null;
var noChartDataMessage = 'Empty';
function formatTeamHours(hours) { return Number(hours).toFixed(2); }
function renderTeamEmptyState() { throw Error('Unexpected empty chart'); }
var errors = [];
console.error = function () { errors.push(Array.from(arguments).map(String).join(' ')); };
var cases = ${JSON.stringify(cases).replace(/</g, () => String.fromCharCode(92) + 'u003c')};
function check(value, message) { if (!value) throw Error(message); }
try {
  for (var item of cases) {
    if (teamChart) { teamChart.destroy(); teamChart = null; }
    document.getElementById('host').innerHTML = item.form + item.analytics;
    var section = document.querySelector('.analytics-section');
    var table = document.getElementById('team-time-overview-box');
    check(table, item.name + ': missing Time Log');
    var chartCard = section.querySelector('.visualization-section');
    var tableRect = table.getBoundingClientRect();
    var cardRect = chartCard.getBoundingClientRect();
    check(tableRect.width > 0 && cardRect.left > tableRect.right, item.name + ': missing two-column layout');
    check(cardRect.width < section.clientWidth - tableRect.width, item.name + ': chart stretches across table');
    var wrapper = chartCard.querySelector('.chart-wrapper');
    check(wrapper.getBoundingClientRect().height <= (item.type === 'bar' ? 301 : 371), item.name + ': chart height exceeds its allocation');
    check(document.getElementById('chart-container').classList.contains('has-chart-legend') === (item.type === 'bar'), item.name + ': wrong legend sizing');

    var canvas = document.getElementById('time-chart');
    var config = JSON.parse(canvas.getAttribute('data-chart'));
    config.options.animation = false;
    canvas.setAttribute('data-chart', JSON.stringify(config));
    var start = item.html.indexOf('function initChart() {');
    var end = item.html.indexOf('var TEAM_VIEW_CONFIG', start);
    check(start >= 0 && end >= 0, 'Missing team chart initializer');
    window.eval(item.html.slice(start, end));
    initChart();
    check(!errors.length && teamChart && teamChart.config.type === item.type, item.name + ': chart rendering failed ' + errors.join('; '));
    if (item.type === 'bar') {
      var legend = document.getElementById('team-chart-legend');
      check(legend.querySelectorAll('.ta-legend-item').length === config.data.datasets.length, item.name + ': legend missing');
      check(legend.getBoundingClientRect().bottom <= cardRect.bottom, item.name + ': legend overflows chart card');
    }

    start = item.html.indexOf('function switchTeamChartType(chartType)');
    end = item.html.indexOf('function toggleHolidays()', start);
    check(start >= 0 && end >= 0, 'Missing chart controls');
    window.eval(item.html.slice(start, end));
    var form = document.getElementById('team-analytics-form');
    var original = new URLSearchParams(new FormData(form));
    var submitted;
    form.submit = function () { submitted = new URLSearchParams(new FormData(form)); };
    ['line', 'bar'].forEach(function(type) {
      var button = Array.from(document.querySelectorAll('.visualization-controls button')).find(function(el) {
        return el.getAttribute('onclick') === "switchTeamChartType('" + type + "')";
      });
      check(button && button.getBoundingClientRect().width > 0, item.name + ': invisible chart toggle');
      button.click();
      check(submitted && submitted.get('chart_type') === type, item.name + ': chart switch not submitted');
      for (var key of ['view_mode', 'team_id', 'filter', 'from', 'to', 'grouping', 'hide_holidays']) {
        check(submitted.get(key) === original.get(key), item.name + ': chart switch lost ' + key);
      }
    });
  }
  document.getElementById('result').textContent = 'PASS ' + cases.length + ' team grouping layouts and chart controls';
} catch (error) { document.getElementById('result').textContent = 'FAIL ' + error.stack; }
</script></body></html>`);
const output = execFileSync(process.env.CHROME_BIN || '/opt/google/chrome/chrome', [
  '--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--disable-background-networking',
  '--no-first-run', '--window-size=1600,1000', '--user-data-dir=' + path.join(dir, 'profile'),
  '--dump-dom', '--virtual-time-budget=1000', 'file://' + file
], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30000, maxBuffer: 32 * 1024 * 1024 });
const result = output.match(/<pre id="result">([^<]*)<\/pre>/);
assert(result && result[1].startsWith('PASS '), result ? result[1] : output.slice(-3000));
console.log(result[1]);
