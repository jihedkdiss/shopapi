const express = require('express');
const initSqlJs = require('sql.js');
const helmet = require('helmet');
const app = express();
// Security headers (CSP, X-Content-Type-Options, no X-Powered-By...). The lab serves plain HTTP,
// so don't tell browsers to upgrade requests to HTTPS.
app.use(helmet({ contentSecurityPolicy: { directives: { upgradeInsecureRequests: null } } }));
let db;
app.get('/product', (req, res) => {
  // Parameterized: the id travels separately from the SQL, so it can never become SQL.
  const stmt = db.prepare('SELECT * FROM products WHERE id = ? AND hidden = 0');
  stmt.bind([req.query.id]);
  const rows = [];
  while (stmt.step()) rows.push(stmt.getAsObject());
  stmt.free();
  res.json(rows);
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
