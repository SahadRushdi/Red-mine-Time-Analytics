'use strict';

// Run the real scripts against a browser DOM, including full-page grouping navigation.
// CHROME_BIN can select another Chromium installation.
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ta-grouping-browser-'));
const source = name => fs.readFileSync(path.join(__dirname, '../assets/javascripts', name), 'utf8');

async function scenario(scope) {
  const file = path.join(dir, scope + '.html');
  const config = {
    basePath: file, fieldsPath: '/fields', storageScope: scope,
    scrollFlag: scope === 'team' ? 'scrollToTeamTable' : 'scrollToTable',
    defaultViewMode: 'issue', carryParams: { grouping: 'monthly', filter: 'this_month' },
    labels: { remove: 'Remove', empty: 'Empty', error: 'Retry loading', noMatches: 'No matches', alreadyUsed: 'Used' }
  };
  fs.writeFileSync(file, `<!doctype html><html><head><style>
    [hidden], .hidden {display:none !important} body {margin:0} #ta-grouping-navigation {padding:10px}
    </style><script>
    window.errors = []; window.checks = 0;
    window.check = function(value, message) { if (!value) throw Error(message); window.checks++; };
    window.addEventListener('error', function(e) { window.errors.push(e.message); });
    window.taEscapeHtml = function(s) { var e = document.createElement('span'); e.textContent = s; return e.innerHTML; };
    window.requests = []; window.failRequest = false;
    window.sections = [{section:'issue_cf', label:'Issue custom fields', fields:[{key:'cf_issue_1',label:'Customer',pinned:false}]}];
    window.fetch = function(url, options) {
      window.requests.push(options);
      return window.failRequest ? Promise.reject(Error('offline')) : Promise.resolve({ok:true,json:function(){return Promise.resolve({sections:window.sections});}});
    };
    window.config = ${JSON.stringify(config)};
    var chosen = new URLSearchParams(location.search).get('view_mode');
    if (chosen) {
      window.config.activeKey = chosen; window.config.activeLabel = 'Customer New';
      window.sections[0].fields.push({key:chosen,label:'Customer New',pinned:false});
    }
    else { sessionStorage.clear(); sessionStorage.setItem(window.config.scrollFlag, 'true'); }
    sessionStorage.setItem('${scope === 'team' ? 'teamScrollPosition' : 'scrollPosition'}','2000');
    </script></head><body><div style="height:900px"></div>
    <div id="ta-grouping-navigation"><ul><li id="ta-dimension-chips"></li></ul>
      <button id="ta-add-dimension-btn">Add</button><div id="ta-dimension-menu" class="hidden">
      <input id="ta-dimension-search"><div id="ta-dimension-menu-body"></div></div></div>
    <div style="height:1800px">Results</div>
    <div id="content"><form><select id="custom_field_field_format"><option>string</option><option>text</option></select>
      <p id="filter-row"><input name="custom_field[is_filter]" type="hidden" value="0">
        <input id="custom_field_is_filter" name="custom_field[is_filter]" type="checkbox" checked></p>
      <input id="custom_field_multiple" type="checkbox">
      <p id="ta-pinned-grouping-control" data-grouping-formats='["string"]'>
        <input id="ta-pinned-grouping-unchecked" type="hidden"><input id="ta_pinned_grouping" type="checkbox" checked><em>Requires filter</em>
      </p></form></div><pre id="result">pending</pre>
    <script>var el=document.createElement('script');el.type='application/json';el.id='ta-dimension-config';el.textContent=JSON.stringify(window.config);document.body.appendChild(el);</script>
    <script>${source('ta_grouping_custom_fields.js')}</script>
    <script>${source('ta_dimension_tabs.js')}</script>
    <script>
    const tick = () => new Promise(resolve => setTimeout(resolve, 50));
    const click = id => document.getElementById(id).click();
    const change = id => document.getElementById(id).dispatchEvent(new Event('change', {bubbles:true}));
    window.addEventListener('load', async function() {
      try {
        await tick();
        check(sessionStorage.getItem(config.scrollFlag) === null, 'navigation flag consumed');
        check(sessionStorage.getItem('${scope === 'team' ? 'teamScrollPosition' : 'scrollPosition'}') === null, 'pagination scroll cannot override navigation');
        // A second load verifies actual selection navigation, chip persistence, and filter carry-over.
        if (chosen) {
          await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
          check(new URLSearchParams(location.search).get('grouping') === 'monthly', 'grouping retained');
          check(new URLSearchParams(location.search).get('filter') === 'this_month', 'filter retained');
          check(!new URLSearchParams(location.search).has('page'), 'pagination reset');
          check(document.querySelector('[data-ta-dim-key="cf_issue_2"]'), 'added grouping survives full reload');
        check(document.querySelector('.ta-view-tab-active') === document.activeElement,
          'selected group receives focus: ' + document.activeElement.tagName + ', scroll=' + window.scrollY);
          check(Math.abs(document.getElementById('ta-grouping-navigation').getBoundingClientRect().top) < 2, 'tabs remain visible above results');
          check(errors.length === 0, errors.join('; '));
          document.getElementById('result').textContent = 'PASS ' + (Number(sessionStorage.getItem('previousChecks')) + checks);
          return;
        }
        check(!document.getElementById('ta_pinned_grouping').disabled, 'eligible pin enabled');
        document.getElementById('custom_field_is_filter').checked = false; change('custom_field_is_filter');
        check(document.getElementById('ta_pinned_grouping').disabled, 'filter prerequisite enforced');
        document.getElementById('custom_field_multiple').checked = true; change('custom_field_multiple');
        check(document.getElementById('filter-row').hidden && document.getElementById('ta-pinned-grouping-control').hidden, 'multiple values hide both controls');
        check(document.getElementById('custom_field_is_filter').disabled, 'hidden filter not submitted');
        document.getElementById('custom_field_multiple').checked = false; change('custom_field_multiple');
        document.getElementById('custom_field_field_format').value = 'text'; change('custom_field_field_format');
        check(document.getElementById('filter-row').hidden, 'unsupported format hides core filter');
        const form = document.querySelector('form'); const replacement = form.cloneNode(true);
        replacement.querySelector('#custom_field_field_format').value = 'text'; form.replaceWith(replacement);
        await tick();
        check(document.getElementById('filter-row').hidden, 'AJAX replacement reconciled');
        document.getElementById('custom_field_field_format').value = 'string';
        document.getElementById('custom_field_is_filter').checked = true; change('custom_field_field_format');
        check(!document.getElementById('filter-row').hidden && !document.getElementById('ta_pinned_grouping').disabled, 'supported format restores controls');
        check(document.getElementById('ta_pinned_grouping').checked, 'pin intent preserved');
        click('ta-add-dimension-btn'); click('ta-add-dimension-btn'); click('ta-add-dimension-btn'); await tick();
        check(document.querySelector('[data-ta-dim-pick="cf_issue_1"]'), 'first field listed');
        check(requests.length === 1, 'simultaneous picker opens share an in-flight request');
        click('ta-add-dimension-btn');
        window.sections[0].fields.push({key:'cf_issue_2',label:'Customer New',pinned:false});
        click('ta-add-dimension-btn'); await tick();
        check(document.querySelector('[data-ta-dim-pick="cf_issue_2"]'), 'new field discovered without page reload');
        check(requests.length === 2 && requests.every(r => r.cache === 'no-store'), 'picker reloads with cache bypass');
        const search = document.getElementById('ta-dimension-search');
        search.value = 'New'; search.dispatchEvent(new Event('input'));
        check(document.querySelectorAll('[data-ta-dim-pick]').length === 1, 'search filters fields');
        click('ta-add-dimension-btn'); window.failRequest = true;
        click('ta-add-dimension-btn'); await tick();
        check(document.getElementById('ta-dimension-menu-body').textContent === 'Retry loading', 'failure is explained');
        click('ta-add-dimension-btn'); window.failRequest = false;
        click('ta-add-dimension-btn'); await tick();
        check(document.querySelector('[data-ta-dim-pick="cf_issue_2"]'), 'failed request can retry');
        search.value = 'New'; search.dispatchEvent(new Event('input'));
        sessionStorage.setItem('previousChecks', String(checks));
        search.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));
      } catch(e) { document.getElementById('result').textContent = 'FAIL ' + e.stack; }
    });
    </script></body></html>`);
  const chrome = spawn(process.env.CHROME_BIN || '/opt/google/chrome/chrome', [
    '--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--disable-background-networking',
    '--no-first-run', '--allow-file-access-from-files', '--remote-debugging-port=0',
    '--user-data-dir=' + path.join(dir, scope + '-profile'), 'about:blank'
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  let socket;
  try {
    const address = await new Promise((resolve, reject) => {
      let stderr = '';
      chrome.stderr.on('data', chunk => {
        stderr += chunk;
        const match = stderr.match(/DevTools listening on ws:\/\/(127\.0\.0\.1:\d+)/);
        if (match) resolve('http://' + match[1]);
      });
      chrome.on('exit', () => reject(Error(stderr)));
      chrome.on('error', reject);
    });
    const page = await (await fetch(address + '/json/new?' + encodeURIComponent('file://' + file), { method: 'PUT' })).json();
    socket = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    let sequence = 0;
    const pending = new Map();
    socket.onmessage = event => {
      const data = JSON.parse(event.data);
      if (pending.has(data.id)) { pending.get(data.id)(data); pending.delete(data.id); }
    };
    function evaluate(expression) {
      return new Promise(resolve => {
        const id = ++sequence; pending.set(id, resolve);
        socket.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }));
      });
    }
    let result = 'pending';
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const response = await evaluate('document.getElementById("result")?.textContent');
      result = response.result?.result?.value || 'pending';
      if (/^(PASS|FAIL)/.test(result)) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert(result.startsWith('PASS '), result);
    console.log(scope + ': ' + result);
  } finally {
    if (socket) socket.close();
    chrome.kill();
  }
}
(async function () {
  await scenario('individual');
  await scenario('team');
}()).catch(error => { console.error(error); process.exitCode = 1; });
