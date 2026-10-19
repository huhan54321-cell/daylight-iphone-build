'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { connectionEvent } = require('../scripts/career-service-runtime.cjs');

test('connection diagnostics redact credentials, arbitrary URLs and request content', () => {
  const secret = 'credential-must-not-be-logged';
  const req = { method: 'GET', url: '/v2/career/snapshot?token=' + secret,
    headers: { authorization: 'Bearer ' + secret, 'user-agent': 'Daylight CFNetwork Darwin ' + secret,
      'x-forwarded-for': '100.70.80.90', cookie: secret }, socket: { remoteAddress: '127.0.0.1' }, body: secret };
  const event = connectionEvent(req, 200, '2026-10-19T00:00:00Z');
  assert.equal(event.client, 'apple-app'); assert.equal(event.peer, '100.70.80.90');
  assert.equal(event.route, '/v2/career/snapshot'); assert.ok(!JSON.stringify(event).includes(secret));
  assert.equal(connectionEvent({ ...req, url: '/' + secret }, 404).route, 'other');
  assert.equal(connectionEvent({ ...req, url: '/v2/career/materials/' + secret }, 200).route, '/v2/career/*');
  assert.equal(connectionEvent({ ...req, headers: { 'x-forwarded-for': secret } }, 401).peer, '127.0.0.1');
});
