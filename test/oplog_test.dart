import 'dart:typed_data';

import 'package:lyra_node/lyra_node.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('hlc', () {
    test('never goes backwards, even when the wall clock does', () {
      var wall = 1000;
      final clock = HlcClock("m", now: () => wall);

      final a = clock.tick();
      wall = 500;
      final b = clock.tick();
      final c = clock.tick();
      wall = 2000;
      final d = clock.tick();

      expect([a, b, c, d], orderedEquals([a, b, c, d]..sort()));
      expect(b.millis, 1000);
      expect(d, Hlc(2000, 0, "m"));
    });

    test('seeded with the last stamp written, it continues after it', () {
      final clock = HlcClock("m", last: Hlc(5000, 3, "m"), now: () => 10);

      expect(clock.tick(), Hlc(5000, 4, "m"));
    });

    test('a remote stamp moves it forward, one too far ahead is refused', () {
      final clock = HlcClock("m", now: () => 1000);

      expect(clock.receive(Hlc(1500, 7, "c")), Hlc(1500, 8, "m"));
      expect(() => clock.receive(Hlc(1000 + 61000, 0, "c")), throwsA(isA<ClockDrift>()));
    });

    test('packed stamps sort like the stamps', () {
      final stamps = [Hlc(10, 2, "b"), Hlc(9, 99, "z"), Hlc(10, 2, "a"), Hlc(1700000000000, 0, "a")];
      final packed = stamps.map((s) => s.pack()).toList()..sort();

      expect(packed.map(Hlc.parse).toList(), [...stamps]..sort());
    });
  });

  group('oplog and commands', () {
    late Store store;

    setUp(() {
      final paths = tempPaths(addTearDown);
      store = Store.open(paths.database, Uint8List(32));
      migrate(store, backups: paths.backups);
      addTearDown(store.close);
    });

    test('entries come back in order, after a seq', () {
      final clock = HlcClock("m");
      final oplog = Oplog(store.db);

      store.write((_) {
        for (var i = 0; i < 3; i++) {
          oplog.append(hlc: clock.tick(), entity: "product", entityId: "p$i", kind: "created", payload: {"n": i});
        }
      });

      expect(oplog.lastSeq, 3);
      expect(oplog.since(1).map((e) => e.entityId), ["p1", "p2"]);
      expect(oplog.since(0, limit: 1).single.payload, {"n": 0});
      expect(oplog.lastHlc, clock.last);
    });

    test('a command answers once, again on replay, and refuses other arguments', () {
      final ledger = CommandLedger(store.db);
      final now = DateTime.utc(2026, 9, 30);

      expect(ledger.replay("c1", "stock.move", {"qty": 2}).found, isFalse);

      store.write((_) => ledger.record("c1", "stock.move", {"qty": 2}, {"balance": 5}, now));

      expect(ledger.replay("c1", "stock.move", {"qty": 2}).answer, {"balance": 5});
      expect(() => ledger.replay("c1", "stock.move", {"qty": 3}), throwsA(isA<CommandReused>()));
    });

    test('answers are kept 30 days', () {
      final ledger = CommandLedger(store.db);
      final day = DateTime.utc(2026, 9, 1);

      store.write((_) => ledger.record("old", "x", const {}, null, day));
      store.write((_) => ledger.record("new", "x", const {}, null, day.add(const Duration(days: 20))));

      expect(store.write((_) => ledger.prune(day.add(const Duration(days: 31)))), 1);
      expect(ledger.replay("new", "x", const {}).found, isTrue);
    });
  });

  group('audit', () {
    late Store store;
    late AuditLog audit;

    setUp(() {
      final paths = tempPaths(addTearDown);
      store = Store.open(paths.database, Uint8List(32));
      migrate(store, backups: paths.backups);
      audit = AuditLog(store.db);
      addTearDown(store.close);
    });

    test('each entry chains to the one before', () {
      store.write((_) {
        audit.append("a");
        audit.append("b", actor: "u1", data: {"x": 1});
      });

      final entries = audit.list();

      expect(entries.first.prev, AuditLog.genesis);
      expect(entries.last.prev, entries.first.hash);
      expect(audit.verify(), isNull);
    });

    test('editing or removing an entry is found', () {
      store.write((_) {
        for (final kind in ["a", "b", "c"]) {
          audit.append(kind, data: {"kind": kind});
        }
      });

      store.write((db) => db.execute("UPDATE audit SET data = '{\"kind\":\"z\"}' WHERE seq = 2"));
      expect(audit.verify(), 2);

      store.write((db) => db.execute("UPDATE audit SET data = '{\"kind\":\"b\"}' WHERE seq = 2"));
      expect(audit.verify(), isNull);

      store.write((db) => db.execute("DELETE FROM audit WHERE seq = 2"));
      expect(audit.verify(), 3);
    });
  });
}
