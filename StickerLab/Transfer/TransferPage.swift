enum TransferPage {
    // Served to the PC browser by TransferServer. No external resources: works offline on the LAN.
    static let html = #"""
<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>StickerLab · Invia dal PC</title>
<style>
  :root { --bg:#000; --card:#141416; --line:#2a2a2e; --text:#f2f2f7; --muted:#8e8e93; --accent:#0a84ff; --ok:#30d158; --err:#ff453a; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:15px/1.45 -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width:760px; margin:0 auto; padding:32px 16px 64px; }
  h1 { font-size:28px; margin:0 0 4px; letter-spacing:-.02em; }
  .sub { color:var(--muted); margin:0 0 24px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:22px; padding:18px; margin-bottom:16px; }
  label { display:block; font-weight:600; margin-bottom:8px; }
  select, input[type=text] { width:100%; padding:12px 14px; border-radius:12px; border:1px solid var(--line); background:#0b0b0d; color:var(--text); font:inherit; }
  .row { display:flex; gap:12px; align-items:center; margin-top:12px; flex-wrap:wrap; }
  .row input[type=text] { flex:1; min-width:180px; }
  .check { display:flex; align-items:center; gap:8px; color:var(--muted); font-weight:500; margin:0; }
  #drop { border:2px dashed #3a3a40; border-radius:22px; padding:44px 16px; text-align:center; cursor:pointer; transition:.15s; }
  #drop.over { border-color:var(--accent); background:rgba(10,132,255,.08); }
  #drop strong { font-size:18px; display:block; margin-bottom:6px; }
  #drop span { color:var(--muted); }
  ul { list-style:none; padding:0; margin:0; }
  li { display:flex; justify-content:space-between; gap:12px; padding:10px 0; border-bottom:1px solid var(--line); }
  li:last-child { border-bottom:0; }
  .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .st { color:var(--muted); white-space:nowrap; }
  .st.ok { color:var(--ok); } .st.err { color:var(--err); }
  .hint { color:var(--muted); font-size:13px; margin-top:10px; }
  #summary { font-weight:600; margin-bottom:8px; }
</style>
</head>
<body>
<main>
  <h1>Invia sticker a StickerLab</h1>
  <p class="sub">Scegli il pacchetto e trascina qui GIF, immagini, WebP o video: finiscono direttamente nell'iPhone. Puoi trascinare anche un backup .zip per ripristinare i pacchetti.</p>

  <div class="card">
    <label for="pack">Pacchetto di destinazione</label>
    <select id="pack"></select>
    <div class="row" id="newrow" hidden>
      <input type="text" id="newname" placeholder="Nome del nuovo pacchetto">
      <label class="check"><input type="checkbox" id="newanim"> Animato</label>
    </div>
    <p class="hint">WhatsApp non mischia statici e animati: in un pacchetto statico le GIF diventano immagini fisse, in uno animato le immagini diventano animazioni di 2 fotogrammi. Max 30 sticker per pacchetto (poi ne viene creato un altro).</p>
  </div>

  <div class="card" id="drop">
    <strong>Trascina qui i file</strong>
    <span>oppure clicca per sceglierli · GIF, PNG, JPG, WebP, MP4, MOV · backup .zip</span>
    <input type="file" id="files" multiple accept="image/*,video/*,.webp,.zip,.wastickers" hidden>
  </div>

  <div class="card" id="results" hidden>
    <div id="summary"></div>
    <ul id="list"></ul>
  </div>
</main>
<script>
const $ = (id) => document.getElementById(id);
let packs = [];

async function loadPacks(selectId) {
  try {
    const r = await fetch('/api/packs');
    packs = await r.json();
  } catch (e) { packs = []; }
  const sel = $('pack');
  const keep = selectId || sel.value;
  sel.innerHTML = '';
  for (const p of packs) {
    const o = document.createElement('option');
    o.value = p.id;
    o.textContent = `${p.name} · ${p.count}/${p.max} · ${p.animated ? 'animato' : 'statico'}`;
    sel.appendChild(o);
  }
  const n = document.createElement('option');
  n.value = 'new'; n.textContent = '➕ Nuovo pacchetto…';
  sel.appendChild(n);
  if (keep && [...sel.options].some(o => o.value === keep)) sel.value = keep;
  else if (!packs.length) sel.value = 'new';
  $('newrow').hidden = sel.value !== 'new';
}

$('pack').addEventListener('change', () => { $('newrow').hidden = $('pack').value !== 'new'; });

async function targetPack() {
  let id = $('pack').value;
  if (id !== 'new') return id;
  const r = await fetch('/api/packs', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: $('newname').value, animated: $('newanim').checked })
  });
  const j = await r.json();
  if (!j.ok) throw new Error(j.message || 'Impossibile creare il pacchetto');
  await loadPacks(j.id);
  return j.id;
}

async function send(files) {
  files = [...files].filter(f => f.size > 0);
  if (!files.length) return;
  $('results').hidden = false;
  const list = $('list');
  const rows = files.map(f => {
    const li = document.createElement('li');
    li.innerHTML = '<span class="name"></span><span class="st">In attesa</span>';
    li.querySelector('.name').textContent = f.name;
    list.prepend(li);
    return li;
  });
  let target;
  try { target = await targetPack(); }
  catch (e) { $('summary').textContent = e.message; return; }

  let ok = 0;
  for (let i = 0; i < files.length; i++) {
    const st = rows[i].querySelector('.st');
    st.textContent = 'Invio…';
    $('summary').textContent = `Invio ${i + 1} di ${files.length}…`;
    try {
      const r = await fetch(`/api/upload?pack=${encodeURIComponent(target)}&filename=${encodeURIComponent(files[i].name)}`, {
        method: 'POST', body: files[i]
      });
      const j = await r.json();
      if (j.packId) target = j.packId;
      st.textContent = j.ok ? '✓ ' + j.message : '✗ ' + (j.message || 'Errore');
      st.className = 'st ' + (j.ok ? 'ok' : 'err');
      if (j.ok) ok++;
    } catch (e) {
      st.textContent = '✗ iPhone non raggiungibile (app aperta?)';
      st.className = 'st err';
    }
  }
  $('summary').textContent = `Fatto: ${ok} di ${files.length} aggiunti.`;
  loadPacks(target);
}

const drop = $('drop');
drop.addEventListener('click', () => $('files').click());
$('files').addEventListener('change', (e) => { send(e.target.files); e.target.value = ''; });
['dragenter', 'dragover'].forEach(t => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach(t => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', (e) => send(e.dataTransfer.files));
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', (e) => e.preventDefault());

loadPacks();
</script>
</body>
</html>
"""#
}
