import 'package:sqlite3/sqlite3.dart';
import 'package:sui_auth/sqlite.dart';
import 'package:sui_auth/sui_auth.dart';

import 'config.dart';

/// The session cookie. One name per app: browsers share cookies across
/// localhost ports, so a shared name would sign people out of other apps.
const credenceCookieName = 'credence_session';

/// Sign in with Sui for vault owners. Nonces and sessions live in the app's
/// own SQLite file (`sui_auth_*` tables).
///
/// [verifier] and [clock] are for tests (a local verifier never touches the
/// network; a fake clock tests expiry).
SuiAuth buildAuth(
  ServerConfig config,
  Database db, {
  SuiSignatureVerifier? verifier,
  DateTime Function()? clock,
  List<String>? allowedOrigins,
}) {
  final store = SqliteSuiAuthStore(db);
  return SuiAuth(
    config: SuiAuthConfig.fromBaseUrl(
      // The signed domain, the URI line and the only origin allowed to POST
      // to /api/auth/*. It must be exactly the address people open.
      config.siteUrl,
      chain: config.suiChain,
      statement:
          'Sign in to Credence to manage your vaults. This does not send a '
          'transaction or cost gas.',
      cookieName: credenceCookieName,
      allowedOrigins: allowedOrigins,
    ),
    nonces: store,
    sessions: store,
    verifier: verifier,
    clock: clock,
  );
}
