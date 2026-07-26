import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:hf_tokenizers/hf_tokenizers.dart';

import 'package:context_budget/src/budget.dart';
import 'package:context_budget/src/render.dart';

Future<void> main(List<String> args) async {
  final runner =
      CommandRunner<void>(
          'context_budget',
          'Know what you are sending a model.',
        )
        ..addCommand(BudgetCommand())
        ..addCommand(RenderCommand());
  try {
    await runner.run(args);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
}

class BudgetCommand extends Command<void> {
  BudgetCommand() {
    argParser
      ..addOption(
        'tokenizer',
        abbr: 't',
        help:
            'Path to a tokenizer.json. Use the one your model ships so the '
            'counts are the counts the model will actually see.',
        defaultsTo: 'assets/bert-base-uncased.json',
      )
      ..addOption(
        'window',
        abbr: 'w',
        help: 'Context window to measure against, in tokens.',
        defaultsTo: '200000',
      )
      ..addOption(
        'ext',
        help: 'Only measure files with these comma-separated extensions.',
      )
      ..addOption('top', help: 'Show only the N most expensive files.');
  }

  @override
  String get name => 'budget';

  @override
  String get description =>
      'Measure a directory in tokens and see what fits in a context window.';

  @override
  void run() {
    final rest = argResults!.rest;
    final root = Directory(rest.isEmpty ? '.' : rest.first);
    if (!root.existsSync()) {
      throw UsageException('no such directory: ${root.path}', usage);
    }

    final window = int.tryParse(argResults!['window'] as String);
    if (window == null || window <= 0) {
      throw UsageException('--window must be a positive integer', usage);
    }

    final tokenizerPath = argResults!['tokenizer'] as String;
    if (!File(tokenizerPath).existsSync()) {
      throw UsageException('no tokenizer.json at $tokenizerPath', usage);
    }

    final extensions = (argResults!['ext'] as String?)
        ?.split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .map((e) => e.startsWith('.') ? e : '.$e')
        .toSet();

    final tokenizer = Tokenizer.fromFile(tokenizerPath);
    final Budget budget;
    try {
      budget = measureTree(
        root,
        tokenizer: tokenizer,
        window: window,
        include: extensions == null
            ? null
            : (path) => extensions.any(path.endsWith),
      );
    } finally {
      tokenizer.close();
    }

    _report(budget, tokenizerPath, int.tryParse(argResults!['top'] ?? ''));
  }

  void _report(Budget budget, String tokenizerPath, int? top) {
    final out = stdout;
    out.writeln('tokenizer  ${p(tokenizerPath)}');
    out.writeln('window     ${_n(budget.window)} tokens');
    out.writeln();

    final shown = top == null ? budget.costs : budget.costs.take(top).toList();
    if (shown.isNotEmpty) {
      final width = shown.map((c) => _n(c.tokens).length).reduce(_max);
      for (final c in shown) {
        final pct = (c.tokens / budget.window * 100).toStringAsFixed(1);
        out.writeln(
          '  ${_n(c.tokens).padLeft(width)}  '
          '${pct.padLeft(5)}%  '
          '${c.density.toStringAsFixed(1).padLeft(4)} B/tok  '
          '${c.path}',
        );
      }
      if (top != null && budget.costs.length > top) {
        out.writeln('  ... and ${budget.costs.length - top} more files');
      }
      out.writeln();
    }

    final pct = (budget.fill * 100).toStringAsFixed(1);
    out.writeln(
      '${_n(budget.totalTokens)} tokens across '
      '${budget.costs.length} files, $pct% of the window',
    );

    if (!budget.fits) {
      final fitting = budget.largestFittingSet;
      final overBy = budget.totalTokens - budget.window;
      out.writeln(
        'over by ${_n(overBy)} tokens; '
        '${fitting.length} of ${budget.costs.length} files fit if you drop '
        'the most expensive ones first',
      );
    }

    if (budget.skipped.isNotEmpty) {
      final byReason = <String, int>{};
      for (final reason in budget.skipped.values) {
        byReason[reason] = (byReason[reason] ?? 0) + 1;
      }
      final parts = byReason.entries
          .map((e) => '${e.value} ${e.key}')
          .join(', ');
      out.writeln('skipped ${budget.skipped.length} files ($parts)');
    }
  }
}

class RenderCommand extends Command<void> {
  RenderCommand() {
    argParser.addOption(
      'provider',
      abbr: 'p',
      help: 'Chunk shape of the recording.',
      allowed: Provider.values.map((p) => p.name),
      defaultsTo: 'anthropic',
    );
  }

  @override
  String get name => 'render';

  @override
  String get description =>
      'Replay a recorded model stream and print the structured object as it '
      'fills in.';

  @override
  Future<void> run() async {
    final rest = argResults!.rest;
    final lines = rest.isEmpty
        ? stdin.transform(utf8.decoder).transform(const LineSplitter())
        : File(
            rest.first,
          ).openRead().transform(utf8.decoder).transform(const LineSplitter());

    final provider = Provider.parse(argResults!['provider'] as String);
    const encoder = JsonEncoder.withIndent('  ');

    var frames = 0;
    Object? last;
    await for (final partial in replay(readChunks(lines), provider)) {
      frames++;
      last = partial;
    }

    if (last == null) {
      stderr.writeln('no JSON was recovered from the recording');
      exitCode = 1;
      return;
    }
    stdout.writeln(encoder.convert(last));
    stderr.writeln('$frames renderable states before the stream closed');
  }
}

int _max(int a, int b) => a > b ? a : b;

String p(String path) => path.split(Platform.pathSeparator).last;

/// Groups digits so large token counts stay readable.
String _n(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
