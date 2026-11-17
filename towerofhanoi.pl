% towerofhanoi.pl - Tower of Hanoi, SWI-Prolog server + browser UI in ONE file.
% Run:  swipl towerofhanoi.pl      (or consult('towerofhanoi.pl') in swipl-win)
% Then Chrome opens http://localhost:8080/  (the page text is stored after end_of_file below)
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(www_browser)).
:- use_module(library(persistency)).
:- use_module(library(readutil)).
:- use_module(library(random)).
:- use_module(library(lists)).
:- use_module(library(aggregate)).
:- use_module(library(pairs)).

:- persistent score(mode:atom, name:atom, moves:integer, time:integer).
:- dynamic game/5, strict/1, src/1.
:- prolog_load_context(source, F), assertz(src(F)).

:- http_handler(root(.),            page,         []).
:- http_handler(root(api/modes),    api_modes,    []).
:- http_handler(root(api/new),      api_new,      []).
:- http_handler(root(api/move),     api_move,     []).
:- http_handler(root(api/undo),     api_undo,     []).
:- http_handler(root(api/restart),  api_restart,  []).
:- http_handler(root(api/pick),     api_pick,     []).
:- http_handler(root(api/score),    api_score,    []).
:- http_handler(root(api/scores),   api_scores,   []).
:- http_handler(root(api/rank),     api_rank,     []).

% ---------- rules: mode, discs, soft move limit factor ----------
gm(easy,      3, 1.5).
gm(hard,      5, 1.4).
gm(difficult, 7, 1.3).
gm(nightmare, 9, 1.25).

mode_info(M,N,Par,Lim) :- gm(M,N,F), Par is (1<<N)-1, Lim is ceiling(Par*F).

g(D,K,V) :- get_dict(K,D,V).

% pegs are 3 lists, top disc first. Disc 1 is the smallest.
step(Pg,F,T,Pg2) :-
    F \== T, nth0(F,Pg,[D|Rf]), nth0(T,Pg,To),
    ( To == [] ; To = [X|_], D < X ), !,
    setp(Pg,F,Rf,P1), setp(P1,T,[D|To],Pg2).
setp(L,I,V,L2) :- nth0(I,L,_,R), nth0(I,L2,V,R).

% ---------- API ----------
api_modes(_) :-
    findall(_{mode:M,n:N,par:P,limit:L}, (gm(M,N,_), mode_info(M,N,P,L)), Ls),
    reply_json_dict(Ls).

api_new(R) :-
    http_read_json_dict(R,D), g(D,mode,M0), atom_string(M,M0),
    mode_info(M,N,P,L), numlist(1,N,Ds), Id is random(1000000000),
    assertz(game(Id,M,[Ds,[],[]],0,[])),
    ( get_dict(strict,D,true) -> assertz(strict(Id)) ; true ),
    reply_json_dict(_{gid:Id,n:N,par:P,limit:L,pegs:[Ds,[],[]],moves:0}).

api_move(R) :-
    http_read_json_dict(R,D), g(D,gid,G), g(D,from,F), g(D,to,T),
    game(G,M,Pg,C,H), mode_info(M,N,_,Lim),
    (   step(Pg,F,T,Pg2)
    ->  C2 is C+1, retract(game(G,_,_,_,_)), assertz(game(G,M,Pg2,C2,[Pg-C|H])),
        nth0(2,Pg2,Goal), length(Goal,Len),
        ( Len =:= N -> W = true ; W = false ),
        ( C2 > Lim -> O = true ; O = false ),
        reply_json_dict(_{ok:true,pegs:Pg2,moves:C2,won:W,over:O})
    ;   reply_json_dict(_{ok:false})
    ).

% undo / restart are refused for strict (multiplayer) games
api_undo(R) :-
    http_read_json_dict(R,D), g(D,gid,G),
    (   \+ strict(G), game(G,M,_,_,[Pg-C|H])
    ->  retract(game(G,_,_,_,_)), assertz(game(G,M,Pg,C,H)),
        reply_json_dict(_{ok:true,pegs:Pg,moves:C})
    ;   reply_json_dict(_{ok:false})
    ).

api_restart(R) :-
    http_read_json_dict(R,D), g(D,gid,G),
    (   \+ strict(G), game(G,M,_,_,_)
    ->  mode_info(M,N,_,_), numlist(1,N,Ds),
        retract(game(G,_,_,_,_)), assertz(game(G,M,[Ds,[],[]],0,[])),
        reply_json_dict(_{ok:true,pegs:[Ds,[],[]],moves:0})
    ;   reply_json_dict(_{ok:false})
    ).

api_pick(_) :-
    random_member(M,[easy,hard,difficult,nightmare]), random_member(B,[moves,time]),
    reply_json_dict(_{mode:M,basis:B}).

save(M,N,Mv,T) :- catch(assert_score(M,N,Mv,T),_,assertz(score(M,N,Mv,T))).

