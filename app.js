const express = require('express');
const initSqlJs = require('sql.js');
const app = express();
let db;
app.get('/product', (req, res) => {
  try { const result = db.exec("SELECT * FROM products WHERE id = " + req.query.id); res.json(toRows(result)); }
  catch (err) { res.status(400).json({ error: err.message }); }
});
app.get('/products', (req, res) => res.json(toRows(db.exec('SELECT id, name, price, emoji FROM products WHERE hidden = 0'))));
app.get('/version', (req, res) => res.json({ version: process.env.APP_VERSION || 'local' }));
app.get('/health', (req, res) => res.send('ok'));
app.use(express.static('public'));

function toRows(result) {
  if (!result.length) return [];
  const { columns, values } = result[0];
  return values.map(v => Object.fromEntries(columns.map((c, i) => [c, v[i]])));
}

initSqlJs().then(SQL => {
  db = new SQL.Database();
  db.run(`CREATE TABLE products (id INTEGER, name TEXT, price REAL, emoji TEXT, hidden INTEGER);
    INSERT INTO products VALUES
      (1, 'Cloud hoodie', 39.0, '🧥', 0), (2, 'YAML mug', 12.5, '☕', 0),
      (3, 'Pipeline stickers', 4.0, '🏷️', 0), (4, 'Least-privilege cap', 18.0, '🧢', 0),
      (99, 'STAFF ONLY: code DEVSECOPS-100-OFF', 0.0, '🔐', 1);`);
  app.listen(3000, () => console.log('shopapi on :3000'));
});
