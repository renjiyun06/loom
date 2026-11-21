'use strict';
(function(){
var $=function(id){return document.getElementById(id);};
var icons={
message:'<path d="M20 11.5a7.5 7.5 0 0 1-7.5 7.5H5l-3 3v-8.5A7.5 7.5 0 0 1 9.5 6H13a7.5 7.5 0 0 1 7 5.5Z"/><path d="M8 11h7M8 15h4"/>',
replay:'<path d="M4 9a8 8 0 1 1 0 6"/><path d="M4 3v6h6"/>',
moon:'<path d="M20.5 13A8.5 8.5 0 0 1 11 3.5 8.5 8.5 0 1 0 20.5 13Z"/>',
sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5"/>',
panel:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16M18 8v3"/>',
more:'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
check:'<path d="m5 12 4 4 10-10"/>',
copy:'<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/>',
source:'<path d="m8 7-5 5 5 5M16 7l5 5-5 5M14 4l-4 16"/>',
external:'<path d="M14 3h7v7M21 3l-10 10"/><path d="M10 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-5"/>',
close:'<path d="m6 6 12 12M6 18 18 6"/>',
chevron:'<path d="m9 5 7 7-7 7"/>',
stop:'<rect x="6" y="6" width="12" height="12" rx="1"/>',
lock:'<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
collapse:'<path d="m7 5 5 5 5-5M7 19l5-5 5 5"/>',
terminal:'<path d="m5 7 5 5-5 5M13 17h6"/>',
alert:'<path d="m10.3 4.3-8 14A1.8 1.8 0 0 0 4 21h16a1.8 1.8 0 0 0 1.7-2.7l-8-14a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4M12 17h.01"/>'
};
function icon(name){return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'+(icons[name]||'')+'</svg>';}
document.querySelectorAll('[data-icon]').forEach(function(el){el.innerHTML=icon(el.dataset.icon);});
function escapeHtml(value){return String(value).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];});}
var tick=String.fromCharCode(96),fence=tick.repeat(3);
function inline(text){
 var pattern=new RegExp(tick+'([^'+tick+']+)'+tick+'|\\*\\*([^*]+)\\*\\*|\\*([^*]+)\\*|\\[([^\\]]+)\\]\\(([^\\s)]+)\\)','g');
 var result='',last=0,match;
 while((match=pattern.exec(text))){
  result+=escapeHtml(text.slice(last,match.index));
  if(match[1]!==undefined)result+='<code>'+escapeHtml(match[1])+'</code>';
  else if(match[2]!==undefined)result+='<strong>'+escapeHtml(match[2])+'</strong>';
  else if(match[3]!==undefined)result+='<em>'+escapeHtml(match[3])+'</em>';
  else {
   var url=match[5];
   result+=/^(https?:\/\/|mailto:)/i.test(url)?'<a href="'+escapeHtml(url)+'" target="_blank" rel="noopener noreferrer">'+escapeHtml(match[4])+'</a>':escapeHtml(match[4]);
  }
  last=pattern.lastIndex;
 }
 return result+escapeHtml(text.slice(last));
}
function highlight(code){
 var pattern=/"[^"]*"|'(?:[^']|'')*'|\b(?:self|super|true|false|nil|return|const|let|function|if|else)\b|#[A-Za-z]\w*|\b\d+(?:\.\d+)?\b/g;
 var out='',last=0,m;
 while((m=pattern.exec(code))){
  out+=escapeHtml(code.slice(last,m.index));
  var token=m[0],kind=token[0]==='"'?'comment':token[0]==="'"?'string':/^\d/.test(token)?'number':'keyword';
  out+='<span class="tok-'+kind+'">'+escapeHtml(token)+'</span>';last=pattern.lastIndex;
 }
 return out+escapeHtml(code.slice(last));
}
function codeBlock(code,language){
 return '<div class="code-block"><div class="code-header"><span>'+escapeHtml(language||'text')+'</span><button class="copy-code" type="button" data-code="'+encodeURIComponent(code)+'">复制代码</button></div><pre><code>'+highlight(code)+'</code></pre></div>';
}
function cells(line){return line.trim().replace(/^\|/,'').replace(/\|$/,'').split('|').map(function(c){return c.trim();});}
function tableSeparator(line){return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);}
function renderMarkdown(markdown){
 var lines=String(markdown).replace(/\r\n?/g,'\n').split('\n'),out='',i=0;
 function boundary(line,index){return !line.trim()||line.indexOf(fence)===0||/^#{1,3}\s/.test(line)||/^\s*[-*]\s/.test(line)||/^\d+\.\s/.test(line)||/^>\s?/.test(line)||(lines[index+1]&&tableSeparator(lines[index+1]));}
 while(i<lines.length){
  var line=lines[i],m;
  if(!line.trim()){i++;continue;}
  if(line.indexOf(fence)===0){var lang=line.slice(3).trim(),code=[];i++;while(i<lines.length&&lines[i].indexOf(fence)!==0)code.push(lines[i++]);if(i<lines.length)i++;out+=codeBlock(code.join('\n'),lang);continue;}
  if((m=/^(#{1,3})\s+(.*)$/.exec(line))){out+='<h'+m[1].length+'>'+inline(m[2])+'</h'+m[1].length+'>';i++;continue;}
  if(lines[i+1]&&tableSeparator(lines[i+1])){
   var headings=cells(line);out+='<div class="table-scroll"><table><thead><tr>'+headings.map(function(c){return '<th>'+inline(c)+'</th>';}).join('')+'</tr></thead><tbody>';i+=2;
   while(i<lines.length&&lines[i].includes('|')&&lines[i].trim()){var row=cells(lines[i++]);out+='<tr>'+headings.map(function(_,index){return '<td>'+inline(row[index]||'')+'</td>';}).join('')+'</tr>';}
   out+='</tbody></table></div>';continue;
  }
  if(/^>\s?/.test(line)){var quote=[];while(i<lines.length&&/^>\s?/.test(lines[i]))quote.push(lines[i++].replace(/^>\s?/,''));out+='<blockquote><p>'+quote.map(inline).join('<br>')+'</p></blockquote>';continue;}
  if(/^\s*[-*]\s/.test(line)||/^\d+\.\s/.test(line)){
   var ordered=/^\d+\.\s/.test(line),listPattern=ordered?/^\d+\.\s+(.*)$/:/^\s*[-*]\s+(.*)$/;
   out+=ordered?'<ol>':'<ul>';while(i<lines.length&&(m=listPattern.exec(lines[i]))){out+='<li>'+inline(m[1])+'</li>';i++;}out+=ordered?'</ol>':'</ul>';continue;
  }
  if(/^---+$/.test(line.trim())){out+='<hr>';i++;continue;}
  var paragraph=[line];i++;while(i<lines.length&&!boundary(lines[i],i))paragraph.push(lines[i++]);
  out+='<p>'+paragraph.map(inline).join('<br>')+'</p>';
 }
 return out;
}
var sampleUser='把 Loom 的对话页变成一个现代、清晰的工作界面。重点是 Markdown 阅读体验和真实活动展示。';
var sampleAnswer=[
'可以。让对话更好读，让过程更清晰。',
'',
'## 一个更专注的工作空间',
'',
'左侧保留完整的对话节奏，右侧把执行过程整理成一条**紧凑、可展开的活动时间线**。你可以专注阅读，也可以随时了解工作进行到了哪里。',
'',
'- **内容优先**：清晰的标题、段落和留白，让长回复也容易阅读。',
'- **按需展开**：工具的参数和结果留在详情里，不占据整个页面。',
'- **持续可见**：回复和活动逐步出现，不必等到任务结束。',
'',
'| 区域 | 默认展示 | 深入查看 |',
'| --- | --- | --- |',
'| 对话 | Markdown 正文与代码 | 复制原文、查看源码 |',
'| 实时活动 | 动作、状态和耗时 | 展开参数与执行结果 |',
'',
'### 代码，也应该好读',
'',
'代码块有独立的语言标识和复制入口，普通文字中的 '+tick+'LoomConversation'+tick+' 则保持轻量。',
'',
fence+'smalltalk',
'"从活对象开始，逐步演进"',
'LoomConversation state.',
'',
'[ LMExecution checkpoint ] fork.',
fence,
'',
'> 让活动可见，同时把阅读的空间留给对话。',
'',
'你可以点击右上角的“演示流式输出”，体验正文逐步出现、活动同步更新的过程。'
].join('\n');
var activities=[
{id:'p1',type:'progress',title:'先确认现有能力',text:'检查原生 Markdown、列表与折叠组件，保留当前对话的连续性。',time:'10:48:02',status:'complete'},
{id:'t1',type:'tool',title:'读取界面实现',tool:'pharo_eval',duration:'104 ms',status:'complete',args:'(LMConversationUI >> #build) sourceCode',result:'已读取 LMConversationUI 的当前实现。\n布局：对话 70% / 活动 30%\n保留当前对象与会话。',open:false,tab:'args'},
{id:'t2',type:'tool',title:'检查渲染组件',tool:'pharo_eval',duration:'82 ms',status:'complete',args:"GtLMessageStyler selectors.\nBrSimpleList name.\nBrExpander name.",result:'已找到原生文本样式、表格和代码块组件。\n支持标题、列表、链接与可折叠详情。',open:false,tab:'args'},
{id:'p2',type:'progress',title:'整理阅读与交互层次',text:'正文保留完整表达，执行细节按需展开。滚动阅读时不会被新输出拉走。',time:'10:48:06',status:'complete'},
{id:'t3',type:'tool',title:'验证流式更新',tool:'pharo_eval',duration:'126 ms',status:'complete',args:"'中文分段与 Markdown 预览验证'",result:'✓ 中文片段完整\n✓ 正文增量更新\n✓ 工具状态与结果关联\n✓ 手动阅读位置保持',open:false,tab:'args'},
{id:'done',type:'progress',title:'本轮演示完成',text:'回复与活动均已展示。展开任意工具，可以查看参数和结果。',time:'10:48:14',status:'complete'}
];
var messages=[],filter='all',running=false,animation=null,sequence=0,follow=true,toastTimer=null,runStarted=0,streamingMessage=null,currentView='complete';
function cloneActivities(){return activities.map(function(e){return Object.assign({},e);});}
var events=cloneActivities();
function userMessage(text){return {id:'m'+(++sequence),role:'user',text:text,time:'刚刚'};}
function assistantMessage(text){return {id:'m'+(++sequence),role:'assistant',text:text,streaming:false,source:false};}
function renderMessages(){
 $('messages').innerHTML=messages.map(function(m){
  if(m.role==='user')return '<article class="message user-message"><div class="user-bubble">'+escapeHtml(m.text)+'</div><div class="user-meta">你 · '+escapeHtml(m.time)+'</div></article>';
  return '<article class="message assistant-message" data-message="'+m.id+'"><div class="assistant-head"><span>Loom</span><small>'+(m.streaming?'正在演示输出':'示例回复')+'</small></div><div class="markdown message-body">'+(m.source?'<pre class="source-view">'+escapeHtml(m.text)+'</pre>':renderMarkdown(m.text))+(m.streaming?'<span class="stream-cursor"></span>':'')+'</div><div class="message-actions"'+(m.streaming?' hidden':'')+'><button class="icon-button copy-message" data-id="'+m.id+'" aria-label="复制回复" title="复制 Markdown">'+icon('copy')+'</button><button class="icon-button toggle-source" data-id="'+m.id+'" aria-label="切换 Markdown 源码" title="查看 Markdown 源码">'+icon('source')+'</button><span class="response-time">已完成</span></div></article>';
 }).join('');
}
function setSummary(state,tools,elapsed){
 var badge=$('run-badge');badge.className='run-badge'+(state==='running'?' running':state==='error'?' failed':'');
 badge.innerHTML=state==='running'?'<span class="spinner"></span>执行中':(state==='error'?'需要关注':state==='stopped'?'已停止':'已完成');
 $('run-stats').textContent=tools+' 工具 · '+elapsed+'s';
 $('event-status').textContent=state==='running'?'正在接收演示事件':state==='stopped'?'演示已停止':'本轮事件已同步';
}
function renderActivities(){
 var visible=events.filter(function(e){return !e.hidden&&(filter==='all'||filter==='tools'&&e.type==='tool'||filter==='errors'&&e.status==='error');});
 var actual=events.filter(function(e){return !e.hidden;});
 $('all-count').textContent=actual.length;$('tool-count').textContent=actual.filter(function(e){return e.type==='tool';}).length;$('error-count').textContent=actual.filter(function(e){return e.status==='error';}).length;
 $('activity-list').innerHTML=visible.length?visible.map(function(e){
  var statusIcon=e.status==='running'?'<span class="spinner"></span>':(e.type==='tool'?icon(e.status==='error'?'alert':'check'):'');
  var start='<article class="activity-item'+(e.type==='progress'?' progress-item':'')+(e.open?' expanded':'')+'" data-event="'+e.id+'">'+(statusIcon?'<span class="timeline-icon '+(e.status==='error'?'error':e.status==='running'?'running':'success')+'">'+statusIcon+'</span>':'');
  if(e.type==='progress')return start+'<button class="progress-toggle" data-toggle="'+e.id+'" aria-expanded="'+!!e.open+'"><span class="progress-title">'+escapeHtml(e.title)+'</span><span class="progress-chevron">'+icon('chevron')+'</span></button><div class="progress-body">'+escapeHtml(e.text)+'</div><div class="event-time">'+escapeHtml(e.time)+'</div></article>';
  var detail=e.tab==='result'?e.result:e.args;
  return start+'<div class="tool-card'+(e.open?' open':'')+(e.status==='running'?' is-running':e.status==='error'?' is-error':'')+'"><button class="tool-summary" data-toggle="'+e.id+'" aria-expanded="'+e.open+'"><span class="tool-title"><strong>'+escapeHtml(e.title)+'</strong><small>'+escapeHtml(e.tool)+'</small></span><span class="tool-duration">'+escapeHtml(e.status==='running'?'执行中':e.status==='error'?'失败':e.duration)+'</span><span class="tool-chevron">'+icon('chevron')+'</span></button>'+(e.status==='error'?'<div class="error-inline">渲染检查未通过。展开结果查看原因。</div>':'')+(e.open?'<div class="tool-details"><div class="detail-tabs"><button class="detail-tab'+(e.tab==='args'?' active':'')+'" data-tab="args" data-event-id="'+e.id+'">参数</button><button class="detail-tab'+(e.tab==='result'?' active':'')+'" data-tab="result" data-event-id="'+e.id+'">结果</button><button class="detail-copy" data-copy-event="'+e.id+'" aria-label="复制当前详情">'+icon('copy')+'</button></div><pre>'+escapeHtml(detail)+'</pre></div>':'')+'</div></article>';
 }).join(''):'<div class="filter-empty">'+(filter==='errors'?'本轮没有异常':'还没有这类活动')+'</div>';
}
function scrollLatest(force){if(force||follow){$('chat-scroll').scrollTop=$('chat-scroll').scrollHeight;$('jump-latest').hidden=true;}else $('jump-latest').hidden=false;}
function toast(text){clearTimeout(toastTimer);$('toast').textContent=text;$('toast').classList.add('visible');toastTimer=setTimeout(function(){$('toast').classList.remove('visible');},1800);}
async function copy(text){
 try{if(navigator.clipboard&&window.isSecureContext)await navigator.clipboard.writeText(text);else{var field=document.createElement('textarea');field.value=text;field.style.position='fixed';field.style.opacity='0';document.body.appendChild(field);field.select();var success=document.execCommand('copy');field.remove();if(!success)throw new Error('copy');}toast('已复制');}catch(e){toast('复制不可用，可选中文字手动复制');}
}
function setRunning(value){
 running=value;$('stop').hidden=!value;$('generation-label').hidden=!value;$('send').disabled=value;$('replay').disabled=value;
}
function updateStreamingMessage(m){
 var article=document.querySelector('[data-message="'+m.id+'"]');if(!article){renderMessages();article=document.querySelector('[data-message="'+m.id+'"]');}
 article.querySelector('.message-body').innerHTML=renderMarkdown(m.text)+(m.streaming?'<span class="stream-cursor"></span>':'');
 article.querySelector('.assistant-head small').textContent=m.streaming?'正在演示输出':'示例回复';
 article.querySelector('.message-actions').hidden=m.streaming;
}
function beginStream(answer){
 if(running)return;
 setRunning(true);currentView='stream';follow=true;runStarted=performance.now();
 var m=assistantMessage('');m.streaming=true;streamingMessage=m;messages.push(m);
 events=cloneActivities().map(function(e){e.hidden=true;e.open=false;return e;});events[0].hidden=false;events[0].text='正在为你整理界面结构与阅读方式。';
 renderMessages();renderActivities();setSummary('running',0,'0.0');scrollLatest(true);
 var position=0,lastStage=-1;
 animation=setInterval(function(){
  var elapsed=(performance.now()-runStarted)/1000,stage=Math.min(4,Math.floor(elapsed/1.2));
  if(stage!==lastStage){
   events.forEach(function(e,index){e.hidden=index>stage;e.status=index===stage&&e.type==='tool'?'running':'complete';});
   if(stage===1||stage===2||stage===4){events[stage].open=true;events[stage].tab='args';}
   events.forEach(function(e,index){if(index<stage)e.open=false;});
   lastStage=stage;renderActivities();$('activity-scroll').scrollTop=$('activity-scroll').scrollHeight;
  }
  position=Math.min(answer.length,position+Math.max(3,Math.ceil(answer.length/110)));
  m.text=answer.slice(0,position);updateStreamingMessage(m);scrollLatest(false);
  setSummary('running',events.filter(function(e){return !e.hidden&&e.type==='tool';}).length,elapsed.toFixed(1));
  if(position>=answer.length){
   clearInterval(animation);animation=null;m.streaming=false;updateStreamingMessage(m);setRunning(false);streamingMessage=null;
   events=cloneActivities();renderActivities();setSummary('complete',3,elapsed.toFixed(1));scrollLatest(false);currentView='complete';
  }
 },90);
}
function stopStream(){
 if(!running)return;clearInterval(animation);animation=null;
 if(streamingMessage){streamingMessage.streaming=false;updateStreamingMessage(streamingMessage);var label=document.querySelector('[data-message="'+streamingMessage.id+'"] .response-time');if(label)label.textContent='已停止';}
 events.forEach(function(e){if(e.status==='running'){e.status='complete';e.duration='已停止';}});
 setRunning(false);streamingMessage=null;renderActivities();setSummary('stopped',events.filter(function(e){return !e.hidden&&e.type==='tool';}).length,((performance.now()-runStarted)/1000).toFixed(1));toast('流式演示已停止');
}
function reset(){
 if(animation)clearInterval(animation);animation=null;setRunning(false);streamingMessage=null;filter='all';
 document.querySelectorAll('.filter').forEach(function(b){b.classList.toggle('active',b.dataset.filter==='all');});
 messages=[userMessage(sampleUser),assistantMessage(sampleAnswer)];messages[0].time='10:48';
 events=cloneActivities();renderMessages();renderActivities();setSummary('complete',3,'12.4');follow=true;
 $('chat-scroll').scrollTop=0;$('jump-latest').hidden=true;currentView='complete';
}
$('chat-scroll').addEventListener('scroll',function(){var el=this;follow=el.scrollHeight-el.scrollTop-el.clientHeight<72;if(follow)$('jump-latest').hidden=true;},{passive:true});
$('jump-latest').addEventListener('click',function(){follow=true;scrollLatest(true);});
$('messages').addEventListener('click',function(e){
 var code=e.target.closest('[data-code]');if(code){copy(decodeURIComponent(code.dataset.code));return;}
 var copyButton=e.target.closest('.copy-message');if(copyButton){var m=messages.find(function(m){return m.id===copyButton.dataset.id;});if(m)copy(m.text);return;}
 var source=e.target.closest('.toggle-source');if(source){var message=messages.find(function(m){return m.id===source.dataset.id;});if(message){message.source=!message.source;var previous=$('chat-scroll').scrollTop;renderMessages();$('chat-scroll').scrollTop=previous;}}
});
$('activity-list').addEventListener('click',function(e){
 var toggle=e.target.closest('[data-toggle]');if(toggle){var entry=events.find(function(e){return e.id===toggle.dataset.toggle;});entry.open=!entry.open;renderActivities();return;}
 var tab=e.target.closest('[data-tab]');if(tab){var event=events.find(function(e){return e.id===tab.dataset.eventId;});event.tab=tab.dataset.tab;renderActivities();return;}
 var copyButton=e.target.closest('[data-copy-event]');if(copyButton){var eventToCopy=events.find(function(e){return e.id===copyButton.dataset.copyEvent;});copy(eventToCopy.tab==='result'?eventToCopy.result:eventToCopy.args);}
});
document.querySelectorAll('.filter').forEach(function(button){button.addEventListener('click',function(){filter=button.dataset.filter;document.querySelectorAll('.filter').forEach(function(b){b.classList.toggle('active',b===button);});renderActivities();});});
$('collapse-all').addEventListener('click',function(){events.forEach(function(e){e.open=false;});renderActivities();});
$('replay').addEventListener('click',function(){if(running)return;messages=[userMessage(sampleUser)];messages[0].time='刚刚';beginStream(sampleAnswer);});
$('stop').addEventListener('click',stopStream);
function submit(){
 var text=$('prompt').value.trim();if(!text||running)return;
 messages.push(userMessage(text));$('prompt').value='';$('prompt').style.height='';
 var reply=['这是**本地界面的交互演示**。你的消息已经显示在对话中，右侧活动也会同步变化。','','### 你刚刚输入的内容','','> '+text.replace(/\n/g,'\n> '),'','这份原型用于确认布局、Markdown 阅读和流式反馈。正式接入后，回复和活动将由 Loom 的真实事件驱动。'].join('\n');
 beginStream(reply);
}
$('composer-form').addEventListener('submit',function(e){e.preventDefault();submit();});
$('prompt').addEventListener('keydown',function(e){if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing&&e.keyCode!==229){e.preventDefault();submit();}});
$('prompt').addEventListener('input',function(){this.style.height='auto';this.style.height=Math.min(150,Math.max(42,this.scrollHeight))+'px';});
function toggleActivity(){
 var hide=$('workspace').classList.toggle('activity-hidden');$('activity-toggle').setAttribute('aria-expanded',String(!hide));
}
$('activity-toggle').addEventListener('click',toggleActivity);
$('more-toggle').addEventListener('click',function(){var open=$('more-menu').hidden;$('more-menu').hidden=!open;this.setAttribute('aria-expanded',String(open));});
document.addEventListener('click',function(e){if(!e.target.closest('.menu-wrap')){$('more-menu').hidden=true;$('more-toggle').setAttribute('aria-expanded','false');}});
$('copy-conversation').addEventListener('click',function(){copy(messages.map(function(m){return (m.role==='user'?'你':'Loom')+'\n\n'+m.text;}).join('\n\n---\n\n'));$('more-menu').hidden=true;});
$('reset-demo').addEventListener('click',function(){reset();$('more-menu').hidden=true;toast('已重置为初始预览');});
$('error-demo').addEventListener('click',function(){
 if(running)stopStream();events=cloneActivities();events[4].status='error';events[4].open=true;events[4].tab='result';events[4].result='示例错误：表格宽度超过容器。\n建议：使用横向滚动容器，保留正文阅读宽度。\n\n这是一条用于预览错误样式的演示事件。';events.pop();filter='all';
 document.querySelectorAll('.filter').forEach(function(b){b.classList.toggle('active',b.dataset.filter==='all');});
 renderActivities();setSummary('error',3,'12.4');$('more-menu').hidden=true;if($('workspace').classList.contains('activity-hidden'))toggleActivity();$('activity-scroll').scrollTop=$('activity-scroll').scrollHeight;
});
$('raw-events').addEventListener('click',function(){$('event-json').textContent=JSON.stringify({prototype:true,events:events.filter(function(e){return !e.hidden;})},null,2);$('event-dialog').showModal();});
$('dialog-close').addEventListener('click',function(){$('event-dialog').close();});
$('event-dialog').addEventListener('click',function(e){if(e.target===this){var r=this.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)this.close();}});
$('copy-events').addEventListener('click',function(){copy($('event-json').textContent);});
document.addEventListener('keydown',function(e){if(e.key==='Escape'){$('more-menu').hidden=true;$('more-toggle').setAttribute('aria-expanded','false');}});
var dragging=false;
function setWidth(width){var available=window.innerWidth;document.documentElement.style.setProperty('--activity-width',Math.min(Math.max(300,width),Math.min(620,available*.52))+'px');}
$('splitter').addEventListener('pointerdown',function(e){dragging=true;this.setPointerCapture(e.pointerId);this.classList.add('dragging');document.body.style.userSelect='none';});
$('splitter').addEventListener('pointermove',function(e){if(dragging)setWidth(window.innerWidth-e.clientX);});
$('splitter').addEventListener('pointerup',function(e){dragging=false;this.classList.remove('dragging');document.body.style.userSelect='';if(this.hasPointerCapture(e.pointerId))this.releasePointerCapture(e.pointerId);});
$('splitter').addEventListener('pointercancel',function(){dragging=false;this.classList.remove('dragging');document.body.style.userSelect='';});
$('splitter').addEventListener('keydown',function(e){if(e.key==='ArrowLeft'||e.key==='ArrowRight'){e.preventDefault();var current=$('activity-pane').getBoundingClientRect().width;setWidth(current+(e.key==='ArrowLeft'?20:-20));}});
if(window.innerWidth<800)$('workspace').classList.add('activity-hidden');
$('activity-toggle').setAttribute('aria-expanded',String(!$('workspace').classList.contains('activity-hidden')));
reset();
window.LoomPrototype={renderMarkdown:renderMarkdown,escapeHtml:escapeHtml,reset:reset,stop:stopStream};
})();
