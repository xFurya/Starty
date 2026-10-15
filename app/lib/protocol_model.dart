// Файл протокола турнира с сайта (контракт, версия v=1): разбор с защитой от битых полей.
// Файл целиком не читается, если это не JSON, версия не 1 или нет верхнего уровня.
// Битый сегмент — только его состояние становится format; битая строка — весь сегмент format.
// Неизвестные ключи игнорируем: новое необязательное поле версию не меняет.
import 'dart:convert';

/// Файл не разобран целиком: не JSON, другая версия или нет обязательных полей верхнего уровня.
class ProtocolFormatException implements Exception {
  final String message;
  const ProtocolFormatException(this.message);
  @override
  String toString() => 'ProtocolFormatException: $message';
}

const protocolVersion = 1;

/// Состояние сегмента (контракт 2.4). Значение вне списка — format.
enum SegmentState {
  scheduled('scheduled'),
  notPublished('not_published'),
  inProgress('in_progress'),
  provisional('provisional'),
  finalized('final'),
  judgesMismatch('judges_mismatch'),
  format('format');

  final String wire;
  const SegmentState(this.wire);

  static SegmentState? fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

/// Состояние итога вида (контракт 2.4, Total.state).
enum TotalState {
  finalized('final'),
  provisional('provisional'),
  notPublished('not_published'),
  format('format');

  final String wire;
  const TotalState(this.wire);

  static TotalState? fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

const _tables = {'results', 'judges_pdf', 'starting', 'empty', 'format'};
final _points = RegExp(r'^\d{1,3}\.\d{2}$');

/// Файл турнира целиком.
class ProtocolDoc {
  final int v;
  final String tid, tournament, src;

  /// Когда содержимое файла менялось в последний раз; null, если в файле дата не читается.
  final DateTime? built;

  /// Есть ли на табло хотя бы одна ссылка на судейские оценки.
  final bool marks;
  final List<ProtocolCategory> categories;

  const ProtocolDoc({
    this.v = protocolVersion,
    required this.tid,
    required this.tournament,
    required this.src,
    this.built,
    required this.marks,
    required this.categories,
  });

  /// Разбор JSON-текста файла. Бросает [ProtocolFormatException], если файл не разобрать целиком.
  factory ProtocolDoc.fromJsonString(String body) {
    final Object? raw;
    try {
      raw = jsonDecode(body);
    } on FormatException {
      throw const ProtocolFormatException('не JSON');
    }
    if (raw is! Map) throw const ProtocolFormatException('верхний уровень не объект');
    return ProtocolDoc.fromJson(Map<String, dynamic>.from(raw));
  }

  factory ProtocolDoc.fromJson(Map<String, dynamic> j) {
    final v = j['v'];
    if (v is! int || v != protocolVersion) throw ProtocolFormatException('версия $v');
    final tid = j['tid'], tournament = j['tournament'], src = j['src'];
    if (tid is! String || tournament is! String || src is! String) {
      throw const ProtocolFormatException('нет tid, tournament или src');
    }
    final cats = j['categories'];
    if (cats is! List) throw const ProtocolFormatException('нет categories');
    final marks = j['marks'];
    return ProtocolDoc(
      tid: tid,
      tournament: tournament,
      src: src,
      built: _date(j['built']),
      marks: marks == true,
      // категория, которую не разобрать, пропускается: остальные показываем
      categories: [
        for (final c in cats)
          if (c is Map) ProtocolCategory.tryParse(Map<String, dynamic>.from(c)),
      ].whereType<ProtocolCategory>().toList(),
    );
  }

  /// Категория под вид и уровень старта; null — в файле такой нет.
  ProtocolCategory? categoryFor(String kind, String level) {
    for (final c in categories) {
      if (c.kind == kind && c.level == level) return c;
    }
    return null;
  }
}

/// Категория: вид, уровень, сегменты и итог вида.
class ProtocolCategory {
  final String kind, level, name;
  final List<ProtocolSegment> segments;
  final ProtocolTotal? total;

  const ProtocolCategory({
    required this.kind,
    required this.level,
    required this.name,
    required this.segments,
    this.total,
  });

