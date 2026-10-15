// Палитра «Лёд»: цвета светлой и тёмной темы. Экраны берут цвета только отсюда,
// литералы Color(0x…) в экранах не пишем.
import 'package:flutter/material.dart';

/// Цвета «Лёд»: светлая тема — главная, тёмная — ночной каток.
/// Акцент — синий из иконки (#2B78C2 → #0A2342).
class Palette {
  final bool isDark;
  final Color bg, bgTop, plate, plateLine, ink, ink2, ink3, line, accent, onAccent, live, sheet, frost, nav;

  /// Обводка флажков и переключателей: не ниже 3:1 к фону листа.
  final Color control;

  /// Виды: приглушённые ледяные оттенки — женщины, мужчины, пары, танцы.
  final Color women, men, pairs, dance;

  const Palette({
    required this.isDark,
    required this.bg,
    required this.bgTop,
    required this.plate,
    required this.plateLine,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.accent,
    required this.onAccent,
    required this.live,
    required this.sheet,
    required this.frost,
    required this.nav,
    required this.control,
    required this.women,
    required this.men,
    required this.pairs,
    required this.dance,
  });

  /// Синий из иконки: верх и низ градиента.
  static const iceBlue = Color(0xFF2B78C2);
  static const deepBlue = Color(0xFF0A2342);

  static const light = Palette(
    isDark: false,
    bg: Color(0xFFF1F6FB),
    bgTop: Color(0xFFE2EEF9),
    plate: Color(0xFFFFFFFF),
    plateLine: Color(0xFFD6E3EF),
    ink: Color(0xFF0B1A2A),
    ink2: Color(0xFF4A6077),
    ink3: Color(0xFF8396AA),
    line: Color(0xFFE4ECF4),
    accent: Color(0xFF1D63AD),
    onAccent: Color(0xFFFFFFFF),
    live: Color(0xFFD5304A),
    sheet: Color(0xFFF7FAFD),
    frost: Color(0xFFE6F0FA),
    nav: Color(0xFFFBFDFF),
    control: Color(0xFF6F8399),
    women: Color(0xFFB9668A),
    men: Color(0xFF3D7CC0),
    pairs: Color(0xFF3A9294),
    dance: Color(0xFF8576C0),
  );
  static const dark = Palette(
    isDark: true,
    bg: Color(0xFF06101B),
    bgTop: Color(0xFF0B2036),
    plate: Color(0xFF0C1B2B),
    plateLine: Color(0xFF1A2F46),
    ink: Color(0xFFE8F1FA),
    ink2: Color(0xFF9CB1C6),
    ink3: Color(0xFF627990),
    line: Color(0xFF15283C),
    accent: Color(0xFF80BBF2),
    onAccent: Color(0xFF06101B),
    live: Color(0xFFFF6B78),
    sheet: Color(0xFF0A1726),
    frost: Color(0xFF132A42),
    nav: Color(0xFF081422),
    control: Color(0xFF6E86A0),
    women: Color(0xFFE59AB5),
    men: Color(0xFF7FB2E8),
    pairs: Color(0xFF6FCBC8),
    dance: Color(0xFFB3A6EC),
  );
  static Palette of(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? dark : light;

  /// Дорожка включённого переключателя: под белым бегунком не ниже 4.5:1.
  Color get switchOn => isDark ? iceBlue : accent;

  Color kind(String k) => switch (k) {
    'women' => women,
    'men' => men,
    'pairs' => pairs,
    'dance' => dance,
    _ => ink3,
  };
}
