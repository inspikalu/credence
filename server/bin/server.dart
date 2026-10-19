import 'dart:io';

import 'package:credence_server/credence_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as io;

Future<void> main() async {
  final ServerConfig config;
  try {
    config = ServerConfig.fromEnvironment(Platform.environment);
  } on FormatException catch (e) {
    stderr.writeln('Config error: ${e.message}');
    exit(64);
  }

  Directory(config.dataDir).createSync(recursive: true);
  final store = Store.open(p.join(config.dataDir, 'credence.sqlite'));
  final handler = buildHandler(config: config, store: store, logRequests: true);

  final server = await io.serve(
    handler,
    InternetAddress.anyIPv4,
    config.port,
    poweredByHeader: null,
  );
  server.autoCompress = true;
  stdout.writeln('Credence listening on http://localhost:${server.port}');
  stdout.writeln(config.describe());
  if (config.publicBaseUrl == null) {
    stderr.writeln(
      'WARNING: PUBLIC_BASE_URL is not set. Link previews use the checked '
      'Host header (or http://localhost:${config.port} when it fails the '
      'check). Set PUBLIC_BASE_URL in production.',
    );
  }
  if (config.trustProxy) {
    stdout.writeln(
      'TRUST_PROXY=true: X-Forwarded-Host, X-Forwarded-Proto and '
      'X-Forwarded-For are trusted. Only use behind a proxy that sets them.',
    );
  }

  Future<void> shutdown(ProcessSignal signal) async {
    stdout.writeln('Stopping (${signal.name})');
    await server.close();
    store.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
