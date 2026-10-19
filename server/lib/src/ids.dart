import 'dart:math';

final Random _random = Random.secure();

/// Lowercase letters and digits without look-alikes (no 0, 1, i, l, o).
const _alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

/// A random identifier for vaults and documents.
String newId([int length = 12]) => List.generate(
  length,
  (_) => _alphabet[_random.nextInt(_alphabet.length)],
).join();
