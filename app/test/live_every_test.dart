import 'package:flutter_test/flutter_test.dart';
import 'package:starty/data.dart';
import 'package:starty/sheets.dart' show liveEveryWarning;

void main() {
  test('частота: меньше десяти секунд не принимается, шире часа обрезается', () {
    expect(validLiveEvery(9), isNull);
    expect(validLiveEvery('abc'), isNull);
    expect(validLiveEvery(10), 10);
    expect(validLiveEvery('45'), 45);
    expect(validLiveEvery(99999), liveEveryMax);
  });

  test('частота старта: своя, иначе общая', () {
    expect(effectiveLiveEvery(30, {'a': 10}, 'a'), 10);
    expect(effectiveLiveEvery(30, {'a': 10}, 'b'), 30);
  });

  test('подпись и предупреждение о батарее', () {
    expect(liveEveryLabel(30), '30 сек');
    expect(liveEveryLabel(120), '2 мин');
    expect(liveEveryLabel(90), '1 мин 30 сек');
    expect(liveEveryWarning(10), isNotNull);
    expect(liveEveryWarning(600), isNull);
  });
}
