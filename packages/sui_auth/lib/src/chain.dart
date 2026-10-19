/// A Sui network, named the way the Wallet Standard names chains.
enum SuiChain {
  mainnet('sui:mainnet', 'https://graphql.mainnet.sui.io/graphql'),
  testnet('sui:testnet', 'https://graphql.testnet.sui.io/graphql'),
  devnet('sui:devnet', 'https://graphql.devnet.sui.io/graphql');

  const SuiChain(this.id, this._graphql);

  /// Wallet Standard chain id, for example `sui:testnet`.
  final String id;
  final String _graphql;

  /// Mysten's public GraphQL endpoint for this network.
  Uri get graphqlEndpoint => Uri.parse(_graphql);

  /// Parses `sui:testnet`, `testnet`, and so on. Returns null if unknown.
  static SuiChain? tryParse(String? value) {
    if (value == null) return null;
    final v = value.trim().toLowerCase();
    for (final chain in values) {
      if (chain.id == v || chain.name == v) return chain;
    }
    return null;
  }

  @override
  String toString() => id;
}
