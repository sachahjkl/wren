(function(){
var box=document.getElementById('doc-search-input');
var out=document.getElementById('doc-search-results');
if(!box||!out)return;
var idx=null,loading=false;
function load(cb){if(idx){cb();return;}if(loading)return;loading=true;
fetch('/docs/search-index.json').then(function(r){return r.json();}).then(function(d){idx=d;cb();});}
function norm(s){return (s||'').toLowerCase();}
function score(d,terms){var t=norm(d.t),s=norm(d.s),b=norm(d.b),sc=0;
for(var i=0;i<terms.length;i++){var w=terms[i];if(!w)continue;var hit=0;
if(t.indexOf(w)>=0){sc+=10;hit=1;}if(s.indexOf(w)>=0){sc+=4;hit=1;}
var p=b.indexOf(w);if(p>=0){sc+=2;hit=1;}if(!hit)return 0;}
return sc;}
function snippet(b,terms){var t=norm(b),p=-1;
for(var i=0;i<terms.length;i++){var q=t.indexOf(terms[i]);if(q>=0&&(p<0||q<p))p=q;}
if(p<0)p=0;var start=Math.max(0,p-40);var s=b.slice(start,start+150);
return (start>0?'…':'')+s+(start+150<b.length?'…':'');}
function esc(s){return s.replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
function run(){var q=box.value.trim();if(!q){out.hidden=true;out.innerHTML='';return;}
load(function(){var terms=norm(q).split(/\s+/);var hits=[];
for(var i=0;i<idx.length;i++){var sc=score(idx[i],terms);if(sc>0)hits.push([sc,idx[i]]);}
hits.sort(function(a,b){return b[0]-a[0];});hits=hits.slice(0,8);
if(!hits.length){out.innerHTML='<p class="doc-search-none">No matches.</p>';out.hidden=false;return;}
var h='<ul>';for(var i=0;i<hits.length;i++){var d=hits[i][1];
h+='<li><a href="'+d.u+'"><span class="r-sec">'+esc(d.s||'')+'</span><strong>'+esc(d.t)+'</strong>'+
'<span class="r-snip">'+esc(snippet(d.b,terms))+'</span></a></li>';}
h+='</ul>';out.innerHTML=h;out.hidden=false;});}
box.addEventListener('input',run);
box.addEventListener('keydown',function(e){if(e.key==='Escape'){box.value='';out.hidden=true;box.blur();}
if(e.key==='Enter'){var a=out.querySelector('a');if(a){e.preventDefault();location.href=a.href;}}});
document.addEventListener('keydown',function(e){if(e.key==='/'&&document.activeElement!==box){
var tag=(document.activeElement||{}).tagName;if(tag==='INPUT'||tag==='TEXTAREA')return;
e.preventDefault();box.focus();}});
document.addEventListener('click',function(e){if(!out.contains(e.target)&&e.target!==box)out.hidden=true;});
})();
