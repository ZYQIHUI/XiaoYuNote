import 'app_config.dart';

class LocalDataState {
  const LocalDataState({
    required this.dataDirectory,
    required this.configPath,
    required this.dailyNotesDirectory,
    required this.weeklyNotesDirectory,
    required this.monthlyNotesDirectory,
    required this.config,
  });

  final String dataDirectory;
  final String configPath;
  final String dailyNotesDirectory;
  final String weeklyNotesDirectory;
  final String monthlyNotesDirectory;
  final AppConfig config;

  LocalDataState copyWith({
    String? dataDirectory,
    String? configPath,
    String? dailyNotesDirectory,
    String? weeklyNotesDirectory,
    String? monthlyNotesDirectory,
    AppConfig? config,
  }) {
    return LocalDataState(
      dataDirectory: dataDirectory ?? this.dataDirectory,
      configPath: configPath ?? this.configPath,
      dailyNotesDirectory: dailyNotesDirectory ?? this.dailyNotesDirectory,
      weeklyNotesDirectory: weeklyNotesDirectory ?? this.weeklyNotesDirectory,
      monthlyNotesDirectory:
          monthlyNotesDirectory ?? this.monthlyNotesDirectory,
      config: config ?? this.config,
    );
  }
}
