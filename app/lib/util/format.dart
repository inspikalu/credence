/// Small formatting helpers. Dates are shown in UTC with the month spelled
/// out, so "03/04" can never be misread.
library;

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `15 Oct 2026`
String formatDate(DateTime date) {
  final d = date.toUtc();
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// `15 Oct 2026, 14:05 UTC`
String formatDateTime(DateTime date) {
  final d = date.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${formatDate(d)}, ${two(d.hour)}:${two(d.minute)} UTC';
}

/// Formats an issue date stored as `YYYY-MM-DD`. Falls back to the raw text.
String formatIssueDate(String isoDate) {
  final parsed = parseIsoDate(isoDate);
  return parsed == null ? isoDate : formatDate(parsed);
}

/// Parses `YYYY-MM-DD` strictly (rejects 2026-02-30).
DateTime? parseIsoDate(String input) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(input.trim());
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final d = int.parse(m.group(3)!);
  final date = DateTime.utc(y, mo, d);
  if (date.year != y || date.month != mo || date.day != d) return null;
  return date;
}

String isoDate(DateTime date) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year.toString().padLeft(4, '0')}-${two(date.month)}-'
      '${two(date.day)}';
}

/// `1.4 MB`, `820 KB`, `512 bytes`
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes bytes';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return '${kb < 10 ? kb.toStringAsFixed(1) : kb.round()} KB';
  }
  final mb = bytes / (1024 * 1024);
  final text = mb.toStringAsFixed(mb < 10 ? 1 : 0);
  return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} MB';
}

/// "1 document", "3 documents"
String plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// A WAL amount from FROST (10^-9 WAL), short and never misleadingly zero:
/// `0.0012 WAL`, `1.25 WAL`, `less than 0.0001 WAL`.
String formatWal(BigInt frost) => _formatCoin(frost, 'WAL');

String formatSui(BigInt mist) => _formatCoin(mist, 'SUI');

String _formatCoin(BigInt frost, String symbol) {
  if (frost <= BigInt.zero) return '0 $symbol';
  final perWal = BigInt.from(1000000000);
  // Four decimals, rounded up so the estimate is never below the charge.
  final tenThousandths =
      (frost * BigInt.from(10000) + perWal - BigInt.one) ~/ perWal;
  if (tenThousandths == BigInt.one && frost * BigInt.from(10000) < perWal) {
    return 'less than 0.0001 $symbol';
  }
  final whole = tenThousandths ~/ BigInt.from(10000);
  var decimals = (tenThousandths % BigInt.from(10000))
      .toString()
      .padLeft(4, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  if (decimals.isNotEmpty) decimals = '.$decimals';
  return '$whole$decimals $symbol';
}

/// `26 epochs (about 26 days)`, from the network's epoch length.
String formatEpochs(int epochs, int epochDurationHours) {
  final days = epochs * epochDurationHours / 24;
  final span = days >= 60
      ? 'about ${(days / 30.4).round()} months'
      : days < 1.5
      ? 'about 1 day'
      : 'about ${days.round()} days';
  return '$epochs ${epochs == 1 ? 'epoch' : 'epochs'} ($span)';
}
