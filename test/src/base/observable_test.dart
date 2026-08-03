import 'package:test/test.dart';
import 'package:xterm2/src/base/observable.dart';

void main() {
  test('Observable allows listeners to unsubscribe during notification', () {
    final observable = _TestObservable();
    final calls = <int>[];

    void firstListener() {
      calls.add(1);
      observable.removeListener(firstListener);
    }

    observable.addListener(firstListener);
    observable.addListener(() => calls.add(2));

    observable.notifyListeners();
    observable.notifyListeners();

    expect(calls, [1, 2, 2]);
  });

  test('Observable allows listeners to subscribe during notification', () {
    final observable = _TestObservable();
    final calls = <int>[];

    void thirdListener() => calls.add(3);

    void firstListener() {
      calls.add(1);
      observable.addListener(thirdListener);
    }

    observable.addListener(firstListener);
    observable.addListener(() => calls.add(2));

    // The newly-added listener must not be invoked mid-round (it is not
    // called this round, since it wasn't present when the round started),
    // but it must be present and invoked on subsequent rounds - and none of
    // this should throw.
    expect(observable.notifyListeners, returnsNormally);
    expect(calls, [1, 2]);

    expect(observable.notifyListeners, returnsNormally);
    expect(calls, [1, 2, 1, 2, 3]);
  });

  test(
    'Observable allows a listener to both add and remove listeners during '
    'notification without throwing',
    () {
      final observable = _TestObservable();
      final calls = <String>[];

      void toBeRemoved() => calls.add('removed');
      void toBeAdded() => calls.add('added');

      void mutatingListener() {
        calls.add('mutating');
        observable.removeListener(toBeRemoved);
        observable.addListener(toBeAdded);
      }

      observable.addListener(toBeRemoved);
      observable.addListener(mutatingListener);

      expect(observable.notifyListeners, returnsNormally);
      expect(calls, ['removed', 'mutating']);

      calls.clear();
      expect(observable.notifyListeners, returnsNormally);
      expect(calls, ['mutating', 'added']);
    },
  );
}

class _TestObservable with Observable {}
