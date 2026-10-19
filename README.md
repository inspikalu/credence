# Credence

**A certificate vault with a check link anyone can open.**

People and small organizations store certificates and documents (course certificates, attendance, awards, receipts) and share a link anyone can open to check a copy of a document.

Files are stored on [Walrus](https://walrus.xyz) through [Dartus](https://pub.dev/packages/dartus),
the Dart SDK for Walrus. Each vault owner's own Sui wallet (for example [Slush](https://slush.app))
pays for what they store and owns the Blob object on Sui. The server holds no keys and pays for
nothing.

## Features

- **Vaults.** An owner signs in with a Sui wallet and creates a personal or organization vault, managed from any device.
- **Documents.** PDF, PNG, JPEG or WebP (10 MB each) with title, issuer, recipient, issue date and notes. The browser computes each file's SHA-256 before upload.
- **Check pages.** Each document has a link and a QR code showing a preview, the details, the Walrus blob ID, the fingerprint and when paid storage ends.
- **Two checks, in the browser.** Re-fetch the stored file from Walrus and compare its fingerprint, or drop a copy you received to compare it on your device (it is never uploaded).
- **Revocation and history.** Owners can revoke a document or edit its details; every change is shown on the check page with a note.

## How it works

- **`app/`**: Flutter web app. Uploads go through Dartus `WalrusWriter`: the blob ID is computed
  in a Web Worker, the wallet approves the storage payment, the bytes go to the Walrus upload
  relay, and the wallet approves once more to certify. Reads use Dartus `WalrusClient`.
- **`server/`**: Dart ([shelf](https://pub.dev/packages/shelf)) server. Serves the landing page
  and the web app, handles Sign in with Sui, keeps metadata in SQLite, and checks every upload
  on Sui (a certified Walrus Blob owned by the signed-in address) before listing it.
- **`packages/`**: shared packages for wallet connection, sign-in, blob checks and upload
  recovery.

```
app/        Flutter web app, served at /app
server/     Dart server and API
packages/   shared Dart packages
Dockerfile  one image with the app and the server
```

## Running locally

With Docker:

```sh
docker build -t credence .
docker run -p 8094:8094 -v credence-data:/data -e PUBLIC_BASE_URL=http://localhost:8094 credence
```

Or with Flutter 3.44.2:

```sh
cd app && flutter pub get
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run
cd ../server && dart pub get
WEB_DIR=../app/build/web PORT=8094 PUBLIC_BASE_URL=http://localhost:8094 dart run bin/server.dart
```

Open http://localhost:8094 for the landing page and http://localhost:8094/app for the app.
Sign-in is bound to `PUBLIC_BASE_URL`, so open exactly that address (`127.0.0.1` is a different
origin). By default everything runs on Sui testnet.

## Configuration

Environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8094` | HTTP port |
| `PUBLIC_BASE_URL` | `http://localhost:<PORT>` | The exact URL people open. Sign-in messages are bound to it, and share links and link previews are built from it. Set it in production. |
| `SUI_CHAIN` | `testnet` | `testnet` or `mainnet` |
| `AGGREGATOR_URL` | Mysten's aggregator for `SUI_CHAIN` | Walrus aggregator for reads |
| `EPOCHS` | `26` | Storage period the app suggests (a mainnet epoch is two weeks). Users pay for what they choose. |
| `MAX_UPLOAD_MB` | `10` | Largest file accepted |
| `DATA_DIR` | `data` | Folder for the SQLite database |
| `TRUST_PROXY` | `false` | Set to `true` behind a reverse proxy that sets `X-Forwarded-*` headers |

## Deploying

The `Dockerfile` builds the web app and the server into one small image. Run it on any host that
supports Docker and give it a persistent volume at `/data`. For mainnet:

```sh
PUBLIC_BASE_URL=https://credence.example.com
SUI_CHAIN=mainnet
AGGREGATOR_URL=https://aggregator.walrus-mainnet.walrus.space
TRUST_PROXY=true   # when behind the host's proxy
```

There is no publisher to run and no wallet to fund: every upload is paid for by the user's
wallet.

## Licence

MIT. See [LICENSE](LICENSE).
