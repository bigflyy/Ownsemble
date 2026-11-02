import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/ui/library_controller.dart';
import 'package:ownsemble/ui/place_history.dart';

void main() {
  Place at(double scroll, {String search = ''}) =>
      Place(view: LibraryView.songs, search: search, scroll: scroll);

  test('back returns the places left, newest first, and forward undoes it', () {
    final places = PlaceHistory()
      ..leave(at(1))
      ..leave(at(2));
    expect(places.back(at(3)), at(2));
    expect(places.back(at(2)), at(1));
    expect(places.back(at(1)), isNull);
    expect(places.forward(at(1)), at(2));
    expect(places.forward(at(2)), at(3));
    expect(places.forward(at(3)), isNull);
  });

  test('nowhere to go leaves the lists as they were', () {
    final places = PlaceHistory();
    expect(places.back(at(1)), isNull);
    expect(places.forward(at(1)), isNull);
    places.leave(at(2));
    expect(places.back(at(3)), at(2));
    expect(places.back(at(2)), isNull);
    expect(places.forward(at(2)), at(3));
  });

  test('a new place after going back drops the forward ones', () {
    final places = PlaceHistory()
      ..leave(at(1))
      ..leave(at(2));
    places.back(at(3));
    places.leave(at(2));
    expect(places.forward(at(4)), isNull);
    expect(places.back(at(4)), at(2));
    expect(places.back(at(2)), at(1));
  });

  test('leaving the same place twice in a row counts once', () {
    final places = PlaceHistory()
      ..leave(at(1))
      ..leave(at(1));
    expect(places.back(at(2)), at(1));
    expect(places.back(at(1)), isNull);
  });

  test('only the newest places are kept', () {
    final places = PlaceHistory();
    for (var i = 0; i < PlaceHistory.limit + 5; i++) {
      places.leave(at(i.toDouble()));
    }
    var steps = 0;
    Place? last;
    var here = at(-1);
    while (true) {
      final place = places.back(here);
      if (place == null) break;
      last = here = place;
      steps++;
    }
    expect(steps, PlaceHistory.limit);
    expect(last, at(5));
  });

  test('a place differs by view, search or scroll', () {
    final place = at(1, search: 'а');
    expect(place, at(1, search: 'а'));
    expect(place, isNot(at(2, search: 'а')));
    expect(place, isNot(at(1, search: 'б')));
    expect(
      place,
      isNot(
        const Place(
          view: LibraryView(ViewKind.history),
          search: 'а',
          scroll: 1,
        ),
      ),
    );
  });
}
