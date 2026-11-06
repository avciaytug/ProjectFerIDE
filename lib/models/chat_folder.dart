import 'package:uuid/uuid.dart';

/// Sohbet oturumlarını gruplayan klasör.
///
/// Disk formatı (_folders.json):
/// [{"id": "...", "name": "PROJELER", "createdAt": "ISO8601"}]
class ChatFolder {
  final String id;
  String name;
  final DateTime createdAt;

  ChatFolder({String? id, required this.name, DateTime? createdAt})
      : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  ChatFolder copyWith({String? name}) {
    return ChatFolder(id: id, name: name ?? this.name, createdAt: createdAt);
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory ChatFolder.fromJson(Map<String, dynamic> json) {
    return ChatFolder(
      id: json['id'] as String?,
      name: json['name'] as String? ?? 'Yeni Klasör',
      createdAt: (json['createdAt'] != null &&
              DateTime.tryParse(json['createdAt'] as String) != null)
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
    );
  }
}