api_score(R) :-
    http_read_json_dict(R,D), g(D,mode,M0), g(D,name,N0), g(D,moves,Mv), g(D,time,T),
    atom_string(M,M0), atom_string(N,N0), save(M,N,Mv,T),
    reply_json_dict(_{ok:true}).

api_scores(R) :-
    http_read_json_dict(R,D), g(D,mode,M0), g(D,basis,B0),
    atom_string(M,M0), atom_string(B,B0),
    findall(K-_{name:N,moves:Mv,time:T},
            ( score(M,N,Mv,T), ( B == time -> K = T-Mv ; K = Mv-T ) ), L0),
    keysort(L0,L), pairs_values(L,S),
    ( length(Top,5), append(Top,_,S) -> true ; Top = S ),
    reply_json_dict(Top).

% ranking with ties: rank = 1 + number of players strictly better
key(B,P,K) :- g(P,moves,M), g(P,time,T), ( B == time -> K = T-M ; K = M-T ).
api_rank(R) :-
    http_read_json_dict(R,D), g(D,basis,B0), atom_string(B,B0), g(D,players,Ps),
    findall(K-P, (member(P,Ps), key(B,P,K)), L),
    findall(Rk-P2, ( member(K-P,L), aggregate_all(count,(member(K2-_,L),K2 @< K),C),
                     Rk is C+1, put_dict(rank,P,Rk,P2) ), Q),
    keysort(Q,S), pairs_values(S,Rs),
    reply_json_dict(_{ranking:Rs}).

% ---------- page: everything after the marker line at the end of this file ----------
page(_) :-
    src(F), read_file_to_string(F,S,[]),
    atomic_list_concat(['@@','PAGE','@@'],M),
    sub_string(S,B,L,_,M), !,
    X is B+L, sub_string(S,X,_,0,T),
    format('Content-type: text/html; charset=UTF-8~n~n'), write(T).

start :-
    catch(http_server(http_dispatch,[port(8080)]),E,print_message(error,E)),
    catch(db_attach('hanoi_scores.db',[]),_,true),
    catch(www_open_url('http://localhost:8080/'),_,true),
    format("~nTower of Hanoi is running at http://localhost:8080/~n").

:- initialization(start).

