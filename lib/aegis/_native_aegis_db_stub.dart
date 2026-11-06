/// Web (tarayıcı) ortamında `_native_aegis_db.dart` yerine yüklenen stub.
/// AegisService web'de in-memory çalıştığı için bu sınıf asla anılmaz;
/// yalnızca `dart:ffi`'den arınmış derlemeyi sağlamak için var.
library;

class _StubDb {
  void execute(String sql, [List<Object?> params = const []]) {}
  List<Map<String, Object?>> select(String sql, [List<Object?> params = const []]) => [];
  void dispose() {}
}

class NativeAegisDb {
  final String dbPath;
  bool hasFts = false;
  final _StubDb db = _StubDb();
  NativeAegisDb(this.dbPath) {}
  void dispose() => db.dispose();
}
