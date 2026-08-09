import 'note_file.dart';

class NoteExternalUpdate {
  const NoteExternalUpdate({
    required this.kind,
    required this.path,
    required this.revision,
  });

  final NoteKind kind;
  final String path;
  final int revision;
}
