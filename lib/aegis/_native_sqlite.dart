/// Native (masaüstü) ortamda `package:sqlite3`'ü dışarıya açan ince sarmalayıcı.
/// Web'de bu dosya YÜKLENMEZ (koşullu import), böylece `dart:ffi` derlemeye girmez.
library;

import 'package:sqlite3/sqlite3.dart' as _s;

typedef Database = _s.Database;
final sqlite3 = _s.sqlite3;
