// Tiny orders API. Start: PORT=3000 node server.js
const http = require('http');
const orders = [
  { id: 1, customer: 'ana', total: 40.5, status: 'paid' },
  { id: 2, customer: 'bo', total: 12.0, status: 'pending' },
  { id: 3, customer: 'ana', total: 99.99, status: 'refunded' },
];
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ ok: true }));
  }
  if (req.method === 'GET' && url.pathname === '/orders') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(orders));
  }
  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});
server.listen(process.env.PORT || 3000);
