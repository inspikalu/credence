/// A small in-memory sliding-window limiter.
class RateLimiter {
  RateLimiter({
    required this.limit,
    required this.window,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int limit;
  final Duration window;
  final DateTime Function() _clock;
  final Map<String, List<DateTime>> _hits = {};

  /// Records a hit for [key]. Returns false when the limit is reached.
  bool allow(String key) {
    final now = _clock();
    final cutoff = now.subtract(window);
    final list = _hits.putIfAbsent(key, () => <DateTime>[]);
    list.removeWhere((t) => t.isBefore(cutoff));
    if (_hits.length > 10000) {
      _hits.removeWhere((_, v) => v.isEmpty || v.last.isBefore(cutoff));
    }
    if (list.length >= limit) return false;
    list.add(now);
    return true;
  }
}
