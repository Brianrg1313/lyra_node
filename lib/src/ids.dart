import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// A new record id: a UUIDv7 string (`docs/offline/README.md`, Identity). Time-ordered, so
/// fresh rows land at the end of an index, and never the backend's ids (plan principle 1).
String newId() => _uuid.v7();
