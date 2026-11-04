import Foundation

/// The single-page web UI served by `WiFiTransferServer`.
enum WiFiTransferPage {
    static let faviconSVG = #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path fill="#FFB23F" d="M10 6l14 12h16L54 6v30c0 13-10 22-22 22S10 49 10 36z"/><circle cx="24" cy="34" r="4" fill="#1b1622"/><circle cx="40" cy="34" r="4" fill="#1b1622"/><path d="M29 42h6l-3 3z" fill="#1b1622"/></svg>
"""#

    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MuurMusic Wi-Fi Transfer</title>
<link rel="icon" href="/favicon.ico" type="image/svg+xml">
<style>
:root { --bg:#14111a; --card:#1f1a28; --line:#2e2739; --text:#f3eefa; --muted:#a69cb5; --accent:#FFB23F; --accent2:#8B6CFF; --bad:#ff6b81; --good:#5EE0C0; }
* { box-sizing:border-box; }
body { margin:0; font:15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background:radial-gradient(circle at 20% 0%, #2a2040 0, var(--bg) 55%); color:var(--text); min-height:100vh; }
main { max-width:860px; margin:0 auto; padding:28px 18px 60px; }
header { display:flex; align-items:center; gap:18px; margin-bottom:22px; }
header h1 { margin:0; font-size:26px; letter-spacing:.3px; }
header p { margin:2px 0 0; color:var(--muted); }
.cat { width:84px; height:84px; flex:none; }
.cat .eye { transform-origin:center; animation:blink 5s infinite; }
.cat .tail { transform-origin:88px 92px; animation:wag 3s ease-in-out infinite; }
body.busy .cat .tail { animation-duration:.6s; }
body.busy .cat .eye { animation:none; }
@keyframes blink { 0%,92%,100% { transform:scaleY(1); } 95% { transform:scaleY(.1); } }
@keyframes wag { 0%,100% { transform:rotate(-8deg); } 50% { transform:rotate(14deg); } }
.card { background:var(--card); border:1px solid var(--line); border-radius:18px; padding:20px; margin-bottom:18px; box-shadow:0 10px 30px rgba(0,0,0,.25); }
.drop { border:2px dashed #4a3f5c; border-radius:16px; padding:34px 16px; text-align:center; transition:.15s; cursor:pointer; }
.drop.over { border-color:var(--accent); background:rgba(255,178,63,.07); transform:scale(1.01); }
.drop strong { display:block; font-size:18px; margin-bottom:4px; }
.drop span { color:var(--muted); }
.paws { font-size:22px; letter-spacing:6px; opacity:.8; margin-bottom:6px; }
.buttons { display:flex; flex-wrap:wrap; gap:10px; justify-content:center; margin-top:16px; }
button, .btn { font:inherit; border:0; border-radius:999px; padding:9px 18px; background:var(--accent); color:#1b1622; font-weight:600; cursor:pointer; text-decoration:none; display:inline-block; }
button.secondary { background:#332b40; color:var(--text); }
button.icon { padding:4px 10px; background:transparent; color:var(--muted); font-weight:500; }
button.icon:hover { color:var(--bad); }
input[type=file] { display:none; }
.queue .item, .files .row { display:flex; align-items:center; gap:12px; padding:9px 0; border-bottom:1px solid var(--line); }
.queue .item:last-child, .files .row:last-child { border-bottom:0; }
.name { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.meta { color:var(--muted); font-size:13px; white-space:nowrap; }
.bar { height:6px; background:#332b40; border-radius:6px; overflow:hidden; width:140px; flex:none; }
.bar i { display:block; height:100%; width:0; background:linear-gradient(90deg, var(--accent), var(--accent2)); transition:width .2s; }
.ok { color:var(--good); } .err { color:var(--bad); }
h2 { margin:0 0 10px; font-size:17px; display:flex; justify-content:space-between; align-items:center; }
.empty { color:var(--muted); text-align:center; padding:10px 0; }
.login { max-width:340px; margin:40px auto; text-align:center; }
.login input { font:inherit; font-size:28px; letter-spacing:10px; text-align:center; width:100%; padding:10px; border-radius:14px; border:1px solid var(--line); background:#151119; color:var(--text); margin:14px 0; }
.hidden { display:none !important; }
a.file { color:var(--text); text-decoration:none; } a.file:hover { color:var(--accent); }
footer { text-align:center; color:var(--muted); font-size:13px; margin-top:30px; }
</style>
</head>
<body>
<main>
<header>
  <svg class="cat" viewBox="0 0 120 120" aria-hidden="true">
    <path class="tail" d="M88 92c18-2 22-20 14-30" stroke="#FFB23F" stroke-width="9" fill="none" stroke-linecap="round"/>
    <path d="M22 18l20 18h36l20-18v52c0 24-18 40-38 40S22 94 22 70z" fill="#FFB23F"/>
    <path d="M30 30l9 9M90 30l-9 9" stroke="#e0952a" stroke-width="5" stroke-linecap="round"/>
    <ellipse class="eye" cx="46" cy="64" rx="6" ry="8" fill="#1b1622"/>
    <ellipse class="eye" cx="74" cy="64" rx="6" ry="8" fill="#1b1622"/>
    <path d="M55 78h10l-5 6z" fill="#1b1622"/>
    <path d="M60 84c-3 6-10 6-12 2M60 84c3 6 10 6 12 2" stroke="#1b1622" stroke-width="2.5" fill="none" stroke-linecap="round"/>
    <path d="M38 80H18M38 86l-18 5M82 80h20M82 86l18 5" stroke="#1b1622" stroke-width="2" stroke-linecap="round"/>
  </svg>
  <div>
    <h1>MuurMusic Wi-Fi Transfer</h1>
    <p id="device">Feed the cat some music.</p>
  </div>
</header>

<section id="login" class="card login hidden">
  <h2 style="justify-content:center">Enter the PIN</h2>
  <p class="meta">The PIN is shown in MuurMusic on your device.</p>
  <form id="loginForm" method="post" action="/api/login">
    <input id="pin" name="pin" inputmode="numeric" autocomplete="one-time-code" maxlength="12" required>
    <button type="submit">Unlock</button>
  </form>
  <p id="loginError" class="err"></p>
</section>

<div id="app" class="hidden">
  <section class="card">
    <div id="drop" class="drop">
      <div class="paws">&#128062; &#128062; &#128062;</div>
      <strong>Drop music files or folders here</strong>
      <span>FLAC, ALAC, MP3, DSD, WAV, playlists, lyrics, artwork and ZIP archives</span>
      <div class="buttons">
        <button type="button" id="pickFiles">Choose files</button>
        <button type="button" class="secondary" id="pickFolder">Choose a folder</button>
      </div>
    </div>
    <input type="file" id="files" multiple>
    <input type="file" id="folder" webkitdirectory directory multiple>
  </section>

  <section class="card">
    <h2>Uploads <button class="icon" id="clearDone" type="button">Clear finished</button></h2>
    <div id="queue" class="queue"><div class="empty">Nothing uploading. The cat is napping.</div></div>
  </section>

  <section class="card">
    <h2><span>On the device</span><span class="meta" id="free"></span></h2>
    <div id="fileList" class="files"><div class="empty">Loading&hellip;</div></div>
  </section>
</div>

<noscript>
  <section class="card">
    <form method="post" action="/api/login"><input name="pin" placeholder="PIN"> <button>Unlock</button></form>
    <form method="post" action="/upload" enctype="multipart/form-data" style="margin-top:12px">
      <input type="file" name="file" multiple style="display:inline"> <button>Upload</button>
    </form>
  </section>
</noscript>
<footer>Keep MuurMusic open on your device while transferring.</footer>
</main>
<script>
(function () {
  const $ = (id) => document.getElementById(id);
  const allowed = /\.(flac|alac|m4a|m4b|m4p|aac|adts|mp4|m4v|mov|mp3|mp2|mp1|mpga|wav|wave|aif|aiff|aifc|caf|dsf|dff|dsd|ape|wv|tta|ogg|oga|opus|spx|mpc|mp\+|mpp|shn|ac3|eac3|ec3|mka|mkv|mpeg|mpg|mod|xm|it|s3m|mtm|669|amf|w64|rf64|snd|au|3gp|3g2|amr|m3u|m3u8|cue|pls|json|zip|jpg|jpeg|png|gif|bmp|webp|heic|lrc|txt)$/i;
  const queue = [];
  let active = 0;
  const maxParallel = 2;

  function fmtSize(n) {
    if (n < 1024) return n + ' B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    let i = -1;
    do { n /= 1024; i++; } while (n >= 1024 && i < units.length - 1);
    return n.toFixed(n < 10 ? 1 : 0) + ' ' + units[i];
  }
  function esc(s) { return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
  function encodePath(p) { return p.split('/').map(encodeURIComponent).join('/'); }

  async function api(path, options) {
    const response = await fetch(path, Object.assign({ credentials: 'same-origin', headers: { 'X-Requested-With': 'fetch' } }, options || {}));
    if (response.status === 401) { showLogin(); throw new Error('PIN required'); }
    return response;
  }

  function showLogin() { $('login').classList.remove('hidden'); $('app').classList.add('hidden'); $('pin').focus(); }
  function showApp() { $('login').classList.add('hidden'); $('app').classList.remove('hidden'); refreshFiles(); }

  async function init() {
    try {
      const info = await (await fetch('/api/info', { credentials: 'same-origin' })).json();
      $('device').textContent = 'Uploading to ' + info.name + ' \u2014 feed the cat some music.';
      if (info.requiresPIN && !info.authorized) showLogin(); else showApp();
    } catch (e) { $('device').textContent = 'Cannot reach MuurMusic. Is the app still open?'; }
  }

  $('loginForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    $('loginError').textContent = '';
    const body = new URLSearchParams({ pin: $('pin').value });
    const response = await fetch('/api/login', { method: 'POST', body, credentials: 'same-origin', headers: { 'X-Requested-With': 'fetch' } });
    if (response.ok) { $('pin').value = ''; showApp(); return; }
    const data = await response.json().catch(() => ({}));
    $('loginError').textContent = data.error || 'Wrong PIN';
  });

  function addFiles(list) {
    for (const entry of list) {
      const file = entry.file || entry;
      const path = entry.path || file.webkitRelativePath || file.name;
      const row = document.createElement('div');
      row.className = 'item';
      row.innerHTML = '<span class="name"></span><span class="meta"></span><span class="bar"><i></i></span>';
      row.querySelector('.name').textContent = path;
      row.querySelector('.meta').textContent = fmtSize(file.size);
      const placeholder = $('queue').querySelector('.empty');
      if (placeholder) placeholder.remove();
      $('queue').prepend(row);
      if (!allowed.test(file.name)) {
        row.querySelector('.meta').textContent = 'skipped';
        row.querySelector('.meta').className = 'meta err';
        row.dataset.done = '1';
        continue;
      }
      queue.push({ file, path, row });
    }
    pump();
  }

  function pump() {
    document.body.classList.toggle('busy', active > 0 || queue.length > 0);
    while (active < maxParallel && queue.length) {
      const job = queue.shift();
      active++;
      upload(job).finally(() => { active--; pump(); if (!active && !queue.length) refreshFiles(); });
    }
  }

  function upload(job) {
    return new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      const bar = job.row.querySelector('.bar i');
      const meta = job.row.querySelector('.meta');
      xhr.open('POST', '/api/upload');
      xhr.withCredentials = true;
      xhr.setRequestHeader('X-File-Name', encodeURIComponent(job.path));
      xhr.setRequestHeader('X-Requested-With', 'xhr');
      xhr.upload.onprogress = (e) => { if (e.lengthComputable) bar.style.width = (e.loaded / e.total * 100) + '%'; };
      xhr.onload = () => {
        job.row.dataset.done = '1';
        if (xhr.status === 201) { bar.style.width = '100%'; meta.textContent = 'done'; meta.className = 'meta ok'; }
        else {
          let message = 'failed';
          try { message = JSON.parse(xhr.responseText).error || message; } catch (e) {}
          meta.textContent = message; meta.className = 'meta err';
          if (xhr.status === 401) showLogin();
        }
        resolve();
      };
      xhr.onerror = () => { job.row.dataset.done = '1'; meta.textContent = 'connection lost'; meta.className = 'meta err'; resolve(); };
      xhr.send(job.file);
    });
  }

  function readEntry(entry, prefix) {
    return new Promise((resolve) => {
      if (entry.isFile) {
        entry.file((file) => resolve([{ file, path: prefix + file.name }]), () => resolve([]));
      } else if (entry.isDirectory) {
        const reader = entry.createReader();
        const all = [];
        const next = () => reader.readEntries(async (entries) => {
          if (!entries.length) {
            const nested = await Promise.all(all.map((e) => readEntry(e, prefix + entry.name + '/')));
            resolve(nested.flat());
            return;
          }
          all.push(...entries);
          next();
        }, () => resolve([]));
        next();
      } else resolve([]);
    });
  }

  const drop = $('drop');
  ['dragenter', 'dragover'].forEach((type) => drop.addEventListener(type, (e) => { e.preventDefault(); drop.classList.add('over'); }));
  ['dragleave', 'drop'].forEach((type) => drop.addEventListener(type, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
  drop.addEventListener('drop', async (e) => {
    const items = e.dataTransfer.items;
    if (items && items.length && items[0].webkitGetAsEntry) {
      const entries = [];
      for (const item of items) { const entry = item.webkitGetAsEntry(); if (entry) entries.push(entry); }
      const files = (await Promise.all(entries.map((entry) => readEntry(entry, '')))).flat();
      addFiles(files);
    } else addFiles(e.dataTransfer.files);
  });
  drop.addEventListener('click', (e) => { if (e.target === drop || e.target.tagName !== 'BUTTON') $('files').click(); });
  $('pickFiles').addEventListener('click', (e) => { e.stopPropagation(); $('files').click(); });
  $('pickFolder').addEventListener('click', (e) => { e.stopPropagation(); $('folder').click(); });
  $('files').addEventListener('change', (e) => { addFiles(e.target.files); e.target.value = ''; });
  $('folder').addEventListener('change', (e) => { addFiles(e.target.files); e.target.value = ''; });
  $('clearDone').addEventListener('click', () => {
    $('queue').querySelectorAll('.item').forEach((row) => { if (row.dataset.done) row.remove(); });
    if (!$('queue').children.length) $('queue').innerHTML = '<div class="empty">Nothing uploading. The cat is napping.</div>';
  });

  async function refreshFiles() {
    try {
      const data = await (await api('/api/files')).json();
      if (data.freeBytes >= 0) $('free').textContent = fmtSize(data.freeBytes) + ' free';
      const list = $('fileList');
      if (!data.files.length) { list.innerHTML = '<div class="empty">No files yet.</div>'; return; }
      list.innerHTML = data.files.map((f) =>
        '<div class="row"><a class="file name" href="/files/' + encodePath(f.path) + '">' + esc(f.path) + '</a>' +
        '<span class="meta">' + fmtSize(f.size) + '</span>' +
        '<button class="icon" data-path="' + esc(f.path) + '" title="Delete">&#10005;</button></div>').join('');
      list.querySelectorAll('button[data-path]').forEach((button) => button.addEventListener('click', async () => {
        if (!confirm('Delete ' + button.dataset.path + '?')) return;
        await api('/api/files?path=' + encodeURIComponent(button.dataset.path), { method: 'DELETE' });
        refreshFiles();
      }));
    } catch (e) { /* login shown */ }
  }

  init();
})();
</script>
</body>
</html>
"""#
}
