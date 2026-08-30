// How long are CSI parameters, really?
//
//   dart run script/csi_param_census.dart
//
// Phase 5.4 rejected CSI bulk scanning twice on throughput alone, and phase
// 5.5 rejected a third implementation. This counts the thing all three were
// betting on, so the front closes on arithmetic rather than on three negative
// benchmarks.
//
// A bulk scanner pays its setup once per *parameter*, and earns it back once
// per digit after the first - the first digit is already in hand from the
// `consume()` that got the parser into the digit branch. So the question is
// how many parameters carry a second digit at all.
//
// The answer on `parse_bench`'s two CSI-heavy workloads is that most do not,
// and that the scanner ends up making more calls than it removes:
//
//   sgr        779 parameters, 630 digits left for a bulk path
//   altscreen  300 parameters, 191 digits left for a bulk path
//
// 300 calls to remove 191 is not a trade, which is why `altscreen` measured
// worst in every attempt. `sgr` gets closer because its parameters are longer
// (42.9% two-digit, 19.0% three-digit against altscreen's 30.3% and 16.7%),
// and it measured flat rather than negative - the same ordering the benchmark
// showed, arrived at without running it.
//
// The workload builders below are copies of the ones in `bin/parse_bench.dart`.
// They are duplicated rather than imported because those are private to that
// entry point; if a workload there changes, change it here too.

const _chunkSize = 8192;
const _columns = 170;
const _rows = 50;

void main() {
  final workloads = <String, String Function(int)>{
    'sgr': _sgrChunk,
    'altscreen': _altScreenChunk,
  };

  for (final entry in workloads.entries) {
    final census = _census(entry.value(1));
    print(entry.key);
    print('  ${census.totalBytes} bytes, '
        'CSI ${census.csiBytes} (${_pct(census.csiBytes, census.totalBytes)}), '
        'of which digits ${census.digitBytes} '
        '(${_pct(census.digitBytes, census.totalBytes)} of the stream)');

    final lengths = census.paramsByLength.keys.toList()..sort();
    for (final length in lengths) {
      final count = census.paramsByLength[length]!;
      print('  $length-digit parameters: $count '
          '(${_pct(count, census.params)}), '
          'digits past the first: ${(length - 1) * count}');
    }

    print('  a bulk scanner would be called ${census.params} times '
        'to take ${census.digitsPastFirst} digits, '
        '${census.productiveCalls} of those calls productive '
        '(${_pct(census.productiveCalls, census.params)})');
    print('');
  }
}

String _pct(int part, int whole) {
  if (whole == 0) return '0.0%';
  return '${(part / whole * 100).toStringAsFixed(1)}%';
}

/// Walks [data] the way `_consumeCsi` does: into a CSI on `ESC [`, then over
/// its bytes until a final byte in `@`..`~` ends it, counting the runs of
/// digits on the way.
_Census _census(String data) {
  final paramsByLength = <int, int>{};
  var csiBytes = 0;
  var digitBytes = 0;
  var offset = 0;

  while (offset < data.length) {
    final isCsiStart = data.codeUnitAt(offset) == 0x1b &&
        offset + 1 < data.length &&
        data.codeUnitAt(offset + 1) == 0x5b;
    if (!isCsiStart) {
      offset++;
      continue;
    }

    offset += 2;
    csiBytes += 2;
    var run = 0;
    while (offset < data.length) {
      final codeUnit = data.codeUnitAt(offset);
      offset++;
      csiBytes++;

      if (codeUnit >= 0x30 && codeUnit <= 0x39) {
        digitBytes++;
        run++;
        continue;
      }

      if (run > 0) {
        paramsByLength[run] = (paramsByLength[run] ?? 0) + 1;
        run = 0;
      }
      if (codeUnit >= 0x40 && codeUnit <= 0x7e) break;
    }
  }

  return _Census(
    totalBytes: data.length,
    csiBytes: csiBytes,
    digitBytes: digitBytes,
    paramsByLength: paramsByLength,
  );
}

class _Census {
  const _Census({
    required this.totalBytes,
    required this.csiBytes,
    required this.digitBytes,
    required this.paramsByLength,
  });

  final int totalBytes;
  final int csiBytes;
  final int digitBytes;
  final Map<int, int> paramsByLength;

  /// One call per parameter, whether or not it has anything to take.
  int get params => paramsByLength.values.fold(0, (sum, n) => sum + n);

  /// What a bulk scanner would actually take: every digit but the first of
  /// each parameter, since the first is already consumed.
  int get digitsPastFirst =>
      paramsByLength.entries.fold(0, (sum, e) => sum + (e.key - 1) * e.value);

  /// Calls that take at least one digit. The rest are setup for nothing.
  int get productiveCalls => paramsByLength.entries
      .where((e) => e.key > 1)
      .fold(0, (sum, e) => sum + e.value);
}

/// Heavy SGR churn, the workload with the largest share of CSI bytes.
String _sgrChunk(int seed) {
  final buffer = StringBuffer();
  var line = seed * 1000;
  while (buffer.length < _chunkSize) {
    for (var segment = 0; segment < 6; segment++) {
      buffer.write('\x1b[38;5;${(line * 13 + segment * 31) % 256}m');
      buffer.write('segment${segment}_of_line_$line ');
    }
    buffer.write('\x1b[0m\r\n');
    line++;
  }
  return buffer.toString();
}

/// Cursor-addressed full-screen redraw, the workload with the most CSI
/// sequences and the shortest parameters.
String _altScreenChunk(int seed) {
  final buffer = StringBuffer();
  var frame = seed * 100;
  while (buffer.length < _chunkSize) {
    for (var row = 0; row < _rows; row++) {
      buffer.write('\x1b[${row + 1};1H');
      buffer.write('\x1b[48;5;${(row * 3 + frame) % 256}m');
      final bar = (frame + row) % _columns;
      for (var column = 0; column < _columns; column++) {
        buffer.write(column < bar ? '#' : ' ');
      }
      buffer.write('\x1b[0m');
    }
    frame++;
  }
  return buffer.toString();
}