end_of_file.
@@PAGE@@
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tower of Hanoi</title>
<style>
*{box-sizing:border-box}[hidden]{display:none!important}
body{--fg:#fff;--ac:#d8a;margin:0;height:100vh;overflow:hidden;font-family:'Segoe UI',system-ui,sans-serif;color:var(--fg);background:var(--bg);transition:background .8s}
.t-menu{--bg:linear-gradient(160deg,#1a1020,#33183f)}
.t-easy{--bg:linear-gradient(#ffe4ef,#ffc9de 70%,#f7a8c4);--fg:#5a2a3c;--ac:#e0568a}
.t-hard{--bg:linear-gradient(#4a1608,#c4531a 60%,#7a2a10);--fg:#fff1dc;--ac:#ff9b3d}
.t-difficult{--bg:linear-gradient(#050a2a,#1b1250 60%,#3a1a6a);--fg:#dff;--ac:#22e6ff}
.t-nightmare{--bg:linear-gradient(#0a0000,#3a0000 65%,#7a1000);--fg:#ffd9c9;--ac:#ff4a1c}
#fx,#flames{position:fixed;inset:0;pointer-events:none}
#flames{display:none;top:auto;height:26vh;filter:blur(8px);animation:fl 2.2s ease-in-out infinite alternate;background:radial-gradient(ellipse at 15% 110%,#ff5a0066,#0000 60%),radial-gradient(ellipse at 50% 115%,#ff2a0055,#0000 60%),radial-gradient(ellipse at 85% 110%,#ff8c0055,#0000 60%)}
@keyframes fl{from{opacity:.5;transform:scaleY(.9)}to{opacity:.9;transform:scaleY(1.15)}}
.t-nightmare #flames{display:block}
.mp.t-nightmare::after{content:'';position:absolute;left:0;right:0;bottom:0;height:35%;filter:blur(8px);animation:fl 2.2s infinite alternate;pointer-events:none;background:radial-gradient(ellipse at 30% 110%,#ff5a0077,#0000 65%),radial-gradient(ellipse at 75% 110%,#ff2a0066,#0000 65%)}
.scr{display:none;position:relative;z-index:2;height:100vh;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:12px}
.scr.on{display:flex}
.row{display:flex;gap:10px;flex-wrap:wrap;justify-content:center;align-items:center}
#sel{padding:0;gap:0;justify-content:flex-start}
#top{padding:8px}#top h1{margin:0;font-weight:300;letter-spacing:5px;font-size:clamp(16px,2.6vw,28px)}
#modes{display:flex;flex:1;width:100%;min-height:0}
.mp{position:relative;flex:1;min-width:0;overflow:hidden;cursor:pointer;transition:flex .55s cubic-bezier(.2,.8,.2,1);display:flex;flex-direction:column;align-items:center;justify-content:center;padding:10px;border-left:1px solid #fff3;background:var(--bg);color:var(--fg)}
.has .mp{flex:.6}.has .mp.act{flex:6}
.kan{font-size:clamp(36px,6vw,84px);text-shadow:0 0 20px var(--ac)}
.has .mp:not(.act) .kan{font-size:26px}
.mp h2{margin:4px 0;letter-spacing:3px;font-size:clamp(13px,1.7vw,22px);white-space:nowrap}
.has .mp:not(.act) h2{writing-mode:vertical-rl}
.pv,.inf,.go,.sub{opacity:0;transition:opacity .4s;pointer-events:none}
.act .pv,.act .inf,.act .go,.act .sub{opacity:1}
.pv{width:92%;max-width:540px;height:min(30vh,240px);margin:8px 0}
.q{font-size:110px;text-align:center;animation:pl 1s infinite alternate}
.go{margin-top:8px;padding:8px 22px;border:2px solid var(--ac);border-radius:30px;animation:pl 1.2s infinite alternate}
@keyframes pl{to{box-shadow:0 0 22px var(--ac)}}
.board{position:relative;display:flex;touch-action:none;user-select:none}
.board::after{content:'';position:absolute;left:0;right:0;bottom:0;height:10px;border-radius:5px;background:var(--ac);opacity:.7}
.col{flex:1;position:relative;cursor:pointer}
.rod{position:absolute;left:calc(50% - 5px);bottom:6px;width:10px;height:88%;border-radius:5px 5px 0 0;background:var(--ac);opacity:.5}
.disc{position:absolute;border-radius:9px;transition:left var(--sp,.17s) ease-in-out,bottom var(--sp,.17s) ease-out;pointer-events:none;z-index:3}
.disc.up{filter:brightness(1.25) drop-shadow(0 0 8px var(--ac))}
.t-easy .disc{background:linear-gradient(hsl(var(--h),60%,82%),hsl(var(--h),45%,60%));border:2px solid #8a5a3a;box-shadow:0 2px 4px #0004}
.t-hard .disc{background:linear-gradient(hsl(var(--h),85%,50%),hsl(var(--h),85%,28%));border:2px solid gold;box-shadow:inset 0 5px 6px #fff5,0 2px 6px #0008}
.t-difficult .disc{background:#0b0b2b;border:2px solid hsl(var(--h),100%,62%);box-shadow:0 0 12px hsl(var(--h),100%,60%),inset 0 0 8px hsl(var(--h),100%,60%)}
.t-nightmare .disc{background:linear-gradient(#2a2a2a,#050505);border:2px solid #5a1000;box-shadow:0 0 14px #f50,inset 0 0 8px #f306}
#gb{width:min(94vw,900px);height:min(50vh,380px)}
.p{position:fixed;pointer-events:none;z-index:50;font-style:normal;line-height:1}
.card{background:#0006;backdrop-filter:blur(8px);border:1px solid #fff3;border-radius:16px;padding:20px 26px;display:flex;flex-direction:column;align-items:center;gap:12px;width:min(94vw,560px);max-height:88vh;overflow:auto}
.t-easy .card{background:#fff9}
.in{display:flex;flex-direction:column;align-items:center;gap:10px;width:100%}
button,input{font:inherit}
button{cursor:pointer;color:var(--fg);background:#8883;border:2px solid var(--ac);border-radius:24px;padding:7px 16px}
button:hover,button.sel{background:var(--ac);color:#fff}
input[type=text]{width:100%;padding:8px 12px;border-radius:10px;border:2px solid var(--ac);margin:3px 0}
#hd{display:flex;gap:16px;flex-wrap:wrap;justify-content:center;font-size:clamp(13px,2vw,18px)}
.ov{background:#d22;color:#fff;border-radius:10px;padding:0 8px;animation:pl .6s infinite alternate}
.win{animation:pop .9s both;text-shadow:0 0 18px var(--ac);margin:0;text-align:center}
.st{font-size:40px;color:gold}
@keyframes pop{from{transform:scale(.3);opacity:0}to{transform:scale(1);opacity:1}}
table{border-collapse:collapse}td{padding:4px 10px;border-bottom:1px solid #fff3}
#gear{position:fixed;top:8px;right:10px;z-index:90;padding:2px 10px;font-size:20px}
#set,#rv{position:fixed;inset:0;display:none;align-items:center;justify-content:center}
#set{z-index:100;background:#000a}#set.on,#rv.on{display:flex}
#set .card{color:#fff;background:#222;width:min(90vw,340px)}#set label{display:flex;gap:8px;width:100%;justify-content:space-between}
#rv{z-index:110;background:#000e;color:#fff;flex-direction:column;font-size:12vmin;text-align:center}#rv small{font-size:5vmin;opacity:.8}.rvt{animation:pop .6s both}
@media(max-width:700px){#modes{flex-direction:column}.has .mp:not(.act) h2{writing-mode:horizontal-tb}.mp{border-left:0;border-top:1px solid #fff3}}
</style></head>
<body class="t-menu">
<div id="fx"></div><div id="flames"></div><button id="gear">&#9881;</button>

<section id="sel" class="scr on"><div id="top" class="row"><h1>&#12495;&#12494;&#12452;&#12398;&#22612; &middot; TOWER OF HANOI</h1><button id="pv">Preview sound: off</button></div><div id="modes"></div></section>

<section id="reg" class="scr"><div class="card"><h2 id="rt"></h2>
<div id="a" class="in"><p>Who is playing?</p><div id="np" class="row"></div><div id="ni" style="width:100%"></div><div id="er"></div><div class="row"><button id="bm">Back</button><button id="nx">Next</button></div></div>
<div id="b" class="in" hidden><p>Ranked by?</p><div id="bo" class="row"><button data-b="moves">Fewest Moves</button><button data-b="time">Fastest Time (min:sec)</button><button data-b="random">Random</button></div><div class="row"><button id="bb">Back</button><button id="go">Start Game</button></div></div>
</div></section>

<section id="game" class="scr"><div id="hd"></div><div id="gb" class="board"></div>
<div class="row"><button id="ub">Undo</button><button id="rb">Restart</button><button id="pz">Pause</button><button id="mb">Menu</button></div></section>

<section id="pass" class="scr"><div class="card"><div id="pt" style="text-align:center"></div><button id="pgo">I am ready</button></div></section>
<section id="end" class="scr"><div class="card" id="en"></div><div class="row"><button id="ag">Play again</button><button id="hm">Menu</button></div></section>

<div id="set"><div class="card"><h2>Settings</h2>
<label>Master <input id="s_m" type="range"></label><label>Music <input id="s_mu" type="range"></label><label>Sound effects <input id="s_fx" type="range"></label>
<label>Mute all <input id="s_mute" type="checkbox"></label><label>Animation effects <input id="s_anim" type="checkbox"></label><button id="sx">Close</button></div></div>
<div id="rv"></div>

<script>
const $=s=>document.querySelector(s),sleep=ms=>new Promise(r=>setTimeout(r,ms)),esc=s=>String(s).replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
const api=(u,b)=>fetch('/api/'+u,b?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}:{}).then(r=>r.json());
const fmt=s=>(s/60|0)+':'+String(s%60|0).padStart(2,'0');

/* ---- mode data: names, hues, music, particles ---- */
const MD={
 easy:{nm:'EASY',kan:'&#26716;',sub:'Sakura Garden',hue:[335,10],mu:{sc:[0,2,3,7,8,12],b:262,w:'triangle',t:650,d:1.4,v:.3}},
 hard:{nm:'HARD',kan:'&#32005;&#33865;',sub:'Momiji Temple',hue:[0,12],mu:{sc:[0,3,5,7,10],b:147,w:'triangle',t:420,d:.5,v:.3,k:75}},
 difficult:{nm:'DIFFICULT',kan:'&#22812;',sub:'Neon Tokyo Night',hue:[170,30],mu:{sc:[0,3,7,10,12,15],b:220,w:'sawtooth',t:240,d:.3,v:.08}},
 nightmare:{nm:'NIGHTMARE',kan:'&#39740;',sub:'Oni Inferno',hue:[355,6],mu:{sc:[0,1,5,6],b:110,w:'sawtooth',t:900,d:1.8,v:.1,dr:55,k:45}}};
const RD={nm:'RANDOM',kan:'&#36939;',sub:'Surprise Mode'};
const FX={easy:{ch:['\u2740','\u273F'],col:'#ff7fa8',r:500},hard:{ch:['\u{1F341}','\u{1F342}'],col:'#ff9b3d',r:500},
 difficult:{ch:['\u2726','\u2744'],col:'#22e6ff',r:450},nightmare:{ch:['\u25CF','\u2022'],col:'#ff6a1c',r:350}};

/* ---- settings + audio (all sounds synthesized, no files) ---- */
let cfg=Object.assign({m:.8,mu:.6,fx:.9,mute:false,anim:true},JSON.parse(localStorage.hcfg||'{}'));
let AC,gM,gMu,gFx,dr,mt,pvOn=false;
function aud(){if(AC){AC.state=='suspended'&&AC.resume();return}AC=new(window.AudioContext||window.webkitAudioContext)();gM=AC.createGain();gMu=AC.createGain();gFx=AC.createGain();gMu.connect(gM);gFx.connect(gM);gM.connect(AC.destination);vol()}
function vol(){localStorage.hcfg=JSON.stringify(cfg);if(AC){gM.gain.value=cfg.mute?0:cfg.m;gMu.gain.value=cfg.mu;gFx.gain.value=cfg.fx}}
function tone(f,d,w,v,bus,t,to){if(!AC)return;const o=AC.createOscillator(),g=AC.createGain(),s=AC.currentTime+(t||0);o.type=w||'sine';o.frequency.setValueAtTime(f,s);to&&o.frequency.exponentialRampToValueAtTime(to,s+d);g.gain.setValueAtTime(v||.3,s);g.gain.exponentialRampToValueAtTime(.001,s+d);o.connect(g);g.connect(bus||gFx);o.start(s);o.stop(s+d+.05)}
function nz(d,v,fq){if(!AC)return;const n=AC.sampleRate*d|0,b=AC.createBuffer(1,n,AC.sampleRate),a=b.getChannelData(0);for(let i=0;i<n;i++)a[i]=Math.random()*2-1;const s=AC.createBufferSource(),f=AC.createBiquadFilter(),g=AC.createGain();s.buffer=b;f.type='lowpass';f.frequency.value=fq;g.gain.setValueAtTime(v,AC.currentTime);g.gain.exponentialRampToValueAtTime(.001,AC.currentTime+d);s.connect(f);f.connect(g);g.connect(gFx);s.start()}
function sfx(t,k){if(!AC)return;
 if(t=='lift')tone(420,.12,'triangle',.25,0,0,820);
 else if(t=='err'){tone(130,.25,'square',.2);tone(95,.3,'square',.2,0,.1)}
 else if(t=='win')[0,4,7,12,16].forEach((s,i)=>tone(392*2**(s/12),.6,'triangle',.3,0,i*.14));
 else if(k=='easy'){tone(660,.5,'triangle',.35);tone(990,.4,'sine',.15,0,.05)}
 else if(k=='hard'){tone(120,.3,'sine',.7,0,0,45);nz(.12,.5,900)}
 else if(k=='difficult'){tone(880,.25,'sawtooth',.12,0,0,330);tone(1320,.2,'square',.06,0,.04)}
 else{tone(75,.55,'sawtooth',.4,0,0,30);nz(.3,.5,500)}}
function music(k){clearInterval(mt);if(dr){try{dr.stop()}catch(e){}dr=null}if(!k||!AC)return;const c=MD[k].mu;let i=0;
 if(c.dr){dr=AC.createOscillator();const g=AC.createGain();dr.type='sawtooth';dr.frequency.value=c.dr;g.gain.value=.05;dr.connect(g);g.connect(gMu);dr.start()}
 mt=setInterval(()=>{tone(c.b*2**(c.sc[Math.random()*c.sc.length|0]/12),c.d,c.w,c.v,gMu);if(c.k&&i%3==0)tone(c.k*2,.35,'sine',.6,gMu,0,c.k/2);i++},c.t)}

/* ---- particles, ambient theme effects, celebration ---- */
function burst(x,y,ch,n,col){if(!cfg.anim)return;for(let i=0;i<n;i++){const e=document.createElement('i'),a=Math.random()*6.28,r=30+Math.random()*60;e.className='p';e.textContent=ch[i%ch.length];e.style.cssText=`left:${x}px;top:${y}px;color:${col}`;document.body.append(e);
 e.animate([{transform:'translate(0,0) scale(1)',opacity:1},{transform:`translate(${Math.cos(a)*r}px,${Math.sin(a)*r-30}px) rotate(${Math.random()*360}deg) scale(.4)`,opacity:0}],{duration:700+Math.random()*400}).onfinish=()=>e.remove()}}
function fall(ch,up,col,z){if(!cfg.anim)return;const e=document.createElement('i'),dx=(Math.random()-.5)*200;e.className='p';e.textContent=ch;
 e.style.cssText=`left:${Math.random()*innerWidth}px;top:${up?105:-6}vh;font-size:${12+Math.random()*16}px;color:${col};z-index:${z||1};opacity:.85`;document.body.append(e);
 e.animate([{transform:'translate(0,0) rotate(0)'},{transform:`translate(${dx}px,${up?-115:115}vh) rotate(${Math.random()*720}deg)`}],{duration:6000+Math.random()*5000}).onfinish=()=>e.remove()}
let AM,TH;
function amb(k){clearInterval(AM);if(!k||!cfg.anim)return;const f=FX[k];AM=setInterval(()=>fall(f.ch[Math.random()*f.ch.length|0],k=='nightmare',f.col),f.r)}
function theme(k){TH=k;document.body.className='t-'+(k||'menu');amb(k)}
function fire(n){for(let i=0;i<n;i++)setTimeout(()=>{tone(300+Math.random()*400,.3,'triangle',.15,0,0,80);burst(innerWidth*(.15+Math.random()*.7),innerHeight*(.15+Math.random()*.4),['\u2726','\u2736','\u2022'],22,'hsl('+(Math.random()*360|0)+',100%,65%)')},i*260)}
function party(){const cs=['\u{1F3EE}','\u{1F38A}','\u2740','\u{1F338}'];for(let i=0;i<50;i++)setTimeout(()=>fall(cs[i%4],i%3==0,'#fff',60),i*120);fire(10)}

/* ---- board: DOM discs, arc move animation, per-mode landing effects ---- */
function mkBoard(el,k,n,pegs){
 el.innerHTML='<div class="col"><i class="rod"></i></div>'.repeat(3);
 const B={el,k,n,d:{},pegs:pegs.map(p=>p.slice())},W=()=>el.clientWidth,H=()=>el.clientHeight,q=()=>B.dm&&!pvOn;
 B.dh=()=>Math.min(30,(H()-30)/n);B.w=s=>W()/3*(.3+.66*s/n);B.x=c=>W()*(c+.5)/3;B.y=l=>8+l*B.dh();
 B.put=(s,c,l)=>{const S=B.d[s].style;S.width=B.w(s)+'px';S.height=B.dh()-3+'px';S.left=B.x(c)-B.w(s)/2+'px';S.bottom=B.y(l)+'px'};
 B.layout=()=>B.pegs.forEach((p,c)=>p.forEach((s,i)=>B.put(s,c,p.length-1-i)));
 for(let s=1;s<=n;s++){const d=document.createElement('div');d.className='disc';d.style.setProperty('--h',(MD[k].hue[0]+s*MD[k].hue[1])%360);el.append(d);B.d[s]=d}
 B.lift=c=>{const d=B.d[B.pegs[c][0]];d.classList.add('up');d.style.bottom=H()-B.dh()-4+'px'};
 B.drop=c=>{const p=B.pegs[c];if(!p.length)return;const d=B.d[p[0]];d.style.transition='';d.classList.remove('up');B.put(p[0],c,p.length-1)};
 B.shake=()=>el.animate([{transform:'translateX(0)'},{transform:'translateX(-9px)'},{transform:'translateX(9px)'},{transform:'translateX(0)'}],{duration:260});
 B.mv=async(f,t,fast)=>{const s=B.pegs[f].shift(),d=B.d[s],sp=fast?100:cfg.anim?170:70;d.style.transition='';d.style.setProperty('--sp',sp+'ms');
  if(!d.classList.contains('up')&&!q())sfx('lift');
  d.classList.add('up');d.style.bottom=H()-B.dh()-4+'px';await sleep(sp);
  d.style.left=B.x(t)-B.w(s)/2+'px';
  if(k=='difficult'&&cfg.anim)for(let i=0;i<5;i++)setTimeout(()=>{const r=d.getBoundingClientRect();burst(r.left+r.width/2,r.top+r.height/2,['\u2726'],2,FX[k].col)},i*sp/3);
  await sleep(sp*1.5);
  const l=B.pegs[t].length;B.pegs[t].unshift(s);d.style.bottom=B.y(l)+'px';await sleep(sp);
  d.classList.remove('up');if(!q())sfx('land',k);const r=d.getBoundingClientRect();burst(r.left+r.width/2,r.bottom,FX[k].ch,k=='easy'?10:8,FX[k].col)};
 B.layout();return B}

/* ---- mode select: joined panels, hover focus, live demo ---- */
let INFO=[],cur=null,DM=null,ft;
function stopDemo(){if(DM){DM.on=0;DM=null}}
function demo(p,k){const n=Math.min(INFO.find(x=>x.mode==k).n,5),el=p.querySelector('.pv'),id=DM={on:1},st=()=>[[...Array(n)].map((_,i)=>i+1),[],[]],mvs=[];
 (function h(n,a,b,c){if(n){h(n-1,a,c,b);mvs.push([a,b]);h(n-1,c,b,a)}})(n,0,2,1);
 (async()=>{await sleep(650);if(!id.on)return;const B=mkBoard(el,k,n,st());B.dm=1;
  while(id.on){for(const[f,t]of mvs){if(!id.on)return;await B.mv(f,t,1);await sleep(110)}await sleep(1000);B.pegs=st();B.layout();await sleep(900)}})()}
function foc(p,k){if(cur===p)return;stopDemo();cur=p;const m=$('#modes');m.classList.toggle('has',!!p);[...m.children].forEach(c=>c.classList.toggle('act',c===p));if(p&&k!='random')demo(p,k)}
function menu(){const m=$('#modes');m.innerHTML='';m.classList.remove('has');cur=null;
 [...INFO.map(i=>i.mode),'random'].forEach(k=>{const D=MD[k]||RD,i=INFO.find(x=>x.mode==k),p=document.createElement('div');p.className='mp t-'+(i?k:'menu');
  p.innerHTML=`<div class="kan">${D.kan}</div><h2>${D.nm}</h2><div class="pv${i?' board':''}">${i?'':'<div class="q">?</div>'}</div><div class="inf">${i?i.n+' discs &middot; Par '+i.par+' &middot; Limit '+i.limit:'Mode is revealed when the game starts'}</div><div class="sub">${D.sub}</div><div class="go">Click to play</div>`;
  p.onpointerdown=e=>p.tc=e.pointerType=='touch';
  p.onmouseenter=()=>{p.fr=1;clearTimeout(ft);ft=setTimeout(()=>foc(p,k),90)};
  p.onclick=()=>{aud();if(cur===p&&!(p.tc&&p.fr))pick(k);else foc(p,k);p.fr=0};
  m.append(p)})}
$('#modes').onmouseleave=()=>{clearTimeout(ft);foc(null)};
$('#pv').onclick=()=>{aud();pvOn=!pvOn;$('#pv').textContent='Preview sound: '+(pvOn?'on':'off')};

/* ---- flow: names -> basis -> (random reveal) -> play ---- */
let S={},G={},GB,busy=false,paused=false,t0=0,acc=0,tt,sel=null;
function show(id){document.querySelectorAll('.scr').forEach(s=>s.classList.toggle('on',s.id==id))}
function pick(k){foc(null);S={mode:k,basis:'moves',players:[''],res:[],cur:0};theme(k=='random'?null:k);regA();show('reg')}
function sync(){S.players=[...document.querySelectorAll('#ni input')].map(i=>i.value)}
function regA(){$('#a').hidden=0;$('#b').hidden=1;$('#er').textContent='';const np=S.players.length;
 $('#rt').innerHTML=MD[S.mode]?MD[S.mode].nm+' - '+MD[S.mode].sub:'RANDOM MODE - surprise!';
 $('#np').innerHTML=[1,2,3,4].map(i=>`<button class="${i==np?'sel':''}" data-n="${i}">${i==1?'Single':i+' Players'}</button>`).join('');
 $('#ni').innerHTML=S.players.map((v,i)=>`<input type="text" maxlength="14" placeholder="${np>1?'Player '+(i+1)+' name':'Your name'}" value="${esc(v)}">`).join('')}
$('#np').onclick=e=>{const n=+e.target.dataset.n;if(!n)return;sync();S.players=Array.from({length:n},(_,i)=>S.players[i]||'');regA()};
function setB(b){S.basis=b;[...$('#bo').children].forEach(c=>c.classList.toggle('sel',c.dataset.b==b))}
$('#bo').onclick=e=>e.target.dataset.b&&setB(e.target.dataset.b);
$('#nx').onclick=()=>{sync();if(!S.players.every(v=>v.trim())){$('#er').textContent='Please enter every name.';return}S.players=S.players.map(v=>v.trim());$('#a').hidden=1;$('#b').hidden=0;setB(S.basis)};
$('#bm').onclick=home;$('#bb').onclick=regA;$('#go').onclick=begin;
async function reveal(parts){const r=$('#rv'),nm=Object.values(MD).map(m=>m.nm);r.classList.add('on');
 for(let i=0;i<14;i++){r.innerHTML=`<div>?</div><small>${nm[i%4]}</small>`;tone(300+i*40,.08,'square',.1);await sleep(90)}
 r.innerHTML=parts.map(x=>`<div class="rvt">${x}</div>`).join('');sfx('win');await sleep(1800);r.classList.remove('on')}
async function begin(){aud();const rm=S.mode=='random',rb=S.basis=='random';let pk={};if(rm||rb)pk=await api('pick');
 S.k=rm?pk.mode:S.mode;S.bs=rb?pk.basis:S.basis;
 if(rm||rb){const p=[];rm&&p.push(MD[S.k].kan+' '+MD[S.k].nm);rb&&p.push('Ranked by '+(S.bs=='time'?'fastest time':'fewest moves'));await reveal(p)}
 theme(S.k);music(S.k);S.cur=0;S.res=[];S.players.length>1?pass():play()}
function pass(){const L=S.res[S.res.length-1];$('#pt').innerHTML=(L?`${esc(L.name)} finished: ${L.moves} moves, ${fmt(L.time)}<br>`:'')+`Pass the mouse to<h2>${esc(S.players[S.cur])}</h2>`;show('pass')}
$('#pgo').onclick=()=>{aud();play()};
function home(){clearInterval(tt);music(null);theme(null);menu();show('sel')}
$('#mb').onclick=home;$('#hm').onclick=home;$('#ag').onclick=()=>pick(S.mode);

/* ---- game: hud, timer, mouse (drag-drop or click-click), undo/restart/pause ---- */
const elapsed=()=>paused?acc:acc+(Date.now()-t0)/1000;
function hud(){const o=G.moves-G.limit;$('#hd').innerHTML=`<b>${esc(S.players[S.cur])}</b><span>${MD[S.k].nm}</span><span>Moves <b>${G.moves}</b></span><span>Par ${G.par}</span><span>Limit ${G.limit}</span>${o>0?`<span class="ov">OVER LIMIT +${o}</span>`:''}<span id="tm">${fmt(elapsed())}</span>`}
async function play(){const g=await api('new',{mode:S.k,strict:S.players.length>1});G={gid:g.gid,par:g.par,limit:g.limit,moves:0};
 show('game');GB=mkBoard($('#gb'),S.k,g.n,g.pegs);wire();$('#ub').hidden=$('#rb').hidden=S.players.length>1;
 sel=null;busy=false;paused=false;acc=0;t0=Date.now();$('#gb').style.visibility='';$('#pz').textContent='Pause';hud();
 clearInterval(tt);tt=setInterval(()=>{const t=$('#tm');t&&(t.textContent=fmt(elapsed()))},250)}
async function attempt(f,c){busy=true;const r=await api('move',{gid:G.gid,from:f,to:c});
 if(!r.ok){GB.drop(f);GB.shake();sfx('err');busy=false;return}
 await GB.mv(f,c);G.moves=r.moves;hud();if(r.won){await finish();return}busy=false}
function wire(){const el=GB.el;let drag=0,mvd=0,sx,sy;
 const col=x=>Math.max(0,Math.min(2,((x-el.getBoundingClientRect().left)/el.clientWidth*3)|0));
 el.onpointerdown=async e=>{if(busy||paused)return;aud();const c=col(e.clientX);
  if(sel==null){if(!GB.pegs[c].length)return;sel=c;drag=1;mvd=0;sx=e.clientX;sy=e.clientY;GB.lift(c);sfx('lift');el.setPointerCapture(e.pointerId)}
  else{const f=sel;sel=null;if(f==c){GB.drop(f);return}await attempt(f,c)}};
 el.onpointermove=e=>{if(!drag)return;if(Math.hypot(e.clientX-sx,e.clientY-sy)>8)mvd=1;
  if(mvd){const d=GB.d[GB.pegs[sel][0]],r=el.getBoundingClientRect();d.style.transition='none';d.style.left=e.clientX-r.left-d.offsetWidth/2+'px';d.style.bottom=r.bottom-e.clientY-d.offsetHeight/2+'px'}};
 el.onpointerup=async e=>{if(!drag)return;drag=0;if(mvd){const f=sel,c=col(e.clientX);sel=null;if(c==f)GB.drop(f);else await attempt(f,c)}}}
$('#ub').onclick=async()=>{if(busy||paused)return;if(sel!=null){GB.drop(sel);sel=null}const r=await api('undo',{gid:G.gid});if(!r.ok)return;GB.pegs=r.pegs;GB.layout();sfx('lift');G.moves=r.moves;hud()};
$('#rb').onclick=async()=>{if(busy||paused)return;sel=null;const r=await api('restart',{gid:G.gid});if(!r.ok)return;GB.pegs=r.pegs;GB.layout();G.moves=0;acc=0;t0=Date.now();hud()};
$('#pz').onclick=()=>{paused=!paused;if(paused){acc+=(Date.now()-t0)/1000;if(sel!=null){GB.drop(sel);sel=null}}else t0=Date.now();$('#gb').style.visibility=paused?'hidden':'';$('#pz').textContent=paused?'Resume':'Pause'};
async function finish(){clearInterval(tt);const t=Math.round(elapsed()),p=S.players[S.cur];
 S.res.push({name:p,moves:G.moves,time:t,par:G.par,limit:G.limit});api('score',{mode:S.k,name:p,moves:G.moves,time:t});
 sfx('win');fire(5);await sleep(1700);if(++S.cur<S.players.length)pass();else end()}

/* ---- results: congratulation (single) or ranked table + winner (multi) ---- */
async function end(){const[r,lb]=await Promise.all([api('rank',{basis:S.bs,players:S.res}),api('scores',{mode:S.k,basis:S.bs})]);
 const R=r.ranking,st=p=>p.moves<=p.par?3:p.moves<=p.limit?2:1,
 stars=p=>'\u2605'.repeat(st(p))+'\u2606'.repeat(3-st(p))+(p.moves>p.limit?' (Over limit)':'');let h;
 if(R.length==1){const p=R[0];h=`<h1 class="win">Congratulations, ${esc(p.name)}!</h1><div class="st">${stars(p)}</div><p>${p.moves} moves (par ${p.par}) &middot; ${fmt(p.time)}</p>`}
 else{const w=R.filter(p=>p.rank==1);
  h=`<h1 class="win">${w.length>1?'It is a tie: '+w.map(p=>esc(p.name)).join(' &amp; '):esc(w[0].name)+' wins!'}</h1><p>Ranked by ${S.bs=='time'?'fastest time':'fewest moves'}</p><table>`+R.map(p=>`<tr><td>#${p.rank}</td><td>${esc(p.name)}</td><td>${p.moves} moves</td><td>${fmt(p.time)}</td><td>${stars(p)}</td></tr>`).join('')+'</table>'}
 h+=`<h3>Best scores - ${MD[S.k].nm}</h3><div>`+lb.map((x,i)=>`${i+1}. ${esc(x.name)} - ${x.moves} moves, ${fmt(x.time)}`).join('<br>')+'</div>';
 $('#en').innerHTML=h;show('end');party()}

/* ---- settings ---- */
$('#gear').onclick=()=>{aud();$('#set').classList.add('on')};$('#sx').onclick=()=>$('#set').classList.remove('on');
['m','mu','fx'].forEach(k=>{const e=$('#s_'+k);e.value=cfg[k]*100;e.oninput=()=>{cfg[k]=e.value/100;vol()}});
$('#s_mute').checked=cfg.mute;$('#s_mute').onchange=e=>{cfg.mute=e.target.checked;vol()};
$('#s_anim').checked=cfg.anim;$('#s_anim').onchange=e=>{cfg.anim=e.target.checked;vol();amb(TH)};
document.addEventListener('pointerdown',aud);
onresize=()=>GB&&GB.layout();
(async()=>{INFO=await api('modes');menu()})();
</script></body></html>
