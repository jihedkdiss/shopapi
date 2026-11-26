// Front end for ShopAPI. Kept in its own file (no inline script) so a strict CSP can work.
const $ = (id) => document.getElementById(id);

function card(p) {
  const el = document.createElement('div');
  el.className = 'card';
  const emoji = document.createElement('div'); emoji.className = 'emoji'; emoji.textContent = p.emoji;
  const name = document.createElement('div'); name.className = 'name'; name.textContent = p.name;
  const price = document.createElement('div'); price.className = 'price'; price.textContent = `€${Number(p.price).toFixed(2)}`;
  const id = document.createElement('div'); id.className = 'pid'; id.textContent = `id ${p.id}`;
  el.append(emoji, name, price, id);
  return el;
}

fetch('products').then(r => r.json()).then(list => list.forEach(p => $('products').append(card(p))));
fetch('version').then(r => r.json()).then(v => { $('version').textContent = v.version.slice(0, 12); });

$('lookup').addEventListener('submit', async (e) => {
  e.preventDefault();
  const res = await fetch('product?id=' + encodeURIComponent($('pid').value));
  const body = await res.json();
  $('result').textContent = `HTTP ${res.status}\n` + JSON.stringify(body, null, 2);
  $('result').className = Array.isArray(body) && body.some(p => p.id === 99) ? 'leak' : '';
});
