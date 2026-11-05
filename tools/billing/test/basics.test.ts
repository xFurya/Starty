import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decimal, minor, human, day } from '../supabase/functions/_shared/money.ts';
import { digest, hmacBase64, md5, same } from '../supabase/functions/_shared/hash.ts';
import { noticeLetter, ownerLetter } from '../supabase/functions/_shared/mail.ts';

// неразрывные пробелы в суммах и датах — чтобы «149 ₽» не разорвалось по строкам
const sp = (s: string) => s.replace(/\u00a0/g, ' ');

test('деньги: копейки туда и обратно', () => {
  assert.equal(decimal(14900), '149.00');
  assert.equal(decimal(990), '9.90');
  assert.equal(decimal(5), '0.05');
  assert.throws(() => decimal(1.5));
  assert.throws(() => decimal(-1));
  assert.equal(minor('149.00'), 14900);
  assert.equal(minor('149'), 14900);
  assert.equal(minor('149.5'), 14950);
  assert.equal(minor('149,50'), 14950);
  assert.equal(minor('149.000000'), 14900);
  assert.equal(minor('149.001'), null);
  assert.equal(minor(149.5), 14950);
  assert.equal(minor(149), 14900);
  assert.equal(minor('abc'), null);
  assert.equal(minor(undefined), null);
  assert.equal(minor('-5'), null);
});

test('деньги: как в письме', () => {
  assert.equal(sp(human(14900, 'RUB')), '149 ₽');
  assert.equal(sp(human(129000, 'RUB')), '1 290 ₽');
  assert.equal(sp(human(990, 'BYN')), '9,90 BYN');
  assert.equal(sp(day('2026-12-04T21:30:00Z')), '5 декабря');
  assert.equal(sp(day('2026-12-05T20:59:00Z')), '5 декабря');
});

test('хэши', async () => {
  assert.equal(md5(''), 'd41d8cd98f00b204e9800998ecf8427e');
  assert.equal(md5('abc'), '900150983cd24fb0d6963f7d28e17f72');
  assert.equal(md5('The quick brown fox jumps over the lazy dog'), '9e107d9d372bb6826bd81d3542a419d6');
  assert.equal(md5('привет, мир'), 'fce838a2cfcd53af5c40cf6e0d83baa0');
  assert.equal(md5('a'.repeat(1000)), 'cabe45dcc9ae5b66ba86600cca6b8ba8');
  assert.equal(await digest('md5', 'abc'), '900150983cd24fb0d6963f7d28e17f72');
  assert.equal(await digest('sha256', '149.000000:7:pass2:Shp_pay=aaaa-bbbb'),
    '9cb4bd60210b8d7ebcd014ba0f523ed9c45997b54f5c0bd2690d94ae16e117d4');
  assert.equal(await hmacBase64('secret', 'InvoiceId=p1&Amount=149.00'), 'mQu9rQbqfqQitBoYcxPjx8b4SxYXlDP/1RoFiSXILxE=');
  assert.ok(same('abc', 'abc'));
  assert.ok(!same('abc', 'abd'));
  assert.ok(!same('abc', 'abcd'));
});

test('напоминание: дата, сумма, карта, как отказаться, продавец', () => {
  const l = noticeLetter({
    user_id: 'u', email: 'a@b.ru', paid_until: '2026-12-05T10:00:00Z', amount: 14900, currency: 'RUB',
    plan_title: 'Месяц', method_title: 'Карта •• 4242', seller: 'Иванов И. И., самозанятый, ИНН 000000000000',
  });
  assert.equal(l.to, 'a@b.ru');
  assert.equal(sp(l.subject), 'Подписка продлится 5 декабря');
  assert.match(sp(l.text), /5 декабря с карты •• 4242 спишется 149 ₽/);
  assert.match(l.text, /Отключить продление/);
  assert.match(l.text, /Продавец: Иванов/);
  const bare = noticeLetter({
    user_id: 'u', email: 'a@b.ru', paid_until: '2026-12-05T10:00:00Z', amount: 14900, currency: 'RUB',
    plan_title: 'Месяц', method_title: null, seller: null,
  });
  assert.match(sp(bare.text), /5 декабря спишется/);
  assert.doesNotMatch(bare.text, /Продавец/);
});

test('владельцу: что вернуть вручную', () => {
  const l = ownerLetter('me@x.ru', 'buyer@x.ru', [
    { payment_id: 'p1', provider: 'robokassa', provider_id: '7', amount: 12000, currency: 'RUB', reason: 'у сервиса нет возврата через API' },
  ]);
  assert.equal(l.to, 'me@x.ru');
  assert.equal(sp(l.subject), 'Возврат вручную: 120 ₽');
  assert.match(l.text, /buyer@x\.ru/);
  assert.match(sp(l.text), /120 ₽ — robokassa, платёж у сервиса 7/);
  assert.match(l.text, /select public\.billing_refunded\('p1', 12000, false\);/);
});
