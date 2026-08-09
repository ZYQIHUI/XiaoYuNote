class CloudSyncConfig {
  const CloudSyncConfig({
    required this.enabled,
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.syncOnStartup,
    required this.realTimeSync,
    required this.lastSyncedAt,
  });

  final bool enabled;
  final String serverUrl;
  final String username;
  final String password;
  final bool syncOnStartup;
  final bool realTimeSync;
  final DateTime? lastSyncedAt;

  static const defaultsValue = CloudSyncConfig(
    enabled: false,
    serverUrl: '',
    username: '',
    password: '',
    syncOnStartup: false,
    realTimeSync: false,
    lastSyncedAt: null,
  );

  factory CloudSyncConfig.defaults() {
    return defaultsValue;
  }

  factory CloudSyncConfig.fromJson(Object? value) {
    if (value is! Map) {
      return CloudSyncConfig.defaults();
    }
    final json = value.map((key, value) => MapEntry(key.toString(), value));
    return CloudSyncConfig(
      enabled: json['enabled'] as bool? ?? false,
      serverUrl: _readString(json['serverUrl']),
      username: _readString(json['username']),
      password: _readString(json['password']),
      syncOnStartup: json['syncOnStartup'] as bool? ?? false,
      realTimeSync: json['realTimeSync'] as bool? ?? false,
      lastSyncedAt: _readDateTime(json['lastSyncedAt']),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'enabled': enabled,
      'serverUrl': serverUrl,
      'username': username,
      'password': password,
      'syncOnStartup': syncOnStartup,
      'realTimeSync': realTimeSync,
      'lastSyncedAt': lastSyncedAt?.toIso8601String(),
    };
  }

  CloudSyncConfig copyWith({
    bool? enabled,
    String? serverUrl,
    String? username,
    String? password,
    bool? syncOnStartup,
    bool? realTimeSync,
    Object? lastSyncedAt = _sentinel,
  }) {
    return CloudSyncConfig(
      enabled: enabled ?? this.enabled,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      syncOnStartup: syncOnStartup ?? this.syncOnStartup,
      realTimeSync: realTimeSync ?? this.realTimeSync,
      lastSyncedAt: lastSyncedAt == _sentinel
          ? this.lastSyncedAt
          : lastSyncedAt as DateTime?,
    );
  }

  bool get hasRequiredFields {
    return serverUrl.trim().isNotEmpty &&
        username.trim().isNotEmpty &&
        password.isNotEmpty;
  }

  static String _readString(Object? value) {
    if (value is! String) {
      return '';
    }
    return value.trim();
  }

  static DateTime? _readDateTime(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }
}

const Object _sentinel = Object();
