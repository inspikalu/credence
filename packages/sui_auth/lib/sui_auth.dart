/// Sign in with Sui for Dart servers.
///
/// Platform-neutral (no `dart:io`, no Flutter): sign-in messages, signature
/// verification, nonce and session logic, cookie helpers and shelf
/// middleware/handlers. SQLite storage is in `package:sui_auth/sqlite.dart`;
/// test helpers in `package:sui_auth/testing.dart`.
library;

export 'src/address.dart'
    show
        isCanonicalSuiAddress,
        normalizeSuiAddress,
        tryNormalizeSuiAddress,
        suiAddressFromFlaggedKey;
export 'src/auth.dart';
export 'src/chain.dart';
export 'src/cookies.dart';
export 'src/message.dart';
export 'src/shelf.dart';
export 'src/signature/graphql.dart';
export 'src/signature/multisig.dart'
    show MultiSigMember, MultiSigPartial, MultiSigParts, parseMultiSig;
export 'src/signature/passkey.dart'
    show
        PasskeyAuthenticatorParts,
        parsePasskeyAuthenticator,
        verifyPasskeyAuthenticator;
export 'src/signature/scheme.dart';
export 'src/signature/verifier.dart';
export 'src/signature/zklogin.dart'
    show
        ZkLoginSignatureParts,
        parseZkLoginSignature,
        zkLoginAddress,
        zkLoginPublicIdentifier,
        decodeZkLoginClaim;
export 'src/store.dart';