  /// Категория без обязательных полей — null (пропускается целиком).
  static ProtocolCategory? tryParse(Map<String, dynamic> j) {
    final kind = j['kind'], level = j['level'], name = j['name'];
    if (kind is! String || level is! String || name is! String) return null;
    final segs = j['segments'];
    if (segs is! List) return null;
    final t = j['total'];
    return ProtocolCategory(
      kind: kind,
      level: level,
      name: name,
      segments: [for (final s in segs) if (s is Map) ProtocolSegment.tryParse(Map<String, dynamic>.from(s))],
      total: t is Map ? ProtocolTotal.parse(Map<String, dynamic>.from(t)) : null,
    );
  }

  /// Сегмент по коду (КП, ПП, РТ, ПТ); null — его нет в файле.
  ProtocolSegment? segmentOf(String code) {
    for (final s in segments) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// Сегмент (короткая, произвольная, ритм-танец, произвольный танец).
class ProtocolSegment {
  final String code, name, page;
  final DateTime? start, end;

  /// URL файла судейских оценок (кнопка «Оценки»); null — ссылки нет.
  final String? judges;
  final String table;
  final SegmentState state;

  /// judges, time или null. Для окончательного сегмента — judges.
  final String? basis;
  final int skipped;
  final List<ProtocolRow> rows;

  /// Судейская бригада сегмента; пусто — в файле её нет (блок не показываем).
  final List<ProtocolJudge> panel;

  const ProtocolSegment({
    required this.code,
    required this.name,
    this.start,
    this.end,
    required this.page,
    this.judges,
    required this.table,
    required this.state,
    this.basis,
    this.skipped = 0,
    this.rows = const [],
    this.panel = const [],
  });

  /// Сегмент с битыми полями: показываем только его состояние «формат», строк нет.
  static ProtocolSegment tryParse(Map<String, dynamic> j) {
    try {
      return _parse(j);
    } on _Broken {
      return ProtocolSegment(
        code: j['code'] is String ? j['code'] as String : '',
        name: j['name'] is String ? j['name'] as String : '',
        page: j['page'] is String ? j['page'] as String : '',
        table: 'format',
        state: SegmentState.format,
      );
    }
  }

  static ProtocolSegment _parse(Map<String, dynamic> j) {
    final code = _str(j['code']), name = _str(j['name']), page = _str(j['page']);
    if (code.isEmpty) throw const _Broken();
    final table = _str(j['table']);
    if (!_tables.contains(table)) throw const _Broken();
    final state = SegmentState.fromWire(j['state']);
    if (state == null) throw const _Broken();
    final basis = j['basis'];
    if (basis != null && basis != 'judges' && basis != 'time') throw const _Broken();
    // окончательный — только по судейским оценкам (или по времени, если так настроено сборщиком)
    if (state == SegmentState.finalized && basis == null) throw const _Broken();
    final judges = j['judges'];
    final rows = j['rows'];
    if (rows != null && rows is! List) throw const _Broken();
    final parsed = <ProtocolRow>[];
    var i = 0;
    for (final r in (rows as List? ?? const [])) {
      i++;
      if (r is! Map) throw const _Broken();
      parsed.add(ProtocolRow.parse(Map<String, dynamic>.from(r), i));
    }
    final skipped = j['skipped'];
    return ProtocolSegment(
      code: code,
      name: name,
      start: _date(j['start']),
      end: _date(j['end']),
      page: page,
      judges: judges is String && judges.isNotEmpty ? judges : null,
      table: table,
      state: state,
      basis: basis as String?,
      skipped: skipped is int && skipped > 0 ? skipped : 0,
      rows: parsed,
      // судья без номера и имени пропускается; битый список судей сегмент не ломает
      panel: _maps(judges is List ? judges : null, ProtocolJudge.tryParse),
    );
  }
}

/// Судья сегмента: номер на табло (J1), имя и страна. Всё необязательное, но не пустое целиком.
class ProtocolJudge {
  final String no, name, nation;
  const ProtocolJudge({required this.no, required this.name, this.nation = ''});

  static ProtocolJudge? tryParse(Map<String, dynamic> j) {
    final no = _text(j['no']), name = _text(j['name']);
    if (no.isEmpty && name.isEmpty) return null;
    return ProtocolJudge(no: no, name: name, nation: _text(j['nation']));
  }
}

/// Строка протокола (или строка итога вида, если [parts] заполнен).
class ProtocolRow {
  /// Позиция в таблице, с 1.
  final int i;
  final int? place;
  final String? status;
  final int? no;
  final String name;

  /// Код страны или региона; пустая строка — колонки нет.
  final String nation;
  final String? points, tes, pcs, ded;

  /// Сумма базовых стоимостей элементов (bv) и стартовая отметка (start): необязательные, как в файле.
  final String? bv, start;

  /// Элементы с базой, GOE и оценкой. Пусто — в файле их нет (блок не показываем).
  final List<ProtocolElement> elements;

  /// Компоненты: название, коэффициент, оценки судей, итог. Пусто — блок не показываем.
  final List<ProtocolComponent> components;

  /// Сбавки с расшифровкой («Падения» -1.00). Пусто — перечня нет, но сумма [ded] может быть.
  final List<ProtocolDeduction> deductions;

  /// Итог вида: значения колонок по сегментам (как на табло); для сегмента — null.
  final List<String?>? parts;

  const ProtocolRow({
    required this.i,
    this.place,
    this.status,
    this.no,
    required this.name,
    this.nation = '',
    this.points,
    this.tes,
    this.pcs,
    this.ded,
    this.bv,
    this.start,
    this.elements = const [],
    this.components = const [],
    this.deductions = const [],
    this.parts,
  });

  /// Строка без имени — формат сегмента (бросает [_Broken]); остальные поля мягкие.
  static ProtocolRow parse(Map<String, dynamic> j, int fallbackIndex) {
    final name = j['name'];
    if (name is! String || name.trim().isEmpty) throw const _Broken();
    final place = j['place'];
    final parsedPlace = place is int && place >= 1 && place <= 999 ? place : null;
    final no = j['no'];
    final parts = j['parts'];
    return ProtocolRow(
      i: j['i'] is int ? j['i'] as int : fallbackIndex,
      place: parsedPlace,
      status: j['status'] is String && (j['status'] as String).isNotEmpty ? j['status'] as String : null,
      no: no is int ? no : null,
      name: name,
      nation: _str(j['nation']),
      points: _score(j['points']),
      tes: _score(j['tes']),
      pcs: _score(j['pcs']),
      // снижение может быть отрицательным
      ded: _signed(j['ded']),
      bv: _score(j['bv']),
      start: _startMark(j['start']),
      elements: _maps(j['els'], ProtocolElement.tryParse),
      components: _maps(j['comp'], ProtocolComponent.tryParse),
      deductions: _maps(j['deds'], ProtocolDeduction.tryParse),
      parts: parts is List ? [for (final p in parts) _part(p)] : null,
    );
  }
}

/// Элемент программы: номер, код (как на табло), отметки, база, GOE, оценки судей, итог элемента.
/// Все числа — строки или null: нет поля — прочерк, а не ноль.
class ProtocolElement {
  final int? no;
  final String name;

  /// Отметки судей/технического специалиста («<», «q», «e», «!»); пустая строка — нет.
  final String info;
  final String? base, goe, score;

  /// База с пометкой x (прыжок во второй половине программы, бонус).
  final bool x;

  /// Оценки GOE судей; null — судья не выставил (прочерк на своём месте).
  final List<num?> judges;

  const ProtocolElement({
    this.no,
    required this.name,
    this.info = '',
    this.base,
    this.x = false,
    this.goe,
    this.judges = const [],
    this.score,
  });

  /// Элемент без названия не показывается: его нечем назвать.
  static ProtocolElement? tryParse(Map<String, dynamic> j) {
    final name = _text(j['n']);
    if (name.isEmpty) return null;
    final no = j['no'];
    return ProtocolElement(
      no: no is int ? no : null,
      name: name,
      info: _text(j['info']),
      base: _score(j['b']),
      x: j['x'] == true,
      goe: _signed(j['g']),
      judges: _marks(j['j']),
      score: _score(j['s']),
    );
  }
}

/// Компонент программы: название, коэффициент, оценки судей, итог.
class ProtocolComponent {
  final String name;

  /// Коэффициент (1.33); null — нет в файле.
  final String? factor;
  final List<num?> judges;
  final String? score;
  const ProtocolComponent({required this.name, this.factor, this.judges = const [], this.score});

  static ProtocolComponent? tryParse(Map<String, dynamic> j) {
    final name = _text(j['n']);
    if (name.isEmpty) return null;
    final f = j['f'];
    return ProtocolComponent(
      name: name,
      factor: f is num && f.isFinite && f > 0 ? _trimZeros(f) : null,
      judges: _marks(j['j']),
      score: _score(j['s']),
    );
  }
}

/// Сбавка: название («Падения») и значение (отрицательное).
class ProtocolDeduction {
  final String name;

  /// Сумма сбавки со знаком; null — нет в файле.
  final String? value;
  const ProtocolDeduction({required this.name, this.value});

  static ProtocolDeduction? tryParse(Map<String, dynamic> j) {
    final name = _text(j['n']);
    if (name.isEmpty) return null;
    return ProtocolDeduction(name: name, value: _signed(j['v']));
  }
}

/// Итог вида (CATnnnRS): колонки по сегментам и строки.
class ProtocolTotal {
  final TotalState state;

  /// Эвристика сборщика: у первых трёх строк заполнены все сегментные колонки. Не признак окончательности.
  final bool complete;
  final List<String> cols;

  /// places — целые числа (места за сегмент), points — с точкой, unknown — иначе.
  final String colsKind;
  final List<ProtocolRow> rows;
  final int skipped;

  const ProtocolTotal({
    required this.state,
    required this.complete,
    required this.cols,
    required this.colsKind,
    required this.rows,
    required this.skipped,
  });

  /// Итог с битыми полями целиком становится format: строки не показываем.
  static ProtocolTotal parse(Map<String, dynamic> j) {
    const broken = ProtocolTotal(state: TotalState.format, complete: false, cols: [], colsKind: 'unknown', rows: [], skipped: 0);
    final state = TotalState.fromWire(j['state']);
    if (state == null) return broken;
    final cols = [for (final c in (j['cols'] as List? ?? const [])) '$c'];
    final kind = j['colsKind'];
    final rawRows = j['rows'] as List? ?? const [];
    final parsed = <ProtocolRow>[];
    var bad = false;
    var i = 0;
    for (final r in rawRows) {
      i++;
      if (r is! Map) {
        bad = true;
        break;
      }
      try {
        final row = ProtocolRow.parse(Map<String, dynamic>.from(r), i);
        // parts той же длины, что cols; иначе строка не показывается как итог
        if (row.parts != null && row.parts!.length != cols.length) throw const _Broken();
        parsed.add(row);
      } on _Broken {
        bad = true;
        break;
      }
    }
    if (bad) return broken;
    final skipped = j['skipped'];
    return ProtocolTotal(
      state: state,
      complete: j['complete'] == true,
      cols: cols,
      colsKind: kind is String && const {'places', 'points'}.contains(kind) ? kind : 'unknown',
      rows: parsed,
      skipped: skipped is int && skipped > 0 ? skipped : 0,
    );
  }
}

/// Строка битая: сегмент или строка, которую нельзя показать.
class _Broken implements Exception {
  const _Broken();
}

String _str(Object? v) => v is String ? v : '';

/// Строка или число как текст; остальное — пусто. Пробелы по краям убираем.
String _text(Object? v) => v is String ? v.trim() : (v is num ? '$v' : '');

/// Разбор необязательного списка объектов: не список — пусто, негодный элемент пропускается.
List<T> _maps<T>(Object? v, T? Function(Map<String, dynamic>) parse) => [
  if (v is List)
    for (final e in v)
      if (e is Map) ?parse(Map<String, dynamic>.from(e)),
];

/// Оценки судей: число или null (судья не выставил). Не число — тоже null: мусор не превращаем в ноль.
List<num?> _marks(Object? v) => [if (v is List) for (final m in v) m is num && m.isFinite ? m : null];

/// 1.33 -> «1.33», 2.0 -> «2», 1.5 -> «1.5».
String _trimZeros(num v) => v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

/// Стартовая отметка: число или короткая строка; пустое — null.
String? _startMark(Object? v) {
  final t = _text(v);
  return t.isEmpty || t.length > 12 ? null : t;
}

/// Строка-число вида NN.NN; иное — null (показываем прочерк, не число).
String? _score(Object? v) {
  if (v is num) v = v.toStringAsFixed(2);
  return v is String && _points.hasMatch(v) ? v : null;
}

/// Значение колонки итога: место за сегмент (целое) или баллы (NN.NN); иное — null.
String? _part(Object? v) {
  if (v is int) return v >= 0 && v <= 999 ? '$v' : null;
  return v is String && RegExp(r'^\d{1,3}(\.\d{2})?$').hasMatch(v) ? v : null;
}

/// GOE: знак и число, например -0.80 или 1.10; иное — null.
String? _signed(Object? v) {
  if (v is num) v = v.toStringAsFixed(2);
  return v is String && RegExp(r'^[+-]?\d{1,2}\.\d{2}$').hasMatch(v) ? v : null;
}

DateTime? _date(Object? v) {
  if (v is! String) return null;
  return DateTime.tryParse(v);
}
