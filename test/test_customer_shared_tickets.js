'use strict';
// Browser regression using the production renderer, grouping controller, and stylesheet.
const fs = require('fs');
const path = require('path');
const os = require('os');
const {execFileSync} = require('child_process');
const root = path.resolve(__dirname, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ta-customer-'));
const script = name => fs.readFileSync(path.join(root, 'assets/javascripts', name), 'utf8');
const individual = fs.readFileSync(path.join(root, 'app/views/time_analytics/individual_dashboard.html.erb'), 'utf8');
const team = fs.readFileSync(path.join(root, 'app/views/team_analytics/index.html.erb'), 'utf8');
const chartCode = individual.slice(individual.indexOf('function renderDonutFromArrays('), individual.indexOf("<% if @view_mode == 'activity' %>\n// ── Activity")) +
 team.slice(team.indexOf('  function renderTeamDonutFromArrays('), team.indexOf('  // Chart initialization'));
const partial = fs.readFileSync(path.join(root, 'app/views/time_analytics/_dimension_tab_body.html.erb'), 'utf8');
const toggleMarkup = partial.match(/<label class="ta-customer-hours-control[\s\S]*?<\/label>/)[0].replace(/<%=[\s\S]*?%>/g, 'Hours by customer');
const theme = fs.readFileSync(path.join(root, '../../app/assets/stylesheets/application.css'), 'utf8');
const html = `<!doctype html><html><head><style>
${theme}
${fs.readFileSync(path.join(root, 'assets/stylesheets/flowbite.min.css'), 'utf8')}
${fs.readFileSync(path.join(root, 'assets/stylesheets/tailwind.output.css'), 'utf8')}
.hidden {display:none} ${fs.readFileSync(path.join(root, 'assets/stylesheets/time_analytics.css'), 'utf8')}
</style></head><body>
<script id="ta-dimension-config" type="application/json">{"basePath":"/my/time","storageScope":"customer-test","labels":{}}</script>
<div id="customer-summary-view"><div id="customer-payload" data-payload='{"grandTotal":24,"loggedTotal":16,"items":[{"name":"A","hours":16,"groupValue":"a","noValue":false},{"name":"B","hours":8,"groupValue":"b","noValue":false}]}'></div>
<div id="customer-cards"></div><div id="customer-pagination-info"></div><div id="customer-pagination-links"></div></div>
${toggleMarkup}<span id="caption"></span><div id="donut-legend"></div><div id="team-donut-legend"></div><div style="width:300px;height:300px"><canvas id="donut-chart"></canvas><span id="total-hours-display"></span></div><div style="width:300px;height:300px"><canvas id="team-donut-chart"></canvas><span id="team-total-hours-display"></span></div><div id="customer-collapse-all-wrapper"></div><div id="fixture"></div><pre id="result">pending</pre>
<script>window.fetch = function () { return Promise.resolve({ok:true,json:function(){return Promise.resolve({items:[{id:1,url:'/issues/1',subject:'Shared',hours:8,valueBreakdown:[{name:'A',groupValue:'a',noValue:false,hours:8},{name:'B',groupValue:'b',noValue:false,hours:8}]}]});}}); }; window.taDimensionTabBody = {viewId:'customer',groupBy:'cf_issue_1',customerGrouping:true,perPage:1,donutCaptionId:'caption',donutLegendId:'donut-legend',labels:{sharedWith:'Shared with %{count}',totalHours:'Total Hours',hoursByCustomer:'Hours by customer'}};</script>
<script>${script('flowbite.min.js')}</script><script>${script('chart.min.js')}</script><script>${script('ta_client_table.js')}</script><script>${script('ta_dimension_tabs.js')}</script>
<script>var donutChartInstance=null, teamDonutChart=null; var formatTeamHours=function(v){return v.toFixed(2)}; var formatHours=formatTeamHours; ${chartCode}</script>
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
  check(cards.querySelector('.ta-shared-button').textContent==='Shared with 2','loaded count label');
  var item={id:1,url:'/issues/1',subject:'Ticket <safe>',trackerName:'Task',hours:8,valueBreakdown:[
   {name:'Customer <A>',groupValue:'a',hours:8},{name:'Customer B',groupValue:'b',hours:8}]};
  var labels={customerGrouping:true,sharedWith:'Shared with %{count}',close:'Close'};
  cards.innerHTML=taIssueRowHtml(item,labels);
  var button=cards.querySelector('.ta-shared-button');
  check(button && button.textContent==='Shared with 2','actual linked customer count');
  check(!cards.querySelector('details'),'no inline disclosure');
  button.dispatchEvent(new MouseEvent('mouseenter',{bubbles:true})); button.focus();
  check(!document.querySelector('.ta-customer-popover'),'hover and focus do not open popover');
  button.click();
  var popup=document.querySelector('.ta-customer-popover');
  check(popup && button.getAttribute('aria-expanded')==='true','click opens Flowbite popover');
  check(getComputedStyle(button).backgroundColor==='rgb(29, 78, 216)' && getComputedStyle(button).color==='rgb(255, 255, 255)','open sharing button stays dark blue with white text');
  var closeStyle=getComputedStyle(popup.querySelector('button'));
  check(closeStyle.color==='rgb(71, 85, 105)' && closeStyle.backgroundColor==='rgb(241, 245, 249)','close icon has visible contrast');
  check(popup.querySelectorAll('li').length===2,'only linked names listed');
  check(popup.textContent.includes('Customer <A>') && !popup.querySelector('a'),'names escaped without navigation');
  check(!popup.textContent.includes('8:00'),'no hours or explanations in popover');
  button.click();check(!document.querySelector('.ta-customer-popover'),'trigger toggles closed');
  button.click();document.body.click();check(!document.querySelector('.ta-customer-popover'),'blank page dismisses');
  button.click();document.querySelector('.ta-customer-popover-close').click();
  check(!document.querySelector('.ta-customer-popover') && document.activeElement===button,'close restores focus');
  button.click();document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));
  check(!document.querySelector('.ta-customer-popover'),'Escape dismisses');
  button.click();taDimensionCollapseAll();check(!document.querySelector('.ta-customer-popover'),'collapse all dismisses');
  check(cards.querySelectorAll('a[href="/issues/1"]').length===2,'ticket links retained');
  button.click();cards.innerHTML=taIssueRowHtml(item,labels);
  await new Promise(function(resolve){setTimeout(resolve,20);});
  check(!document.querySelector('.ta-customer-popover'),'rerender cleans up portal');
  cards.querySelector('.ta-shared-button').click();
  var second=cards.querySelector('.ta-shared-ticket').cloneNode(true);cards.appendChild(second);
  second.querySelector('button').click();
  check(document.querySelectorAll('.ta-customer-popover').length===1,'only one popup at a time');
  document.body.click();
  item.valueBreakdown=item.valueBreakdown.slice(0,1);
  cards.innerHTML=taIssueRowHtml(item,labels);
  check(!cards.querySelector('details, .ta-shared-button, svg, template'),'single customer has no redundant disclosure');
  check(cards.textContent.includes('8:00'),'single customer hours retained');
  item.valueBreakdown.push({name:'B',hours:8});
  cards.innerHTML=taIssueRowHtml(item,{contribution:'%{logged} logged → %{grouped} across values'});
  check(cards.querySelector('details summary') && !cards.querySelector('.ta-shared-badge'),'other grouping renderer unchanged');
  var toggle=document.getElementById('ta-customer-hours-toggle');
  var payloadEl=document.getElementById('customer-payload');
  for (var dashboard of ['individual','team']) {
    var isTeam=dashboard==='team';
    var render=isTeam?renderTeamDonutFromArrays:renderDonutFromArrays;
    var total=document.getElementById(isTeam?'team-total-hours-display':'total-hours-display');
    var legendId=isTeam?'team-donut-legend':'donut-legend';
    taDimensionTabBody.donutLegendId=legendId;
    toggle.checked=false;
    render(['A','B'],[16,8],['#4E79A7','#F28E2B'],24);
    var chart=function(){return isTeam?teamDonutChart:donutChartInstance;};
    check(total.textContent==='16.00' && chart().data.datasets[0].data.join(',')==='16,8',dashboard+' defaults to exact logged total with customer slices');
    check(!document.getElementById(legendId).hidden && document.getElementById(legendId).textContent.includes('66.7%'),dashboard+' default shows customer legend with attributed percentages');
    check(getComputedStyle(toggle.nextElementSibling).backgroundColor==='rgb(203, 213, 225)',dashboard+' toggle off has gray track');
    var originalLegend=document.getElementById(legendId).innerHTML;
    for(var repeat=0;repeat<2;repeat++) {
      toggle.checked=true;toggle.dispatchEvent(new Event('change'));
      var track=toggle.nextElementSibling;
      check(getComputedStyle(track).backgroundColor==='rgb(29, 78, 216)' && getComputedStyle(track.firstElementChild).backgroundColor==='rgb(255, 255, 255)',dashboard+' active toggle shows white thumb on blue');
      check(total.textContent==='24.00' && chart().data.datasets[0].data.join(',')==='16,8',dashboard+' enables attributed chart');
      check(!document.getElementById(legendId).hidden && document.getElementById('caption').textContent==='Hours by customer',dashboard+' shows caption and legend');
      check(chart().data.datasets[0].backgroundColor[1]==='#F28E2B',dashboard+' retains customer colors');
      check(document.getElementById(legendId).innerHTML===originalLegend,dashboard+' toggle preserves legend values');
      toggle.checked=false;toggle.dispatchEvent(new Event('change'));
      check(total.textContent==='16.00' && chart().data.labels[0]==='A',dashboard+' restores logged total and retains slices');
    }
    payloadEl.setAttribute('data-payload',JSON.stringify({loggedTotal:0,grandTotal:0,items:[]}));
    render([],[],[],0);
    check(total.textContent==='0.00',dashboard+' empty total is zero');
    toggle.checked=true;toggle.dispatchEvent(new Event('change'));
    check(total.textContent==='0.00' && document.getElementById(legendId).hidden,dashboard+' empty toggle stays usable');
    payloadEl.setAttribute('data-payload',JSON.stringify({loggedTotal:16,grandTotal:24,items:[]}));
  }
  document.getElementById('result').textContent='PASS '+checks+' Customer ticket checks';
 } catch(e) {document.getElementById('result').textContent='FAIL '+e.stack;}
});
</script></body></html>`;
const file = path.join(dir, 'test.html');fs.writeFileSync(file, html);
const result = execFileSync(process.env.CHROME_BIN || '/usr/bin/google-chrome', ['--headless','--no-sandbox','--disable-gpu','--disable-dev-shm-usage','--disable-background-networking','--user-data-dir='+path.join(dir,'profile'),'--dump-dom','--virtual-time-budget=2000','file://'+file], {encoding:'utf8',stdio:['ignore','pipe','ignore']});
const match=result.match(/<pre id="result">([^<]*)<\/pre>/);
if(!match || !match[1].startsWith('PASS')) throw Error(match ? match[1] : result.slice(-1000));
console.log(match[1]);
