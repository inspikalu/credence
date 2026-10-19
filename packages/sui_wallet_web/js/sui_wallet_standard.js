/*! sui_wallet_web Wallet Standard bridge v1 | MIT */
// Finds wallets through the Wallet Standard (https://github.com/wallet-standard)
// and gives Dart a small promise-based API at window.__suiWalletWeb.
//
// Discovery follows @wallet-standard/app:
// * wallets that loaded before us answer the `wallet-standard:app-ready`
//   event we dispatch, by calling api.register(wallet);
// * wallets that load after us dispatch `wallet-standard:register-wallet`
//   with a callback, which we call with the same api.
//
// Every method resolves to {ok: true, value} or {ok: false, error}; nothing
// rejects, so Dart never has to unwrap foreign JS exceptions.
(function () {
  'use strict';
  var w = window;
  if (w.__suiWalletWeb && w.__suiWalletWeb.version) return;

  var entries = []; // {id, wallet, off}
  var nextId = 1;
  var listeners = [];

  function emit(type, id, changed) {
    for (var i = 0; i < listeners.length; i++) {
      try {
        listeners[i](type, id || null, changed || []);
      } catch (e) {
        console.error('[sui_wallet_web] listener failed', e);
      }
    }
  }

  function find(id) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].id === id) return entries[i];
    }
    return null;
  }

  function watch(entry) {
    var events = safe(function () {
      return entry.wallet.features && entry.wallet.features['standard:events'];
    });
    if (!events || typeof events.on !== 'function') return;
    try {
      entry.off = events.on('change', function (properties) {
        emit('change', entry.id, Object.keys(properties || {}));
      });
    } catch (e) {
      console.error('[sui_wallet_web] could not watch wallet', e);
    }
  }

  function register() {
    var added = [];
    for (var i = 0; i < arguments.length; i++) {
      var wallet = arguments[i];
      if (!wallet || typeof wallet !== 'object') continue;
      var known = false;
      for (var j = 0; j < entries.length; j++) {
        if (entries[j].wallet === wallet) known = true;
      }
      if (known) continue;
      var entry = { id: 'w' + nextId++, wallet: wallet, off: null };
      watch(entry);
      entries.push(entry);
      added.push(entry);
    }
    for (var k = 0; k < added.length; k++) emit('register', added[k].id);
    var done = false;
    return function unregister() {
      if (done) return;
      done = true;
      for (var m = 0; m < added.length; m++) {
        var index = entries.indexOf(added[m]);
        if (index < 0) continue;
        entries.splice(index, 1);
        if (added[m].off) safe(added[m].off);
        emit('unregister', added[m].id);
      }
    };
  }

  function safe(fn) {
    try {
      return fn();
    } catch (e) {
      return undefined;
    }
  }

  function strings(value) {
    if (!value || typeof value.length !== 'number') return [];
    var out = [];
    for (var i = 0; i < value.length; i++) out.push(String(value[i]));
    return out;
  }

  function base64(bytes) {
    if (!bytes || typeof bytes.length !== 'number') return '';
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i] & 0xff);
    return btoa(binary);
  }

  function describeAccount(account) {
    return {
      address: String(safe(function () { return account.address; }) || ''),
      publicKey: base64(safe(function () { return account.publicKey; })),
      chains: strings(safe(function () { return account.chains; })),
      features: strings(safe(function () { return account.features; })),
      label: safe(function () { return account.label == null ? null : String(account.label); }) || null,
      icon: safe(function () { return account.icon == null ? null : String(account.icon); }) || null,
    };
  }

  function accountsOf(wallet) {
    var accounts = safe(function () { return wallet.accounts; });
    return accounts && typeof accounts.length === 'number' ? accounts : [];
  }

  function describe(entry) {
    var wallet = entry.wallet;
    var features = safe(function () { return Object.keys(wallet.features || {}); }) || [];
    var accounts = accountsOf(wallet);
    var described = [];
    for (var i = 0; i < accounts.length; i++) described.push(describeAccount(accounts[i]));
    return {
      id: entry.id,
      name: String(safe(function () { return wallet.name; }) || 'Wallet'),
      icon: String(safe(function () { return wallet.icon; }) || ''),
      version: String(safe(function () { return wallet.version; }) || ''),
      chains: strings(safe(function () { return wallet.chains; })),
      features: strings(features),
      accounts: described,
    };
  }

  function errorInfo(e, fallbackCode) {
    if (e == null) return { name: 'Error', message: 'Unknown error', code: fallbackCode || null };
    var code = safe(function () { return e.code; });
    return {
      name: String(safe(function () { return e.name; }) || 'Error'),
      message: String(safe(function () { return e.message; }) || e),
      code: code == null ? fallbackCode || null : String(code),
    };
  }

  function ok(value) {
    return { ok: true, value: value };
  }

  function fail(e, code) {
    return { ok: false, error: errorInfo(e, code) };
  }

  function feature(entry, name) {
    return safe(function () { return entry.wallet.features[name]; }) || null;
  }

  function missingWallet() {
    return fail({ name: 'WalletNotFound', message: 'That wallet is no longer available.' }, 'WALLET_NOT_FOUND');
  }

  async function connect(id, silent) {
    var entry = find(id);
    if (!entry) return missingWallet();
    var f = feature(entry, 'standard:connect');
    if (!f || typeof f.connect !== 'function') {
      return fail({ name: 'Unsupported', message: 'This wallet cannot connect.' }, 'UNSUPPORTED');
    }
    try {
      var output = await f.connect(silent ? { silent: true } : undefined);
      var accounts = output && output.accounts ? output.accounts : accountsOf(entry.wallet);
      var described = [];
      for (var i = 0; i < accounts.length; i++) described.push(describeAccount(accounts[i]));
      return ok(described);
    } catch (e) {
      return fail(e);
    }
  }

  async function disconnect(id) {
    var entry = find(id);
    if (!entry) return ok(null);
    var f = feature(entry, 'standard:disconnect');
    if (!f || typeof f.disconnect !== 'function') return ok(null);
    try {
      await f.disconnect();
      return ok(null);
    } catch (e) {
      return fail(e);
    }
  }

  function accountFor(entry, address) {
    var accounts = accountsOf(entry.wallet);
    for (var i = 0; i < accounts.length; i++) {
      if (safe(function () { return accounts[i].address; }) === address) return accounts[i];
    }
    return null;
  }

  function missingAccount() {
    return fail({ name: 'AccountNotFound', message: 'That account is not connected.' }, 'ACCOUNT_NOT_FOUND');
  }

  async function signPersonalMessage(id, address, message, chain) {
    var entry = find(id);
    if (!entry) return missingWallet();
    var f = feature(entry, 'sui:signPersonalMessage');
    if (!f || typeof f.signPersonalMessage !== 'function') {
      return fail({ name: 'Unsupported', message: 'This wallet cannot sign messages.' }, 'UNSUPPORTED');
    }
    var account = accountFor(entry, address);
    if (!account) return missingAccount();
    try {
      var input = { message: message, account: account };
      if (chain) input.chain = chain;
      var output = await f.signPersonalMessage(input);
      return ok({ bytes: String(output.bytes), signature: String(output.signature) });
    } catch (e) {
      return fail(e);
    }
  }

  // `transaction` is a serialized transaction (the JSON @mysten/sui's
  // Transaction.toJSON() produces), handed over the way dApp Kit does.
  async function signAndExecuteTransaction(id, address, transaction, chain) {
    var entry = find(id);
    if (!entry) return missingWallet();
    var f = feature(entry, 'sui:signAndExecuteTransaction');
    if (!f || typeof f.signAndExecuteTransaction !== 'function') {
      return fail({ name: 'Unsupported', message: 'This wallet cannot approve transactions.' }, 'UNSUPPORTED');
    }
    var account = accountFor(entry, address);
    if (!account) return missingAccount();
    try {
      var output = await f.signAndExecuteTransaction({
        transaction: { toJSON: function () { return Promise.resolve(transaction); } },
        account: account,
        chain: chain,
      });
      if (!output || typeof output.digest !== 'string') {
        return fail({ name: 'InvalidResponse', message: 'Wallet returned no transaction digest.' });
      }
      return ok({
        digest: output.digest,
        effects: output.effects == null ? '' : String(output.effects),
        bytes: output.bytes == null ? '' : String(output.bytes),
        signature: output.signature == null ? '' : String(output.signature),
      });
    } catch (e) {
      return fail(e);
    }
  }

  async function signTransaction(id, address, transaction, chain) {
    var entry = find(id);
    if (!entry) return missingWallet();
    var f = feature(entry, 'sui:signTransaction');
    if (!f || typeof f.signTransaction !== 'function') {
      return fail({ name: 'Unsupported', message: 'This wallet cannot sign transactions without submitting them.' }, 'UNSUPPORTED');
    }
    var account = accountFor(entry, address);
    if (!account) return missingAccount();
    try {
      var output = await f.signTransaction({
        transaction: { toJSON: function () { return Promise.resolve(transaction); } },
        account: account,
        chain: chain,
      });
      if (!output || typeof output.bytes !== 'string' || typeof output.signature !== 'string') {
        return fail({ name: 'InvalidResponse', message: 'Wallet returned no signed transaction.' });
      }
      return ok({ bytes: output.bytes, signature: output.signature });
    } catch (e) {
      return fail(e);
    }
  }

  function withTransactionLock(name, callback) {
    if (!w.navigator || !w.navigator.locks) {
      return Promise.resolve(fail({ name: 'Unsupported', message: 'This browser cannot safely coordinate payments between tabs.' }, 'UNSUPPORTED'));
    }
    return w.navigator.locks.request(name, { mode: 'exclusive', ifAvailable: true }, function (lock) {
      if (!lock) return fail({ name: 'Busy', message: 'Another tab is handling a transaction for this account.' }, 'TRANSACTION_BUSY');
      return Promise.resolve().then(callback).then(function () { return ok(null); });
    });
  }

  function subscribe(listener) {
    listeners.push(listener);
    return function () {
      var index = listeners.indexOf(listener);
      if (index >= 0) listeners.splice(index, 1);
    };
  }

  function list() {
    var out = [];
    for (var i = 0; i < entries.length; i++) out.push(describe(entries[i]));
    return out;
  }

  w.__suiWalletWeb = Object.freeze({
    version: 3,
    list: list,
    subscribe: subscribe,
    connect: connect,
    disconnect: disconnect,
    signPersonalMessage: signPersonalMessage,
    signAndExecuteTransaction: signAndExecuteTransaction,
    signTransaction: signTransaction,
    withTransactionLock: withTransactionLock,
  });

  var api = Object.freeze({ register: register });
  try {
    w.addEventListener('wallet-standard:register-wallet', function (event) {
      var callback = event && event.detail;
      if (typeof callback !== 'function') return;
      try {
        callback(api);
      } catch (e) {
        console.error('[sui_wallet_web] wallet registration failed', e);
      }
    });
  } catch (e) {
    console.error('[sui_wallet_web] could not listen for wallets', e);
  }
  try {
    w.dispatchEvent(
      new CustomEvent('wallet-standard:app-ready', {
        detail: api,
        bubbles: false,
        cancelable: false,
        composed: false,
      }),
    );
  } catch (e) {
    console.error('[sui_wallet_web] could not announce the app', e);
  }
})();
