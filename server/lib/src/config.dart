/// Server configuration, read from environment variables only.
library;

import 'package:sui_auth/sui_auth.dart' show SuiChain;

/// Which Walrus network uploads are paid for and stored on (from
/// SUI_CHAIN).
enum WalrusNetwork { testnet, mainnet }

/// Runtime settings for the Credence server.
class ServerConfig {
  ServerConfig({
    this.port = 8094,
    Uri? aggregatorUrl,
    this.graphqlUrl,
    this.epochs = 26,
    this.maxUploadMb = 10,
    this.dataDir = 'data',
    this.publicBaseUrl,
    this.webDir = '../app/build/web',
    this.corsAllowOrigin,
    this.trustProxy = false,
    this.suiChain = SuiChain.testnet,
  }) : aggregatorUrl =
           aggregatorUrl ??
           Uri.parse(
             suiChain == SuiChain.mainnet
                 ? mainnetAggregator
                 : defaultAggregator,
           );

  /// Reads settings from [env] (normally `Platform.environment`).
  ///
  /// Throws [FormatException] with a readable message for invalid values.
  factory ServerConfig.fromEnvironment(Map<String, String> env) {
    int intOf(String key, int fallback, {int min = 1, int max = 1 << 30}) {
      final raw = env[key]?.trim();
      if (raw == null || raw.isEmpty) return fallback;
      final value = int.tryParse(raw);
      if (value == null || value < min || value > max) {
        throw FormatException('$key must be a whole number from $min to $max');
      }
      return value;
    }

    Uri? urlOf(String key) {
      final raw = env[key]?.trim();
      if (raw == null || raw.isEmpty) return null;
      final value = Uri.tryParse(raw);
      if (value == null ||
          !(value.isScheme('http') || value.isScheme('https')) ||
          value.host.isEmpty ||
          value.userInfo.isNotEmpty ||
          value.hasQuery ||
          value.hasFragment) {
        throw FormatException('$key must be an http(s) URL');
      }
      return value;
    }

    String? optional(String key) {
      final raw = env[key]?.trim();
      return raw == null || raw.isEmpty ? null : raw;
    }

    final publicBase = urlOf('PUBLIC_BASE_URL')?.toString();
    if (publicBase != null) {
      final parsed = Uri.tryParse(publicBase);
      if (parsed == null || (parsed.path.isNotEmpty && parsed.path != '/')) {
        throw const FormatException(
          'PUBLIC_BASE_URL must be an http(s) origin',
        );
      }
    }

    return ServerConfig(
      port: intOf('PORT', 8094, max: 65535),
      aggregatorUrl: urlOf('AGGREGATOR_URL'),
      graphqlUrl: urlOf('SUI_GRAPHQL_URL'),
      epochs: intOf('EPOCHS', 26, max: maxEpochs),
      maxUploadMb: intOf('MAX_UPLOAD_MB', 10, max: 100),
      dataDir: optional('DATA_DIR') ?? 'data',
      publicBaseUrl: publicBase == null
          ? null
          : publicBase.endsWith('/')
          ? publicBase.substring(0, publicBase.length - 1)
          : publicBase,
      webDir: optional('WEB_DIR') ?? '../app/build/web',
      corsAllowOrigin: optional('CORS_ALLOW_ORIGIN'),
      suiChain: _chain(optional('SUI_CHAIN')),
      trustProxy: const {
        'true',
        '1',
        'yes',
      }.contains(optional('TRUST_PROXY')?.toLowerCase()),
    );
  }

  static SuiChain _chain(String? raw) {
    if (raw == null) return SuiChain.testnet;
    final chain = SuiChain.tryParse(raw);
    if (chain == null) {
      throw const FormatException('SUI_CHAIN must be testnet or mainnet');
    }
    return chain;
  }

  static const defaultAggregator =
      'https://aggregator.walrus-testnet.walrus.space';
  static const mainnetAggregator =
      'https://aggregator.walrus-mainnet.walrus.space';

  /// Walrus accepts storage at most this many epochs ahead (both networks).
  static const maxEpochs = 53;

  final int port;

  /// Where people's browsers (and the server's claim check) read blobs.
  /// Defaults to Mysten's aggregator for [suiChain].
  final Uri aggregatorUrl;

  /// Sui GraphQL endpoint for claim checks (SUI_GRAPHQL_URL). Null uses
  /// Mysten's endpoint for [suiChain]; tests point it at a fake.
  final Uri? graphqlUrl;

  /// The storage period the app suggests, in epochs. People pay for their
  /// own storage and may choose another period.
  final int epochs;

  /// Largest file this site lists (MAX_UPLOAD_MB). People pay for their own
  /// storage, so this is a policy for the site, not a cost control.
  final int maxUploadMb;
  final String dataDir;
  final String? publicBaseUrl;
  final String webDir;

  /// Development and test only: an origin allowed to call the API from
  /// another port. Leave unset in production (the app is same-origin).
  final String? corsAllowOrigin;

  /// Trust `X-Forwarded-Host`, `X-Forwarded-Proto` and `X-Forwarded-For`
  /// (TRUST_PROXY=true). Only set this behind a reverse proxy that
  /// overwrites those headers; otherwise any client can forge them.
  final bool trustProxy;

  /// Sui network for sign-in (SUI_CHAIN, default testnet).
  final SuiChain suiChain;

  /// The origin people open: the signed sign-in domain and the base of
  /// every absolute URL. PUBLIC_BASE_URL, or localhost on [port].
  String get siteUrl => publicBaseUrl ?? 'http://localhost:$port';

  int get maxUploadBytes => maxUploadMb * 1024 * 1024;

  WalrusNetwork get network => suiChain == SuiChain.mainnet
      ? WalrusNetwork.mainnet
      : WalrusNetwork.testnet;

  /// Mysten's Sui full node for [network]: the browser's Walrus writer reads
  /// the chain from it (gRPC-web).
  Uri get fullNodeUrl => Uri.parse('https://fullnode.${network.name}.sui.io');

  /// Mysten's upload relay for [network]: the browser sends the file's bytes
  /// there after the wallet has paid.
  Uri get uploadRelayUrl =>
      Uri.parse('https://upload-relay.${network.name}.walrus.space');

  /// Approximate length of one Walrus epoch, used only to estimate dates.
  /// Testnet epochs last one day; mainnet epochs last two weeks.
  int get epochDurationHours => switch (network) {
    WalrusNetwork.mainnet => 24 * 14,
    WalrusNetwork.testnet => 24,
  };

  /// A description safe to log (there are no secrets in the config).
  String describe() =>
      'port=$port aggregator=$aggregatorUrl '
      'graphql=${graphqlUrl ?? '(default for ${network.name})'} '
      'network=${network.name} suggestedEpochs=$epochs '
      'maxUploadMb=$maxUploadMb dataDir=$dataDir webDir=$webDir '
      'publicBaseUrl=${publicBaseUrl ?? '(unset: checked Host header)'} '
      'trustProxy=$trustProxy suiChain=${suiChain.id}';
}
