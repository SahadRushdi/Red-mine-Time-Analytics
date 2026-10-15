'use strict';

// Exercise the actual inline add/remove script against a minimal DOM, without npm dependencies.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const partial = fs.readFileSync(path.join(__dirname, '../app/views/settings/_redmine_time_analytics_settings.html.erb'), 'utf8');
const script = partial.match(/<script>([\s\S]*?)<\/script>/)[1];

class Input {
  constructor(type, name, value, checked) {
    Object.assign(this, { type, name, value, checked, id: name });
  }
  cloneNode() { return Object.assign(new Input(), this); }
  removeAttribute(name) { delete this[name]; }
}

class Row {
  constructor(inputs) { this.inputs = inputs; }
  cloneNode() { return new Row(this.inputs.map(input => input.cloneNode())); }
  querySelectorAll(selector) {
    assert.strictEqual(selector, 'input');
    return this.inputs;
  }
  remove() { this.parent.rows.splice(this.parent.rows.indexOf(this), 1); }
}

function savedRow(index, weekly, daily) {
  const prefix = 'settings[missing_time_schedules][' + index + ']';
  return new Row([
    new Input('text', prefix + '[cron]', '0 8 * * 1'),
    new Input('hidden', prefix + '[weekly]', '0'),
    new Input('checkbox', prefix + '[weekly]', '1', weekly),
    new Input('hidden', prefix + '[daily]', '0'),
    new Input('checkbox', prefix + '[daily]', '1', daily)
  ]);
}

const list = {
  rows: [], handlers: {},
  querySelectorAll() { return this.rows; },
  querySelector() { return this.rows[0]; },
  addEventListener(event, callback) { this.handlers[event] = callback; },
  appendChild(row) { row.parent = this; this.rows.push(row); }
};
list.appendChild(savedRow(0, false, true));
list.appendChild(savedRow(1, true, true));
const addButton = { addEventListener(event, callback) { this[event] = callback; } };
const document = {
  getElementById(id) { return id === 'missing-time-crons-list' ? list : addButton; },
  addEventListener(event, callback) { assert.strictEqual(event, 'DOMContentLoaded'); callback(); }
};
vm.runInNewContext(script, { document });

function remove(row) {
  list.handlers.click({
    preventDefault() {},
    target: { closest() { return { closest() { return row; } }; } }
  });
}
function add() { addButton.click({ preventDefault() {} }); }

remove(list.rows[0]);
add();
const added = list.rows[1];
assert.strictEqual(added.inputs[0].name, 'settings[missing_time_schedules][2][cron]');
assert.strictEqual(added.inputs[0].value, '');
assert.strictEqual(added.inputs[2].checked, true);
assert.strictEqual(added.inputs[4].checked, false);
assert.strictEqual(added.inputs[1].value, '0');
assert.strictEqual(added.inputs[3].value, '0');
assert.strictEqual(added.inputs[2].id, 'missing-time-weekly-2');
assert.strictEqual(added.inputs[4].id, 'missing-time-daily-2');
assert.ok(!added.inputs[0].id && !added.inputs[1].id && !added.inputs[3].id);
assert.strictEqual(list.rows[0].inputs[2].checked, true);
assert.strictEqual(list.rows[0].inputs[4].checked, true);
list.rows.slice().forEach(remove);
assert.strictEqual(list.rows.length, 0);
add();
assert.strictEqual(list.rows[0].inputs[0].name, 'settings[missing_time_schedules][3][cron]');
assert.strictEqual(list.rows[0].inputs[2].checked, true);
assert.strictEqual(list.rows[0].inputs[4].checked, false);
console.log('Missing time settings add/remove regression test passed');
