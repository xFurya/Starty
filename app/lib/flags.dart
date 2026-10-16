// Флаги стран: PNG 3:2 из flag-icons (MIT, assets/flags/LICENSE-flag-icons.txt), вшиты в сборку.
// Только страны ISU; коды ISU (IOC) переводятся в ISO таблицей. Флага нет — только код страны.
import 'package:flutter/material.dart';

import 'countries.dart';
import 'palette.dart';
import 'ui.dart';

/// Код ISU → ISO 3166-1 (имя файла в assets/flags). Чего нет в таблице, у того нет флага:
/// регионы на российских стартах, простой AIN (нейтральный статус), TPE (у Китайского Тайбэя
/// на соревнованиях свой флаг, не государственный).
const flagIso = {
  'RUS': 'ru', 'BLR': 'by', 'USA': 'us', 'CAN': 'ca', 'MEX': 'mx', 'BRA': 'br', 'ARG': 'ar', 'CHI': 'cl',
  'COL': 'co', 'ECU': 'ec', 'PER': 'pe', 'URU': 'uy', 'VEN': 've', 'PUR': 'pr',
  'JPN': 'jp', 'KOR': 'kr', 'PRK': 'kp', 'CHN': 'cn', 'HKG': 'hk', 'MGL': 'mn', 'PHI': 'ph', 'MAS': 'my',
  'SGP': 'sg', 'THA': 'th', 'INA': 'id', 'IND': 'in', 'VIE': 'vn', 'AUS': 'au', 'NZL': 'nz',
  'RSA': 'za', 'EGY': 'eg', 'MAR': 'ma', 'ISR': 'il', 'TUR': 'tr', 'CYP': 'cy', 'UAE': 'ae', 'IRI': 'ir',
  'KSA': 'sa', 'QAT': 'qa', 'KUW': 'kw', 'LBN': 'lb', 'JOR': 'jo',
  'KAZ': 'kz', 'UZB': 'uz', 'KGZ': 'kg', 'TJK': 'tj', 'TKM': 'tm', 'GEO': 'ge', 'ARM': 'am', 'AZE': 'az',
  'UKR': 'ua', 'MDA': 'md', 'EST': 'ee', 'LAT': 'lv', 'LTU': 'lt', 'FIN': 'fi', 'SWE': 'se', 'NOR': 'no',
  'DEN': 'dk', 'ISL': 'is', 'GBR': 'gb', 'IRL': 'ie', 'FRA': 'fr', 'BEL': 'be', 'NED': 'nl', 'LUX': 'lu',
  'GER': 'de', 'SUI': 'ch', 'AUT': 'at', 'LIE': 'li', 'ITA': 'it', 'MON': 'mc', 'ESP': 'es', 'AND': 'ad',
  'POR': 'pt', 'POL': 'pl', 'CZE': 'cz', 'SVK': 'sk', 'HUN': 'hu', 'ROU': 'ro', 'BUL': 'bg', 'SLO': 'si',
  'CRO': 'hr', 'SRB': 'rs', 'BIH': 'ba', 'MNE': 'me', 'MKD': 'mk', 'ALB': 'al', 'KOS': 'xk', 'GRE': 'gr',
  'MLT': 'mt',
};

/// Файл флага по коду страны (AIN2 → Россия, AIN1 → Беларусь); null — флага нет.
String? flagAsset(String code) {
  final iso = flagIso[nationCode(code).toUpperCase()];
  return iso == null ? null : 'assets/flags/$iso.png';
}

/// Флаг 3:2 со скруглением и тонкой обводкой: белые флаги видны на светлом, тёмные — на тёмном.
class Flag extends StatelessWidget {
  final String asset;
  final double height;
  const Flag(this.asset, {super.key, required this.height});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final r = BorderRadius.circular(height / 6);
    return SizedBox(
      width: height * 1.5,
      height: height,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: r,
          border: Border.all(color: p.ink.withValues(alpha: p.isDark ? .30 : .16), width: .75),
        ),
        child: ClipRRect(
          borderRadius: r,
          child: Image.asset(
            asset,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
            // файла нет — пустого прямоугольника тоже нет
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// Страна: флаг и рядом код приглушённым цветом, по базовой линии строки. Флага нет — только код.
/// Высота флага — 1.05 кегля кода (≈ 0.8 кегля имени рядом), растёт вместе со шрифтом.
class NationTag extends StatelessWidget {
  /// Код как пришёл с табло или из протокола: нейтральные AIN1/AIN2 приводятся к стране.
  final String code;
  final TextStyle style;
  const NationTag(this.code, {super.key, required this.style});

  static double _flagH(TextStyle s) => (s.fontSize ?? 12) * 1.05;

  /// Высота заглавных Manrope в долях кегля.
  static const _capHeight = .72;
  static double _gap(TextStyle s) => (s.fontSize ?? 12) * .4;

  /// Ширина метки — чтобы место под неё учесть заранее (имя короче, колонка ровнее).
  static double widthOf(BuildContext context, String code, TextStyle style) {
    final c = nationCode(code);
    if (c.isEmpty) return 0;
    final k = MediaQuery.textScalerOf(context);
    final flag = flagAsset(c) == null ? 0.0 : k.scale(_flagH(style)) * 1.5 + k.scale(_gap(style));
    return flag + textWidth(context, c, style);
  }

  /// Что прочтёт экранный диктор: страна словами, если знаем.
  static String spoken(String code) {
    final c = nationCode(code);
    return countryNames[c.toUpperCase()] ?? c;
  }

  @override
  Widget build(BuildContext context) {
    final c = nationCode(code);
    if (c.isEmpty) return const SizedBox.shrink();
    final asset = flagAsset(c);
    final k = MediaQuery.textScalerOf(context);
    final h = k.scale(_flagH(style));
    return Semantics(
      label: spoken(c),
      child: ExcludeSemantics(
        child: Text.rich(
          TextSpan(
            children: [
              if (asset != null) ...[
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  // низ флага — на базовой линии, а середина — на середине заглавных кода:
                  // флаг выше заглавных и иначе торчал бы вверх
                  child: Transform.translate(
                    offset: Offset(0, (h - k.scale((style.fontSize ?? 12) * _capHeight)) / 2),
                    child: Flag(asset, height: h),
                  ),
                ),
                WidgetSpan(child: SizedBox(width: k.scale(_gap(style)))),
              ],
              TextSpan(text: c),
            ],
          ),
          maxLines: 1,
          softWrap: false,
          style: style,
        ),
      ),
    );
  }
}
