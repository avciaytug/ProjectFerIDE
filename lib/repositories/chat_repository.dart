import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import '../models/chat_session.dart';
import '../models/chat_folder.dart';
import '../services/agent_engine.dart';

class ChatRepository {
  final String basePath;

  static final Map<String, ChatSession> _pendingSaves = {};
  static final Set<String> _activeSavingIds = {};
  static int _tmpSeq = 0;

  ChatRepository(this.basePath);

  /// Web'de (dart2js) Isolate desteklenmez; Isolate.run orada
  /// UnsupportedError atar ve await sonsuza dek donar. Native'de
  /// ağır JSON işini ayrı isolate'a atarız, web'de inline çalışırız.
  static bool get _isolatesAvailable => !kIsWeb;

  static Future<String> _jsonEncodeSafe(Map<String, dynamic> data) async {
    if (_isolatesAvailable) {
      return Isolate.run(() => jsonEncode(data));
    }
    return jsonEncode(data);
  }

  static Future<Map<String, dynamic>> _jsonDecodeSafe(String content) async {
    if (_isolatesAvailable) {
      return Isolate.run(
          () => jsonDecode(content) as Map<String, dynamic>);
    }
    return jsonDecode(content) as Map<String, dynamic>;
  }

  Future<Directory> _getStorageDir() async {
    final chatDir = Directory(basePath);
    if (!await chatDir.exists()) {
      await chatDir.create(recursive: true);
    }
    return chatDir;
  }

  Future<File> _getIndexFile() async {
    final dir = await _getStorageDir();
    return File(p.join(dir.path, '_index.json'));
  }

  Future<Map<String, dynamic>> _readIndexRaw() async {
    final file = await _getIndexFile();
    if (!await file.exists()) {
      return await _rebuildIndex();
    }
    try {
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return await _rebuildIndex();
    }
  }

  Future<Map<String, dynamic>> _rebuildIndex() async {
    final dir = await _getStorageDir();
    final List<Map<String, dynamic>> sessionSummaries = [];
    final entities = await dir.list().toList();

    for (var entity in entities) {
      if (entity is File &&
          entity.path.endsWith('.json') &&
          !p.basename(entity.path).startsWith('_')) {
        try {
          final content = await entity.readAsString();
          final jsonMap = jsonDecode(content) as Map<String, dynamic>;
          final session = ChatSession.fromJson(jsonMap);
          final preview = session.messages.isNotEmpty
              ? (session.messages.first.event is AgentStarted
                  ? (session.messages.first.event as AgentStarted).goal
                  : session.messages.first.event.toString())
              : '';
          sessionSummaries.add({
            'id': session.id,
            'folderId': session.folderId,
            'title': session.title,
            'createdAt': session.createdAt.toIso8601String(),
            'updatedAt': session.updatedAt.toIso8601String(),
            'messageCount': session.messages.length,
            'tokens': session.calculatedTokens,
            'preview': preview.length > 200 ? preview.substring(0, 200) : preview,
          });
        } catch (_) {}
      }
    }

    final indexData = {
      'version': 1,
      'sessions': sessionSummaries,
    };

    try {
      final file = await _getIndexFile();
      await file.writeAsString(jsonEncode(indexData), flush: true);
    } catch (_) {}

    return indexData;
  }

  Future<void> _upsertIndexEntry(Map<String, dynamic> entry) async {
    try {
      final raw = await _readIndexRaw();
      final List<dynamic> list = List<dynamic>.from(raw['sessions'] ?? []);
      final existingIdx = list.indexWhere((e) => e is Map && e['id'] == entry['id']);
      if (existingIdx != -1) {
        list[existingIdx] = entry;
      } else {
        list.add(entry);
      }
      raw['sessions'] = list;
      final file = await _getIndexFile();
      await file.writeAsString(jsonEncode(raw), flush: true);
    } catch (_) {}
  }

  Future<void> _removeFromIndex(String sessionId) async {
    try {
      final raw = await _readIndexRaw();
      final List<dynamic> list = List<dynamic>.from(raw['sessions'] ?? []);
      list.removeWhere((e) => e is Map && e['id'] == sessionId);
      raw['sessions'] = list;
      final file = await _getIndexFile();
      await file.writeAsString(jsonEncode(raw), flush: true);
    } catch (_) {}
  }

