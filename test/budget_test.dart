import 'dart:io';

import 'package:context_budget/src/budget.dart';
import 'package:hf_tokenizers/hf_tokenizers.dart';
import 'package:test/test.dart';

void main() {
  late Tokenizer tokenizer;
  late Directory root;

  setUpAll(
    () => tokenizer = Tokenizer.fromFile('assets/bert-base-uncased.json'),
  );
  tearDownAll(() => tokenizer.close());

  setUp(() => root = Directory.systemTemp.createTempSync('budget_test'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String path, String contents) {
    final f = File('${root.path}${Platform.pathSeparator}$path')
      ..parent.createSync(recursive: true);
    f.writeAsStringSync(contents);
  }

  Budget measure({int window = 200000, bool Function(String)? include}) =>
      measureTree(root, tokenizer: tokenizer, window: window, include: include);

  test('counts tokens per file, most expensive first', () {
    write('small.txt', 'hello world');
    write('big.txt', List.filled(200, 'hello world').join(' '));

    final b = measure();

    expect(b.costs, hasLength(2));
    expect(b.costs.first.path, 'big.txt');
    expect(b.costs.first.tokens, greaterThan(b.costs.last.tokens));
    expect(b.totalTokens, b.costs.fold<int>(0, (s, c) => s + c.tokens));
  });

  test('skips build and dependency directories without counting them', () {
    write('lib/a.dart', 'const x = 1;');
    // Nested, not at the root: matching only the first path segment would let
    // every vendored and generated tree back into the count.
    write(
      'packages/inner/build/generated.dart',
      List.filled(500, 'const y = 2;').join(),
    );
    write(
      'a/b/node_modules/dep/index.js',
      List.filled(500, 'var z = 3;').join(),
    );

    final b = measure();

    expect(b.costs.map((c) => c.path), ['lib/a.dart']);
  });

  test('reports unreadable and empty files rather than dropping them', () {
    write('good.txt', 'hello');
    write('empty.txt', '');
    File(
      '${root.path}${Platform.pathSeparator}binary.bin',
    ).writeAsBytesSync([0xC3, 0x28, 0xA0, 0xA1]);

    final b = measure();

    expect(b.costs.map((c) => c.path), ['good.txt']);
    expect(b.skipped['empty.txt'], 'empty');
    expect(b.skipped['binary.bin'], 'not utf-8');
  });

  test('include filter narrows the tree', () {
    write('a.dart', 'const x = 1;');
    write('b.md', '# notes');

    final b = measure(include: (path) => path.endsWith('.dart'));

    expect(b.costs.map((c) => c.path), ['a.dart']);
  });

  test('fits and fill describe the window honestly', () {
    write('a.txt', 'hello world');

    final tokens = measure().totalTokens;

    expect(measure(window: tokens).fits, isTrue);
    expect(measure(window: tokens).fill, 1.0);
    expect(measure(window: tokens - 1).fits, isFalse);

    // A full window makes fill symmetric, so the operands could be swapped
    // without the assertion above noticing. This one is off-centre.
    expect(measure(window: tokens * 4).fill, closeTo(0.25, 1e-9));
  });

  test('largestFittingSet takes the cheapest files first', () {
    write('tiny.txt', 'hi');
    write('huge.txt', List.filled(400, 'hello world').join(' '));

    final all = measure();
    final tiny = all.costs.firstWhere((c) => c.path == 'tiny.txt');

    // A window that holds the small file but not the large one.
    final b = measure(window: tiny.tokens + 1);

    expect(b.fits, isFalse);
    expect(b.largestFittingSet.map((c) => c.path), ['tiny.txt']);

    // What the set is for: whatever it returns has to fit. Naming the members
    // does not say that, and the CLI recommends this set to a user who is
    // already over budget.
    write('small.txt', 'hello there');
    final three = measure();
    final cheapest = three.costs.last;
    final window = cheapest.tokens + 1;
    final capped = measure(window: window);

    expect(capped.costs.length, 3);
    expect(
      capped.largestFittingSet.fold<int>(0, (sum, c) => sum + c.tokens),
      lessThanOrEqualTo(window),
    );
  });

  test('density is bytes per token', () {
    write('a.txt', 'the quick brown fox jumps over the lazy dog');

    final cost = measure().costs.single;

    expect(cost.density, cost.bytes / cost.tokens);
  });

  test('source code costs more tokens per byte than prose', () {
    write('prose.txt', 'the quick brown fox jumps over the lazy dog ' * 20);
    write(
      'code.dart',
      "import 'dart:io';\nvoid main() { print('hi'); }\n" * 20,
    );

    final b = measure();
    final prose = b.costs.firstWhere((c) => c.path == 'prose.txt');
    final code = b.costs.firstWhere((c) => c.path == 'code.dart');

    // Punctuation and identifiers fragment into more tokens per byte, which is
    // why a repository fills a window faster than its byte count suggests.
    expect(prose.density, greaterThan(code.density));
  });

  test('a mismatched tokenizer undercounts opaque blobs', () {
    // BERT wordpiece maps an unknown contiguous run to a single [UNK], so a
    // 1200-byte blob measures as 3 tokens. This is a property of the tokenizer,
    // not of the tool: point --tokenizer at the model you actually send to, or
    // minified and base64 payloads will look free.
    write('blob.txt', 'aZ9' * 400);

    final cost = measure().costs.single;

    expect(cost.bytes, 1200);
    expect(cost.tokens, lessThan(10));
  });
}
