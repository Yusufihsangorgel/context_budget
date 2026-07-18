# context_budget

Two things you need when you build against a language model in Dart: know what
you are about to send it, and render what comes back before it finishes.

This is a working demo of [`hf_tokenizers`][hf] and [`stream_struct`][ss], both
pulled from pub.dev the same way you would use them.

[hf]: https://pub.dev/packages/hf_tokenizers
[ss]: https://pub.dev/packages/stream_struct

## Measuring a repository in tokens

Byte counts do not tell you whether a tree fits in a context window. Token
counts do, and they are not proportional to bytes.

```
$ dart run bin/context_budget.dart budget ../image --ext dart --top 5

tokenizer  bert-base-uncased.json
window     200,000 tokens

  37,936   19.0%   3.3 B/tok  lib/src/font/arial_48.dart
  23,475   11.7%   2.8 B/tok  lib/src/formats/webp/vp8.dart
  18,670    9.3%   3.3 B/tok  lib/src/font/arial_24.dart
  13,780    6.9%   3.0 B/tok  lib/src/formats/tiff/tiff_fax_decoder.dart
  13,421    6.7%   3.3 B/tok  lib/src/formats/webp/vp8l.dart
  ... and 474 more files

684,054 tokens across 479 files, 342.0% of the window
over by 484,054 tokens; 363 of 479 files fit if you drop the most expensive ones first
```

The `image` package is three and a half context windows of Dart. One embedded
font file is a fifth of a window on its own, which is the kind of thing you want
to know before an agent pulls it in.

The `B/tok` column is bytes per token. Prose runs near 4.8, Dart source near
2.3, so a repository fills a window faster than its size on disk suggests.

### Point it at the tokenizer you actually use

The counts are only as good as the tokenizer. This ships `bert-base-uncased`
so it runs out of the box, but BERT maps any unknown contiguous run to a single
`[UNK]`:

```dart
tokenizer.encode('aZ9' * 400);  // [101, 100, 102], three tokens for 1200 bytes
```

Minified JavaScript, base64 payloads and lockfiles would look nearly free.
Pass `--tokenizer path/to/tokenizer.json` from the model you actually send to.
Loading any HuggingFace `tokenizer.json` is what `hf_tokenizers` is for.

## Rendering a stream while it arrives

A model emits a structured answer a few characters at a time. Waiting for the
last byte to `jsonDecode` means the screen sits empty for the whole generation.

```
$ dart run bin/context_budget.dart render assets/review-stream.anthropic.jsonl

{
  "verdict": "needs-changes",
  "findings": [
    {
      "file": "lib/src/partial_json.dart",
      "note": "dangling comma path is untested"
    },
    ...
  ],
  "confidence": 0.82
}
19 renderable states before the stream closed
```

The recording is 22 wire deltas. `stream_struct` turns them into 19 complete,
decodable objects along the way, so a UI can paint 19 times instead of once.
Every intermediate state is a real map, never a half-parsed fragment.

Recordings are read as one JSON chunk per line, and `data:` prefixes and the
`[DONE]` sentinel are tolerated so a capture taken off the wire replays as-is.
Use `--provider` for `anthropic`, `openai`, or `gemini` chunk shapes.

## Running it

```
dart pub get
dart test
dart run bin/context_budget.dart budget . --ext dart
dart run bin/context_budget.dart render assets/review-stream.anthropic.jsonl
```

`hf_tokenizers` builds its native library through a Dart build hook and
downloads a prebuilt binary, so no Rust toolchain is needed.

## What is deliberately not here

No model is called. `render` replays a recording rather than holding an API key,
and `budget` is local measurement. That keeps the demo runnable by anyone who
clones it, and keeps the numbers above reproducible.
