import 'dart:typed_data';

import '../bcs.dart';
import '../bytes.dart';
import '../crypto.dart';
import 'scheme.dart';

const maxMultiSigMembers = 10;

/// One public key in a multisig, with its weight.
class MultiSigMember {
  const MultiSigMember(this.scheme, this.publicKey, this.weight);

  final SuiSignatureScheme scheme;

  /// Raw key bytes as stored in the multisig (for zkLogin, the public
  /// identifier bytes).
  final Uint8List publicKey;
  final int weight;
}

/// One member's signature inside a multisig.
class MultiSigPartial {
  const MultiSigPartial(this.scheme, this.signature, this.memberIndex);

  final SuiSignatureScheme scheme;

  /// For Ed25519 and Secp256k1/r1, the 64-byte signature. For passkey and
  /// zkLogin, the scheme's serialized authenticator bytes.
  final Uint8List signature;
  final int memberIndex;
}

class MultiSigParts {
  const MultiSigParts({
    required this.partials,
    required this.bitmap,
    required this.members,
    required this.threshold,
  });

  final List<MultiSigPartial> partials;
  final int bitmap;
  final List<MultiSigMember> members;
  final int threshold;

  /// blake2b256(0x03 || threshold (u16 LE) || flag_i || pk_i || weight_i ...)
  String get address {
    final parts = <int>[
      SuiSignatureScheme.multisig.flag,
      threshold & 0xff,
      (threshold >> 8) & 0xff,
    ];
    for (final m in members) {
      parts
        ..add(m.scheme.flag)
        ..addAll(m.publicKey)
        ..add(m.weight);
    }
    return '0x${toHex(blake2b256(parts))}';
  }
}

// BCS enum variant order, shared by CompressedSignature and PublicKey.
const _variants = [
  SuiSignatureScheme.ed25519,
  SuiSignatureScheme.secp256k1,
  SuiSignatureScheme.secp256r1,
  SuiSignatureScheme.zkLogin,
  SuiSignatureScheme.passkey,
  SuiSignatureScheme.mldsa65,
];

SuiSignatureScheme _variant(BcsReader r) {
  final index = r.uleb128();
  if (index >= _variants.length) {
    throw const BcsFormatException('Unknown multisig variant');
  }
  return _variants[index];
}

/// Parses and validates BCS `MultiSig` bytes (without the 0x03 flag).
MultiSigParts parseMultiSig(Uint8List bytes) {
  final r = BcsReader(bytes);
  final sigs = r.vector((r) {
    final scheme = _variant(r);
    final signature = switch (scheme) {
      SuiSignatureScheme.ed25519 ||
      SuiSignatureScheme.secp256k1 ||
      SuiSignatureScheme.secp256r1 => r.fixedBytes(64),
      SuiSignatureScheme.mldsa65 => r.fixedBytes(3309),
      _ => r.byteVector(),
    };
    return (scheme, signature);
  }, max: maxMultiSigMembers);
  final bitmap = r.u16();
  final members = r.vector((r) {
    final scheme = _variant(r);
    final publicKey = switch (scheme) {
      SuiSignatureScheme.ed25519 => r.fixedBytes(32),
      SuiSignatureScheme.secp256k1 ||
      SuiSignatureScheme.secp256r1 ||
      SuiSignatureScheme.passkey => r.fixedBytes(33),
      SuiSignatureScheme.mldsa65 => r.fixedBytes(1952),
      _ => r.byteVector(),
    };
    final weight = r.u8();
    return MultiSigMember(scheme, publicKey, weight);
  }, max: maxMultiSigMembers);
  final threshold = r.u16();
  r.expectEnd();

  if (members.isEmpty || members.length > maxMultiSigMembers) {
    throw const BcsFormatException('A multisig needs 1 to 10 keys');
  }
  if (threshold < 1) throw const BcsFormatException('Invalid threshold');
  var total = 0;
  for (var i = 0; i < members.length; i++) {
    if (members[i].weight < 1) throw const BcsFormatException('Invalid weight');
    total += members[i].weight;
    for (var j = 0; j < i; j++) {
      if (bytesEqual(members[i].publicKey, members[j].publicKey)) {
        throw const BcsFormatException('Duplicate multisig key');
      }
    }
  }
  if (threshold > total) {
    throw const BcsFormatException('Unreachable multisig threshold');
  }
  if (bitmap >= 1 << maxMultiSigMembers) {
    throw const BcsFormatException('Invalid multisig bitmap');
  }
  final indices = [
    for (var i = 0; i < maxMultiSigMembers; i++)
      if (bitmap & (1 << i) != 0) i,
  ];
  if (sigs.isEmpty || indices.length != sigs.length) {
    throw const BcsFormatException('Multisig bitmap does not match signatures');
  }
  final partials = <MultiSigPartial>[];
  for (var i = 0; i < sigs.length; i++) {
    final index = indices[i];
    if (index >= members.length) {
      throw const BcsFormatException('Multisig bitmap points past the keys');
    }
    final (scheme, signature) = sigs[i];
    if (members[index].scheme != scheme) {
      throw const BcsFormatException('Multisig signature scheme mismatch');
    }
    partials.add(MultiSigPartial(scheme, signature, index));
  }
  return MultiSigParts(
    partials: partials,
    bitmap: bitmap,
    members: members,
    threshold: threshold,
  );
}
