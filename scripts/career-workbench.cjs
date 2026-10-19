'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assets = { '/career': ['index.html', 'text/html'], '/career/': ['index.html', 'text/html'], '/career/workbench.js': ['workbench.js', 'text/javascript'], '/career/workbench.css': ['workbench.css', 'text/css'] };
function serveWorkbench(req, res, route) {
  if (req.method !== 'GET' || !assets[route]) return false;
  const [file, type] = assets[route];
  const content = fs.readFileSync(path.join(__dirname, '../desktop/career', file));
  res.writeHead(200, { 'Content-Type': type + '; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
    'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-src blob:; object-src blob:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'" });
  res.end(content); return true;
}
module.exports = { serveWorkbench };
