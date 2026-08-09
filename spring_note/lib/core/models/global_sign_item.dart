class GlobalSignItem {
  const GlobalSignItem({
    required this.id,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory GlobalSignItem.fromJson(Map<String, Object?> json) {
    return GlobalSignItem(
      id: json['id'] as String? ?? '',
      content: json['content'] as String? ?? '',
      createdAt: _readTime(json['createdAt']),
      updatedAt: _readTime(json['updatedAt']),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  GlobalSignItem copyWith({
    String? id,
    String? content,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return GlobalSignItem(
      id: id ?? this.id,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static DateTime _readTime(Object? value) {
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) {
        return parsed;
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

/// AI 返回的全局签草稿项：已有项携带 id，新增项 id 为空字符串，由系统分配。
class GlobalSignDraftItem {
  const GlobalSignDraftItem({required this.id, required this.content});

  final String id;
  final String content;
}
