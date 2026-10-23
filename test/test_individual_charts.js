'use strict';

// Render real Rails-generated chart payloads with the vendored Chart.js and the page's actual
// initChart function. Generate the cases by running individual_dashboard_charts_test.rb with
// TA_CHART_CASES pointing to a temporary JSON file, then pass that file as this script's argument.
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const cases = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.strictEqual(cases.length, 9, 'Capture all three built-in tabs for daily, weekly, and monthly grouping');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ta-default-charts-'));
const source = name => fs.readFileSync(path.join(__dirname, '../assets/javascripts', name), 'utf8');
const file = path.join(dir, 'charts.html');
fs.writeFileSync(file, `<!doctype html><html><head>
<script>window.addEventListener('error', function(e) { var result = document.getElementById('result'); if (result) result.textContent = 'FAIL ' + e.message; });</script>
<script>${source('chart.min.js')}</script>
<script>${source('chartjs-plugin-colorschemes.min.js')}</script>
<script>${source('time_analytics_chart_plugins.js')}</script>
<style>.chart-wrapper{height:320px;width:800px;position:relative}</style>
</head><body><div id="host"></div><pre id="result">pending</pre><script>
var timeAnalyticsChart = null;
var emptyChartMessage = 'Empty';
function formatHours(hours) { return Number(hours).toFixed(2); }
function renderEmptyState() { throw Error('Unexpected empty chart'); }
var errors = [];
console.error = function () { errors.push(Array.from(arguments).map(String).join(' ')); };
var cases = ${JSON.stringify(cases).replace(/</g, () => String.fromCharCode(92) + 'u003c')};
try {
  for (var item of cases) {
    if (timeAnalyticsChart) { timeAnalyticsChart.destroy(); timeAnalyticsChart = null; }
    document.getElementById('host').innerHTML = '<div class="chart-wrapper"><canvas id="time-chart"></canvas></div><div id="individual-chart-legend"></div>';
    var config = item.chart;
    config.options.animation = false;
    document.getElementById('time-chart').setAttribute('data-chart', JSON.stringify(config));
    var start = item.html.indexOf('function initChart() {');
    var end = item.html.indexOf('function updateChart()', start);
    if (start < 0 || end < 0) throw Error('Missing chart initializer');
    window.eval(item.html.slice(start, end));
    initChart();
    if (errors.length) throw Error(item.name + ': ' + errors.join('; '));
    if (!timeAnalyticsChart || timeAnalyticsChart.config.type !== 'bar') throw Error(item.name + ': missing bar chart');
    if (config.data.datasets.some(function(dataset) { return dataset.data.some(function(value) { return typeof value !== 'number' || !Number.isFinite(value); }); })) throw Error(item.name + ': non-numeric chart hours');
    if (document.querySelectorAll('.ta-legend-item').length !== config.data.datasets.length) throw Error(item.name + ': incomplete legend');
    var image = timeAnalyticsChart.ctx.getImageData(0, 0, timeAnalyticsChart.width, timeAnalyticsChart.height).data;
    if (!image.some(function (value, index) { return index % 4 === 3 && value > 0; })) throw Error(item.name + ': empty canvas');
    var hasBar = config.data.datasets.some(function (dataset, index) {
      return timeAnalyticsChart.getDatasetMeta(index).data.some(function (bar) {
        return bar._model && Number.isFinite(bar._model.y) && Number.isFinite(bar._model.base) && bar._model.y !== bar._model.base;
      });
    });
    if (!hasBar) throw Error(item.name + ': no visible bars');
    initChart();
    if (errors.length || !timeAnalyticsChart) throw Error(item.name + ': reinitialization failed');
  }
  document.getElementById('result').textContent = 'PASS ' + cases.length + ' stacked charts';
} catch (error) {
  document.getElementById('result').textContent = 'FAIL ' + error.stack;
}
</script></body></html>`);
const output = execFileSync(process.env.CHROME_BIN || '/opt/google/chrome/chrome', [
  '--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--disable-background-networking',
  '--no-first-run', '--user-data-dir=' + path.join(dir, 'profile'), '--dump-dom', '--virtual-time-budget=1000', 'file://' + file
], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 30000, maxBuffer: 10 * 1024 * 1024 });
const result = output.match(/<pre id="result">([^<]*)<\/pre>/);
assert(result && result[1].startsWith('PASS '), result ? result[1] : output.slice(-3000));
console.log(result[1]);
