'use strict';
// Browser regression using the production renderer, grouping controller, and stylesheet.
const fs = require('fs');
const path = require('path');
const os = require('os');
const {execFileSync} = require('child_process');
const root = path.resolve(__dirname, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ta-customer-'));
const script = name => fs.readFileSync(path.join(root, 'assets/javascripts', name), 'utf8');
const html = `<!doctype html><html><head><style>
.hidden {display:none} ${fs.readFileSync(path.join(root, 'assets/stylesheets/time_analytics.css'), 'utf8')}
</style></head><body>
<script id="ta-dimension-config" type="application/json">{"basePath":"/my/time","storageScope":"customer-test","labels":{}}</script>
<div id="customer-summary-view"><div id="customer-payload" data-payload='{"grandTotal":24,"items":[{"name":"A","hours":16,"groupValue":"a","noValue":false},{"name":"B","hours":8,"groupValue":"b","noValue":false}]}'></div>
<div id="customer-cards"></div><div id="customer-pagination-info"></div><div id="customer-pagination-links"></div></div>
<div id="customer-collapse-all-wrapper"></div><div id="fixture"></div><pre id="result">pending</pre>
<script>window.fetch = function () { return Promise.resolve({ok:true,json:function(){return Promise.resolve({items:[{id:1,url:'/issues/1',subject:'Shared',hours:8,valueBreakdown:[{name:'A',groupValue:'a',noValue:false,hours:8},{name:'B',groupValue:'b',noValue:false,hours:8}]}]});}}); }; window.taDimensionTabBody = {viewId:'customer',groupBy:'cf_issue_1',customerGrouping:true,perPage:1,labels:{shared:'Shared'}};</script>
<script>${script('ta_client_table.js')}</script><script>${script('ta_dimension_tabs.js')}</script>
<script>
window.addEventListener('load', async function () {
 try {
  var checks=0; function check(value, message) {if(!value)throw Error(message);checks++;}
  var cards=document.getElementById('customer-cards');
  function barColor() {return cards.querySelector('[style*="background-color"]').style.backgroundColor;}
  var original=barColor();
  taDimensionSortClick('name'); taDimensionSortClick('name');
  check(cards.textContent.includes('B'), 'reverse name sort shows B first');
  check(barColor() !== original, 'B keeps its own colour after sorting');
  taDimensionSortClick('hours');
  check(barColor() === original, 'A keeps its original donut colour');
  cards.querySelector('.ts-row-header').click();
  await new Promise(function(resolve){setTimeout(resolve,20);});
  var loadedDots=cards.querySelectorAll('.ta-customer-dot');
  check(loadedDots.length===2 && loadedDots[0].style.backgroundColor===original,'loaded details use actual grouping colour mapping');
  check(loadedDots[1].style.backgroundColor==='rgb(242, 142, 43)','second customer matches donut palette');
  var item={id:1,url:'/issues/1',subject:'Ticket <safe>',trackerName:'Task',hours:8,valueBreakdown:[
   {name:'Customer <A>',groupValue:'a',hours:8},{name:'Customer B',groupValue:'b',hours:8}]};
  var labels={customerGrouping:true,shared:'Shared',valueColor:function(v){return v.groupValue==='a'?'#4E79A7':'#F28E2B';}};
  // Use the production delegated handler so badge clicks cannot toggle the native summary.
  cards.innerHTML=taIssueRowHtml(item,labels);
  var ticket=cards.querySelector('details');
  check(ticket && !ticket.open,'shared ticket starts collapsed');
  check(cards.querySelectorAll('.ta-shared-badge').length===1,'one Shared badge');
  check(!cards.querySelector('.ta-shared-badge svg'),'badge has no chevron');
  cards.querySelector('.ta-shared-badge').click();
  check(!ticket.open,'badge is informational');
  cards.querySelector('summary > svg').dispatchEvent(new MouseEvent('click',{bubbles:true}));
  check(ticket.open,'leading chevron expands ticket');
  check(cards.querySelectorAll('.ta-customer-value').length===2,'both contributions displayed');
  check(cards.textContent.includes('Customer <A>: 8:00'),'customer name escaped and hours retained');
  var dots=cards.querySelectorAll('.ta-customer-dot');
  check(dots[0].style.backgroundColor==='rgb(78, 121, 167)' && dots[1].style.backgroundColor==='rgb(242, 142, 43)','dots use customer palette');
  check(cards.querySelectorAll('a[href="/issues/1"]').length===2,'ticket links retained');
  cards.querySelector('summary').click();check(!ticket.open,'summary collapses');
  cards.querySelector('summary').click();taDimensionCollapseAll();check(!ticket.open,'collapse all closes ticket');
  item.valueBreakdown=item.valueBreakdown.slice(0,1);
  cards.innerHTML=taIssueRowHtml(item,labels);
  check(!cards.querySelector('details, .ta-shared-badge, svg, .ta-customer-values'),'single customer has no redundant disclosure');
  check(cards.textContent.includes('8:00'),'single customer hours retained');
  item.valueBreakdown.push({name:'B',hours:8});
  cards.innerHTML=taIssueRowHtml(item,{contribution:'%{logged} logged → %{grouped} across values'});
  check(cards.querySelector('details summary') && !cards.querySelector('.ta-shared-badge'),'other grouping renderer unchanged');
  document.getElementById('result').textContent='PASS '+checks+' Customer ticket checks';
 } catch(e) {document.getElementById('result').textContent='FAIL '+e.stack;}
});
</script></body></html>`;
const file = path.join(dir, 'test.html');fs.writeFileSync(file, html);
const result = execFileSync(process.env.CHROME_BIN || '/usr/bin/google-chrome', ['--headless','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--disable-background-networking','--user-data-dir='+path.join(dir,'profile'),'--dump-dom','--virtual-time-budget=2000','file://'+file], {encoding:'utf8',stdio:['ignore','pipe','ignore']});
const match=result.match(/<pre id="result">([^<]*)<\/pre>/);
if(!match || !match[1].startsWith('PASS')) throw Error(match ? match[1] : result.slice(-1000));
console.log(match[1]);
