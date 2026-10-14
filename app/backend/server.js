const express = require('express');
const { Pool } = require('pg');

const app = express();
app.use(express.json());

const pool = new Pool({
  host: process.env.DB_HOST || 'db',
  port: parseInt(process.env.DB_PORT || '5432', 10),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
});

async function initDb(retries = 20) {
  for (let i = 0; i < retries; i++) {
    try {
      await pool.query(`CREATE TABLE IF NOT EXISTS tasks (
        id SERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT now())`);
      console.log('Database ready');
      return;
    } catch (e) {
      console.log(`DB not ready (${i + 1}/${retries}): ${e.message}`);
      await new Promise(r => setTimeout(r, 3000));
    }
  }
  process.exit(1);
}

app.get('/api/health', async (_req, res) => {
  try { await pool.query('SELECT 1'); res.json({ status: 'ok', db: true }); }
  catch { res.status(503).json({ status: 'degraded', db: false }); }
});

app.get('/api/tasks', async (_req, res) => {
  const { rows } = await pool.query('SELECT id, title FROM tasks ORDER BY id DESC');
  res.json(rows);
});

app.post('/api/tasks', async (req, res) => {
  const title = (req.body.title || '').toString().trim().slice(0, 200);
  if (!title) return res.status(400).json({ error: 'title required' });
  const { rows } = await pool.query('INSERT INTO tasks(title) VALUES($1) RETURNING id, title', [title]);
  res.status(201).json(rows[0]);
});

app.delete('/api/tasks/:id', async (req, res) => {
  await pool.query('DELETE FROM tasks WHERE id = $1', [parseInt(req.params.id, 10)]);
  res.json({ deleted: true });
});

initDb().then(() => app.listen(process.env.PORT || 5000, () => console.log('API listening')));
