'use strict';

var assert = require('assert');
var fs = require('fs');
var vm = require('vm');
var path = require('path');

var source = fs.readFileSync(
  path.join(__dirname, '..', 'assets', 'javascripts', 'team_activity_groups.js'),
  'utf8'
);
var context = { window: {} };
vm.runInNewContext(source, context);

function formatHours(hours) {
  var totalMinutes = Math.round(parseFloat(hours || 0) * 60);
  var h = Math.floor(totalMinutes / 60);
  var m = totalMinutes % 60;
  return h + ':' + (m < 10 ? '0' : '') + m;
}

var callbacks = context.window.TeamActivityGroups.buildStackedBarTooltipCallbacks(formatHours);
var data = { datasets: [{ label: 'Test', data: [7.3333334922790535] }] };

assert.strictEqual(
  callbacks.label({ datasetIndex: 0, index: 0, yLabel: 7.3333334922790535 }, data),
  'Test: 7:20'
);

console.log('Grouped chart tooltip regression test passed');
