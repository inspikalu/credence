import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'models/models.dart';
import 'platform/browser.dart';
import 'screens/document_screen.dart';
import 'screens/home_screen.dart';
import 'screens/manage_screen.dart';
import 'screens/vault_screen.dart';
import 'services/account.dart';
import 'services/api_client.dart';
import 'services/services.dart';
import 'services/storage.dart';
import 'services/walrus_service.dart';
import 'theme/theme.dart';
import 'theme/tokens.dart';
import 'widgets/common.dart';
import 'widgets/mark.dart';
import 'widgets/page_frame.dart';

typedef WalrusFactory = WalrusService Function(AppConfig config);
typedef StorageFactory = DocumentStorage Function(AppConfig config);
typedef AccountFactory = Account Function(AppConfig config);

/// Loads server config, then runs the router.
class CredenceApp extends StatefulWidget {
  const CredenceApp({
    super.key,
    required this.api,
    required this.browser,
    required this.accountFactory,
    required this.walrusFactory,
    required this.storageFactory,
    this.initialLocation,
  });

  final ApiClient api;
  final Browser browser;
  final AccountFactory accountFactory;
  final WalrusFactory walrusFactory;

  /// Wallet-paid writes (Dartus `WalrusWriter` in the app).
  final StorageFactory storageFactory;

  /// Where to start. On web, main() passes the path the page was opened
  /// with, because the loading screen resets the browser URL to `/`.
  final String? initialLocation;

  @override
  State<CredenceApp> createState() => _CredenceAppState();
}

class _CredenceAppState extends State<CredenceApp> {
  AppServices? _services;
  GoRouter? _router;
  ApiException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _router?.dispose();
    _services?.walrus.close();
    _services?.storage.close();
    _services?.account.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await widget.api.config();
      final account = widget.accountFactory(config);
      final services = AppServices(
        api: widget.api,
        walrus: widget.walrusFactory(config),
        storage: widget.storageFactory(config),
        browser: widget.browser,
        account: account,
        config: config,
      );
      // Whether someone is signed in is checked in the background: check
      // pages never wait for it.
      unawaited(account.start());
      if (!mounted) return;
      setState(() {
        _services = services;
        _router = buildRouter(initialLocation: widget.initialLocation);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    final router = _router;
    if (services != null && router != null) {
      return Services(
        services: services,
        child: AccountScope(
          account: services.account,
          child: MaterialApp.router(
            title: 'Credence',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            routerConfig: router,
          ),
        ),
      );
    }
    return MaterialApp(
      title: 'Credence',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(S.x6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CredenceLogo(size: 36),
                  const SizedBox(height: S.x6),
                  if (_loading)
                    const LoadingView(label: 'Opening Credence…')
                  else
                    ErrorView(
                      title: 'Credence is not answering',
                      message: _error?.message ?? 'Try again in a moment.',
                      onRetry: _load,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Page<void> _page(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: ValueKey(state.uri.path),
      child: child,
      // Enter with a short, strong ease-out; leave faster than we arrived.
      transitionDuration: Motion.enter,
      reverseTransitionDuration: Motion.exit,
      transitionsBuilder: (context, animation, _, child) => FadeTransition(
        opacity: Motion.reduced(context)
            ? const AlwaysStoppedAnimation(1)
            : CurvedAnimation(
                parent: animation,
                curve: Motion.easeOut,
                reverseCurve: Curves.easeOut,
              ),
        child: child,
      ),
    );

GoRouter buildRouter({String? initialLocation}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    // The marketing page lives at `/` (plain HTML served by the server). If
    // the Flutter app is ever loaded there, send it to its own home.
    GoRoute(path: '/', redirect: (c, s) => '/app'),
    GoRoute(path: '/app', pageBuilder: (c, s) => _page(s, const HomeScreen())),
    GoRoute(
      path: '/v/:id',
      pageBuilder: (c, s) =>
          _page(s, VaultScreen(vaultId: s.pathParameters['id']!)),
    ),
    GoRoute(
      path: '/v/:id/manage',
      pageBuilder: (c, s) => _page(
        s,
        ManageScreen(
          vaultId: s.pathParameters['id']!,
          justCreated: s.uri.queryParameters['new'] == '1',
        ),
      ),
    ),
    // Old admin links (secret keys are gone): send them to the manage page,
    // which asks the owner to sign in.
    GoRoute(
      path: '/v/:id/admin',
      redirect: (c, s) => '/v/${s.pathParameters['id']}/manage',
    ),
    GoRoute(
      path: '/d/:id',
      pageBuilder: (c, s) =>
          _page(s, DocumentScreen(documentId: s.pathParameters['id']!)),
    ),
  ],
  errorPageBuilder: (c, s) => _page(
    s,
    Title(
      title: 'Not found · Credence',
      color: C.ledger,
      child: PageFrame(child: NotFoundView()),
    ),
  ),
);
