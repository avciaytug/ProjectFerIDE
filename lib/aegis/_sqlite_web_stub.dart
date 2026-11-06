/// Web (tarayıcı) ortamında `package:sqlite3` yerine yüklenen minimal stub.
///
/// Neden: `package:sqlite3` -> `dart:ffi`'i çeker; `dart:ffi` web'de yoktur.
/// AegisService web'de aslında in-memory çalıştığı için bu stub yalnızca
/// *derlenmeyi* sağlamalı; çalışma anında native kod asla çağrılmaz.
library;

class Database {
  void execute(String sql, [List<Object?> params = const []]) {}
  List<Map<String, Object?>> select(String sql, [List<Object?> params = const []]) => [];
  void dispose() {}
}

class _Sqlite3 {
  Database open(String path) => Database();
}

final sqlite3 = _Sqlite3();
