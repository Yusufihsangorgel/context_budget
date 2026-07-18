import 'dart:convert';
import 'dart:io';

import 'package:hf_tokenizers/hf_tokenizers.dart';

/// One file's cost, measured in tokens rather than bytes.
class FileCost {
  FileCost(this.path, this.tokens, this.bytes);

  final String path;
  final int tokens;
  final int bytes;

  /// Bytes per token. Prose sits near 4, minified assets and base64 blobs run
  /// far lower, which is what makes them expensive to paste into a model.
  double get density => tokens == 0 ? 0 : bytes / tokens;
}

/// The result of measuring a tree against a fixed context window.
class Budget {
  Budget(this.costs, this.window, this.skipped);

  /// Files that were measured, most expensive first.
  final List<FileCost> costs;

  /// The context window the tree is being measured against, in tokens.
  final int window;

  /// Paths that were not measured, and why.
  final Map<String, String> skipped;

  int get totalTokens => costs.fold(0, (sum, c) => sum + c.tokens);

  bool get fits => totalTokens <= window;

  /// How much of the window the tree occupies, where 1.0 is exactly full.
  double get fill => window == 0 ? 0 : totalTokens / window;

  /// The prefix of [costs] that fits in the window when the cheapest files are
  /// added first, which is the order that gets the most files in.
  List<FileCost> get largestFittingSet {
    final cheapestFirst = costs.reversed.toList();
    final taken = <FileCost>[];
    var running = 0;
    for (final c in cheapestFirst) {
      if (running + c.tokens > window) break;
      running += c.tokens;
      taken.add(c);
    }
    return taken.reversed.toList();
  }
}

/// Directory names that are never worth measuring: build output, vendored
/// dependencies, and version control metadata.
const _skipDirs = {
  '.git',
  '.dart_tool',
  '.idea',
  'node_modules',
  'build',
  'target',
  'vendor',
  '.next',
  'Pods',
  '.venv',
  '__pycache__',
};

/// Measures every text file under [root] against a [window]-token budget.
///
/// Binary files and anything under a build or dependency directory are skipped
/// and reported in [Budget.skipped] rather than silently dropped, because a
/// budget that quietly ignores half the tree is worse than no budget.
Budget measureTree(
  Directory root, {
  required Tokenizer tokenizer,
  required int window,
  bool Function(String path)? include,
}) {
  final costs = <FileCost>[];
  final skipped = <String, String>{};

  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;

    final rel = _relative(entity.path, root.path);
    if (rel.split(Platform.pathSeparator).any(_skipDirs.contains)) continue;
    if (include != null && !include(rel)) continue;

    // Read bytes and decode separately. `readAsStringSync` reports a malformed
    // encoding as a FileSystemException, which would lump genuinely unreadable
    // files in with binary ones and make the skip report useless.
    final List<int> bytes;
    try {
      bytes = entity.readAsBytesSync();
    } on FileSystemException {
      skipped[rel] = 'unreadable';
      continue;
    }

    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      skipped[rel] = 'not utf-8';
      continue;
    }

    if (text.isEmpty) {
      skipped[rel] = 'empty';
      continue;
    }

    costs.add(FileCost(rel, tokenizer.encode(text).length, bytes.length));
  }

  costs.sort((a, b) => b.tokens.compareTo(a.tokens));
  return Budget(costs, window, skipped);
}

String _relative(String path, String from) {
  final prefix = from.endsWith(Platform.pathSeparator)
      ? from
      : '$from${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}
