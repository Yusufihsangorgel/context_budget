import 'dart:convert';

import 'package:context_budget/src/render.dart';
import 'package:test/test.dart';

/// Wraps [text] the way Anthropic emits an incremental text delta.
String anthropicLine(String text) =>
    'data: ${jsonEncode({
      'type': 'content_block_delta',
      'delta': {'type': 'text_delta', 'text': text},
    })}';

void main() {
  group('readChunks', () {
    test('strips the SSE data prefix and the DONE sentinel', () async {
      final lines = Stream.fromIterable([
        'data: {"a":1}',
        '',
        '{"b":2}',
        'data: [DONE]',
      ]);

      final chunks = await readChunks(lines).toList();

      expect(chunks, [
        {'a': 1},
        {'b': 2},
      ]);
    });
  });

  group('replay', () {
    test('yields the object as it fills in, not just at the end', () async {
      final target = '{"verdict":"ok","score":3}';
      final lines = Stream.fromIterable([
        for (var i = 0; i < target.length; i += 4)
          anthropicLine(target.substring(i, (i + 4).clamp(0, target.length))),
      ]);

      final states = await replay(
        readChunks(lines),
        Provider.anthropic,
      ).toList();

      expect(
        states.length,
        greaterThan(1),
        reason: 'a partial parser should surface intermediate states',
      );
      expect(states.last, {'verdict': 'ok', 'score': 3});
      // Every state is a usable map, never a half-parsed fragment.
      expect(states.every((s) => s is Map), isTrue);
    });

    test(
      'intermediate states only ever grow toward the final object',
      () async {
        final target = '{"a":"one","b":"two"}';
        final lines = Stream.fromIterable([
          for (var i = 0; i < target.length; i += 3)
            anthropicLine(target.substring(i, (i + 3).clamp(0, target.length))),
        ]);

        final states = await replay(
          readChunks(lines),
          Provider.anthropic,
        ).toList();

        final keyCounts = states.cast<Map>().map((s) => s.keys.length).toList();
        expect(keyCounts, orderedEquals(List.of(keyCounts)..sort()));
        expect(states.last, {'a': 'one', 'b': 'two'});
      },
    );

    test('an empty recording yields nothing rather than throwing', () async {
      final states = await replay(
        readChunks(const Stream.empty()),
        Provider.anthropic,
      ).toList();

      expect(states, isEmpty);
    });
  });

  group('Provider', () {
    test('parses known names and rejects unknown ones', () {
      expect(Provider.parse('openai'), Provider.openai);
      expect(Provider.parse('gemini'), Provider.gemini);
      expect(() => Provider.parse('llama'), throwsArgumentError);
    });
  });
}
