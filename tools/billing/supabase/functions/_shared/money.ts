// Деньги храним в копейках (целое), сервисам отдаём, как каждый просит: «149.00», 149.00 или 14900.

export type Currency = 'RUB' | 'BYN';

/** 14900 → «149.00». */
export function decimal(minor: number): string {
  if (!Number.isInteger(minor) || minor < 0) throw new Error(`сумма ${minor}`);
  return `${Math.floor(minor / 100)}.${String(minor % 100).padStart(2, '0')}`;
}

/** «149.00», «149», «149.000000» (так пишет Робокасса), 149.5 → 14900, 14900, 14900, 14950.
 *  Не число или дробь мельче копейки — null: сумма не сойдётся, и платёж не засчитается. */
export function minor(v: unknown): number | null {
  const s = typeof v === 'number' ? v.toFixed(2) : typeof v === 'string' ? v.trim().replace(',', '.') : '';
  const m = /^(\d+)(?:\.(\d+))?$/.exec(s);
  if (!m) return null;
  const frac = m[2] ?? '';
  if (/[^0]/.test(frac.slice(2))) return null;
  return Number(m[1]) * 100 + Number(frac.slice(0, 2).padEnd(2, '0'));
}

/** Для писем: «149 ₽», «1 290 ₽», «9,90 BYN». */
export function human(minorAmount: number, currency: string): string {
  const whole = Math.floor(minorAmount / 100);
  const frac = minorAmount % 100;
  const grouped = String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  const n = frac === 0 ? grouped : `${grouped},${String(frac).padStart(2, '0')}`;
  return currency === 'RUB' ? `${n} ₽` : `${n} ${currency}`;
}

const months = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];

/** «5 декабря» по Москве — как во всём приложении. */
export function day(iso: string): string {
  const t = new Date(new Date(iso).getTime() + 3 * 3600 * 1000);
  return `${t.getUTCDate()} ${months[t.getUTCMonth()]}`;
}