  Future<void> saveSession(ChatSession session) async {
    session.updatedAt = DateTime.now();
    _pendingSaves[session.id] = session;

    if (_activeSavingIds.contains(session.id)) return;
    _activeSavingIds.add(session.id);

    try {
      while (_pendingSaves.containsKey(session.id)) {
        final toSave = _pendingSaves.remove(session.id)!;
        final dir = await _getStorageDir();
        final targetPath = p.join(dir.path, '${toSave.id}.json');
        final tempPath = '$targetPath.$pid.${_tmpSeq++}.tmp';

        // Encode in Isolate if messages count is large, else inline
        final String jsonStr;
        if (toSave.messages.length > 40 && _isolatesAvailable) {
          jsonStr = await _jsonEncodeSafe(toSave.toJson());
        } else {
          jsonStr = jsonEncode(toSave.toJson());
        }

        final tempFile = File(tempPath);
        await tempFile.writeAsString(jsonStr, flush: true);
        if (await tempFile.exists()) {
          await tempFile.rename(targetPath);
        }

        // Update _index.json
        final preview = toSave.messages.isNotEmpty
            ? (toSave.messages.first.event is AgentStarted
                ? (toSave.messages.first.event as AgentStarted).goal
                : toSave.messages.first.event.toString())
            : '';
        await _upsertIndexEntry({
          'id': toSave.id,
          'folderId': toSave.folderId,
          'title': toSave.title,
          'createdAt': toSave.createdAt.toIso8601String(),
          'updatedAt': toSave.updatedAt.toIso8601String(),
          'messageCount': toSave.messages.length,
          'tokens': toSave.calculatedTokens,
          'preview': preview.length > 200 ? preview.substring(0, 200) : preview,
        });
      }
    } catch (e) {
      print('[ChatRepository] Error saving session ${session.id}: $e');
    } finally {
      _activeSavingIds.remove(session.id);
    }
  }

  Future<ChatSession?> loadSession(String sessionId) async {
    final dir = await _getStorageDir();
    final file = File(p.join(dir.path, '$sessionId.json'));
    if (!await file.exists()) return null;

    try {
      final content = await file.readAsString();
      final jsonMap = await _jsonDecodeSafe(content);
      return ChatSession.fromJson(jsonMap);
    } catch (e) {
      print('[ChatRepository] Error loading session $sessionId: $e');
      return null;
    }
  }

  Future<List<ChatSession>> loadAllSessions() async {
    final rawIndex = await _readIndexRaw();
    final List<dynamic> list = rawIndex['sessions'] ?? [];
    final List<ChatSession> sessions = [];

    for (var item in list) {
      if (item is Map<String, dynamic>) {
        final preview = item['preview'] as String? ?? '';
        final session = ChatSession(
          id: item['id'] as String?,
          folderId: item['folderId'] as String?,
          title: item['title'] as String? ?? 'Yeni Sohbet',
          createdAt: item['createdAt'] != null ? DateTime.tryParse(item['createdAt']) : null,
          updatedAt: item['updatedAt'] != null ? DateTime.tryParse(item['updatedAt']) : null,
          messages: preview.isNotEmpty
              ? [ChatMessage(id: 'preview', event: AgentStarted(preview), timestamp: DateTime.now())]
              : [],
        );
        session.cachedTokens = (item['tokens'] as num?)?.toInt() ?? 0;
        sessions.add(session);
      }
    }

    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  Future<void> deleteSession(String sessionId) async {
    final dir = await _getStorageDir();
    final file = File(p.join(dir.path, '$sessionId.json'));
    if (await file.exists()) {
      await file.delete();
    }
    await _removeFromIndex(sessionId);
  }

  // Klasör Metotları
  Future<File> _getFoldersFile() async {
    final dir = await _getStorageDir();
    return File(p.join(dir.path, '_folders.json'));
  }

  Future<List<ChatFolder>> loadAllFolders() async {
    final file = await _getFoldersFile();
    if (!await file.exists()) return [];

    try {
      final content = await file.readAsString();
      final List<dynamic> jsonList = jsonDecode(content);
      return jsonList.map((e) => ChatFolder.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveFolders(List<ChatFolder> folders) async {
    final file = await _getFoldersFile();
    final jsonList = folders.map((f) => f.toJson()).toList();
    await file.writeAsString(jsonEncode(jsonList));
  }
}
