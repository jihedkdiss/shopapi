const express = require('express');
const mysql = require('mysql');
const app = express();
const db = mysql.createConnection({ host: 'db', user: 'root', password: 'root', database: 'shop' });
app.get('/product', (req, res) => {
  db.query("SELECT * FROM products WHERE id = " + req.query.id, (err, rows) => res.json(rows));
});
app.get('/health', (req, res) => res.send('ok'));
app.listen(3000);
