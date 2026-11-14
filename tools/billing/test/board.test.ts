import { test } from 'node:test';
import assert from 'node:assert/strict';

import { allowed, BOARD } from '../supabase/functions/_shared/board.ts';

test('board: читаются только страницы табло на обычных доменах', () => {
  assert.ok(allowed('https://results.isu.org/results/season2627/gpchn2026/SEG002.htm'));
  assert.ok(allowed('https://fsrussia.ru/results/2627/5etap_sen/index.htm?_=123'));
  assert.ok(allowed('http://www.deu-event.de/results/x/SEG001.HTM'));
  for (const bad of [
    null,
    'ftp://results.isu.org/a.htm',
    'https://results.isu.org/a.pdf',
    'https://127.0.0.1/a.htm',
    'https://localhost/a.htm',
    'https://intranet/a.htm',
    'https://x.supabase.co/a.htm',
    'https://results.isu.org:8443/a.htm',
    'https://user:pw@results.isu.org/a.htm',
    'not a url',
  ]) {
    assert.equal(allowed(bad), null, String(bad));
  }
});

test('board: подпись программы табло', () => {
  assert.ok(BOARD.test('Created by Swiss Timing, Ltd.'));
  assert.ok(BOARD.test('Created by ISUCalcFS Last Update'));
  assert.ok(BOARD.test('Figure Skating Support System by comnet'));
  assert.ok(!BOARD.test('<html>Some other site</html>'));
});
