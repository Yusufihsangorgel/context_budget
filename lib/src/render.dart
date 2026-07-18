import 'dart:convert';

import 'package:stream_struct/stream_struct.dart';

/// The provider whose streaming chunk shape a recording uses.
enum Provider {
  anthropic(anthropicDelta),
  openai(openAiDelta),
  gemini(geminiDelta);

  const Provider(this.extractor);

  final DeltaExtractor extractor;

  static Provider parse(String name) => Provider.values.firstWhere(
        (p) => p.name == name,
        orElse: () => throw ArgumentError(
          'unknown provider "$name", expected one of '
          '${Provider.values.map((p) => p.name).join(', ')}',
        ),
      );
}

/// Reads a recorded stream, one JSON chunk per line, as the provider emitted it.
///
/// Lines that are blank, an SSE `data:` wrapper, or the `[DONE]` sentinel are
/// tolerated so a capture taken straight off the wire can be replayed as-is.
Stream<Map<String, dynamic>> readChunks(Stream<String> lines) async* {
  await for (final raw in lines) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('data:')) line = line.substring(5).trim();
    if (line.isEmpty || line == '[DONE]') continue;

    final decoded = jsonDecode(line);
    if (decoded is Map<String, dynamic>) yield decoded;
  }
}

/// Replays [chunks] and yields the structured object as it fills in.
///
/// Each element is the whole value decoded so far, so a caller can render the
/// current state without tracking deltas itself.
Stream<Object?> replay(
  Stream<Map<String, dynamic>> chunks,
  Provider provider,
) =>
    streamPartialJsonFrom(chunks, provider.extractor);
