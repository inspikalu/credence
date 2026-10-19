/// Server-side checks for Walrus blobs that people stored with their own
/// wallet: the Blob object is a certified Walrus blob owned by the expected
/// address. Reads Sui GraphQL and a Walrus aggregator; no keys involved.
library;

export 'src/blob_check.dart';
