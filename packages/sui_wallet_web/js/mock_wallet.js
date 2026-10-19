/*! sui_wallet_web mock wallet | TEST USE ONLY | MIT */
// A Sui wallet for automated tests. It registers through the Wallet Standard
// exactly like a browser extension, holds throwaway Ed25519 keys, and
// produces real Sui personal-message signatures (intent + BCS + Blake2b-256,
// signed with WebCrypto Ed25519), so a server verifies them like any wallet.
//
// Never load this file in production.
//
//   window.__suiMockWallet.register({
//     name: 'Mock Wallet',                 // shown in the picker
//     seeds: ['<64 hex chars>', ...],       // accounts; default: one random key
//     connect: 'approve',                   // approve | reject | locked | hang
//     sign: 'approve',                      // approve | reject | locked | hang
//     transaction: 'approve',               // approve | reject | locked | hang
//     execute: async (json, address, chain) => digest, // runs approved transactions
//     delayMs: 0,                           // approval delay
//     remember: true,                       // keep authorisation across reloads
//     chains: ['sui:mainnet', 'sui:testnet', 'sui:devnet', 'sui:localnet'],
//     omitFeatures: [],                     // e.g. ['sui:signPersonalMessage']
//   }) -> handle
//
// Playwright: page.addInitScript({path}) then
// page.addInitScript(() => __suiMockWallet.register({...})), or set
// window.__SUI_MOCK_WALLET_CONFIG__ (object or array) before this file runs.
//
// Transactions: the mock cannot build or execute a transaction itself (that
// needs a Sui client). On approval it hands the serialized transaction to
// `execute`, or to window.__suiMockWalletExecute, which a Playwright test can
// provide with page.exposeFunction and implement with @mysten/sui, as Slush
// does. Either returns the digest (or {digest, effects, bytes, signature}).
(function () {
  'use strict';
  var w = window;
  if (w.__suiMockWallet) return;

  // --- Blake2b-256 (RFC 7693), BigInt arithmetic ------------------------------

  var MASK = (1n << 64n) - 1n;
  var IV = [
    0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
    0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n,
  ];
  var SIGMA = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
  ];

  function rotr(x, n) {
    return ((x >> BigInt(n)) | (x << BigInt(64 - n))) & MASK;
  }

  function mix(v, a, b, c, d, x, y) {
    v[a] = (v[a] + v[b] + x) & MASK;
    v[d] = rotr(v[d] ^ v[a], 32);
    v[c] = (v[c] + v[d]) & MASK;
    v[b] = rotr(v[b] ^ v[c], 24);
    v[a] = (v[a] + v[b] + y) & MASK;
    v[d] = rotr(v[d] ^ v[a], 16);
    v[c] = (v[c] + v[d]) & MASK;
    v[b] = rotr(v[b] ^ v[c], 63);
  }

  function compress(h, block, t, last) {
    var m = [];
    for (var i = 0; i < 16; i++) {
      var word = 0n;
      for (var j = 7; j >= 0; j--) word = (word << 8n) | BigInt(block[i * 8 + j]);
      m.push(word);
    }
    var v = h.concat(IV);
    v[12] ^= t & MASK;
    v[13] ^= (t >> 64n) & MASK;
    if (last) v[14] ^= MASK;
    for (var r = 0; r < 12; r++) {
      var s = SIGMA[r % 10];
      mix(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
      mix(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
      mix(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
      mix(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
      mix(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
      mix(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
      mix(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
      mix(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
    }
    for (var k = 0; k < 8; k++) h[k] ^= v[k] ^ v[k + 8];
  }

  function blake2b256(input) {
    var h = IV.slice();
    h[0] ^= 0x01010000n ^ 32n;
    var blocks = Math.max(1, Math.ceil(input.length / 128));
    var t = 0n;
    for (var b = 0; b < blocks; b++) {
      var chunk = input.subarray(b * 128, Math.min(input.length, (b + 1) * 128));
      var block = new Uint8Array(128);
      block.set(chunk);
      t += BigInt(chunk.length);
      compress(h, block, t, b === blocks - 1);
    }
    var out = new Uint8Array(32);
    for (var i = 0; i < 32; i++) out[i] = Number((h[i >> 3] >> BigInt(8 * (i & 7))) & 0xffn);
    return out;
  }

  // --- Bytes ------------------------------------------------------------------

  function concat(parts) {
    var length = 0;
    parts.forEach(function (p) { length += p.length; });
    var out = new Uint8Array(length);
    var offset = 0;
    parts.forEach(function (p) {
      out.set(p, offset);
      offset += p.length;
    });
    return out;
  }

  function uleb128(n) {
    var out = [];
    do {
      var byte = n & 0x7f;
      n = Math.floor(n / 128);
      if (n !== 0) byte |= 0x80;
      out.push(byte);
    } while (n !== 0);
    return new Uint8Array(out);
  }

  function toBase64(bytes) {
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  function fromBase64Url(text) {
    var b64 = text.replace(/-/g, '+').replace(/_/g, '/');
    while (b64.length % 4) b64 += '=';
    var binary = atob(b64);
    var out = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  }

  function toHex(bytes) {
    var hex = '';
    for (var i = 0; i < bytes.length; i++) hex += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    return hex;
  }

  function fromHex(hex) {
    var h = hex.replace(/^0x/i, '');
    if (!/^[0-9a-fA-F]{64}$/.test(h)) throw new Error('Mock wallet seeds are 32 bytes of hex');
    var out = new Uint8Array(32);
    for (var i = 0; i < 32; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
    return out;
  }

  function randomSeedHex() {
    var seed = new Uint8Array(32);
    crypto.getRandomValues(seed);
    return toHex(seed);
  }

  // --- Keys -------------------------------------------------------------------

  var PKCS8_ED25519 = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];

  async function importSeed(seedHex) {
    if (!w.crypto || !crypto.subtle) throw new Error('The mock wallet needs WebCrypto (a secure context).');
    var pkcs8 = concat([new Uint8Array(PKCS8_ED25519), fromHex(seedHex)]);
    var key = await crypto.subtle.importKey('pkcs8', pkcs8, { name: 'Ed25519' }, true, ['sign']);
    var jwk = await crypto.subtle.exportKey('jwk', key);
    var publicKey = fromBase64Url(jwk.x);
    var address = '0x' + toHex(blake2b256(concat([new Uint8Array([0x00]), publicKey])));
    return { key: key, publicKey: publicKey, address: address };
  }

  var DEFAULT_ICON =
    'data:image/svg+xml;base64,' +
    btoa(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">' +
        '<rect width="64" height="64" rx="16" fill="#3D2EFF"/>' +
        '<path d="M18 44V20h6l8 12 8-12h6v24h-6V31l-8 11-8-11v13z" fill="#fff"/>' +
        '</svg>',
    );

  function error(name, message, code) {
    var e = new Error(message);
    e.name = name;
    e.code = code;
    return e;
  }

  function delay(ms) {
    return new Promise(function (resolve) { setTimeout(resolve, ms); });
  }

  var handles = [];

  function register(options) {
    var o = options || {};
    var name = String(o.name || 'Mock Wallet');
    var storageKey = 'sui-mock-wallet:' + name;
    var chains = (o.chains || ['sui:mainnet', 'sui:testnet', 'sui:devnet', 'sui:localnet']).slice();
    var omit = o.omitFeatures || [];
    var behavior = {
      connect: o.connect || 'approve',
      sign: o.sign || 'approve',
      transaction: o.transaction || 'approve',
    };
    var remember = o.remember !== false;
    var seeds = o.seeds ? o.seeds.slice() : o.seed ? [o.seed] : [randomSeedHex()];
    var state = { authorized: false, active: 0, locked: !!o.locked, accounts: [], keys: [] };
    var calls = [];
    var listeners = [];

    if (remember) {
      try {
        var saved = JSON.parse(w.localStorage.getItem(storageKey) || 'null');
        if (saved && saved.authorized) {
          state.authorized = true;
          state.active = saved.active | 0;
        }
      } catch (e) {
        // Storage can be unavailable; start unauthorised.
      }
    }

    function persist() {
      if (!remember) return;
      try {
        w.localStorage.setItem(storageKey, JSON.stringify({ authorized: state.authorized, active: state.active }));
      } catch (e) {
        // Ignore.
      }
    }

    function makeAccount(k) {
      return Object.freeze({
        address: k.address,
        publicKey: k.publicKey,
        chains: chains.slice(),
        features: ['sui:signPersonalMessage', 'sui:signAndExecuteTransaction'],
        label: name + ' account',
        icon: undefined,
      });
    }

    var ready = Promise.all(seeds.map(importSeed)).then(function (keys) {
      state.keys = keys;
      state.accounts = keys.map(makeAccount);
      if (state.active >= state.accounts.length) state.active = 0;
    });

    function exposed() {
      if (!state.authorized || state.locked || !state.accounts.length) return [];
      return [state.accounts[state.active]];
    }

    function emitChange(properties) {
      listeners.slice().forEach(function (listener) {
        try {
          listener(properties);
        } catch (e) {
          console.error('[mock wallet] listener failed', e);
        }
      });
    }

    async function behave(mode) {
      if (mode === 'reject') throw error('UserRejectedRequestError', 'The user rejected the request.', 4001);
      if (mode === 'locked') throw error('WalletLockedError', 'The wallet is locked. Unlock it and try again.', 'WALLET_LOCKED');
      if (mode === 'hang') return new Promise(function () {});
      if (o.delayMs) await delay(o.delayMs);
    }

    async function connect(input) {
      var silent = !!(input && input.silent);
      calls.push({ method: 'connect', silent: silent });
      await ready;
      if (silent) return { accounts: exposed() };
      if (state.locked) throw error('WalletLockedError', 'The wallet is locked. Unlock it and try again.', 'WALLET_LOCKED');
      await behave(behavior.connect);
      state.authorized = true;
      persist();
      var accounts = exposed();
      Promise.resolve().then(function () { emitChange({ accounts: accounts }); });
      return { accounts: accounts };
    }

    async function disconnect() {
      calls.push({ method: 'disconnect' });
      state.authorized = false;
      persist();
    }

    function on(event, listener) {
      if (event !== 'change') return function () {};
      listeners.push(listener);
      return function () {
        var index = listeners.indexOf(listener);
        if (index >= 0) listeners.splice(index, 1);
      };
    }

    async function signPersonalMessage(input) {
      var account = input && input.account;
      calls.push({
        method: 'signPersonalMessage',
        address: account && account.address,
        chain: input && input.chain,
        message: input && input.message ? toBase64(new Uint8Array(input.message)) : null,
      });
      await ready;
      if (state.locked) throw error('WalletLockedError', 'The wallet is locked. Unlock it and try again.', 'WALLET_LOCKED');
      var active = exposed()[0];
      if (!active || !account || account.address !== active.address) {
        throw error('AccountNotAuthorizedError', 'This account is not connected to the site.', 4100);
      }
      if (input.chain && chains.indexOf(input.chain) < 0) {
        throw error('UnsupportedChainError', 'This wallet does not support ' + input.chain + '.', 4901);
      }
      await behave(behavior.sign);
      var message = new Uint8Array(input.message);
      var digest = blake2b256(concat([new Uint8Array([3, 0, 0]), uleb128(message.length), message]));
      var key = state.keys[state.active];
      var signature = new Uint8Array(await crypto.subtle.sign({ name: 'Ed25519' }, key.key, digest));
      var serialized = concat([new Uint8Array([0x00]), signature, key.publicKey]);
      return { bytes: toBase64(message), signature: toBase64(serialized) };
    }

    async function signAndExecuteTransaction(input) {
      var account = input && input.account;
      var json = input && input.transaction ? await input.transaction.toJSON() : null;
      calls.push({
        method: 'signAndExecuteTransaction',
        address: account && account.address,
        chain: input && input.chain,
        transaction: json,
      });
      await ready;
      if (state.locked) throw error('WalletLockedError', 'The wallet is locked. Unlock it and try again.', 'WALLET_LOCKED');
      var active = exposed()[0];
      if (!active || !account || account.address !== active.address) {
        throw error('AccountNotAuthorizedError', 'This account is not connected to the site.', 4100);
      }
      if (chains.indexOf(input.chain) < 0) {
        throw error('UnsupportedChainError', 'This wallet does not support ' + input.chain + '.', 4901);
      }
      await behave(behavior.transaction);
      var execute = o.execute || w.__suiMockWalletExecute;
      if (typeof execute !== 'function') {
        throw error('Error', 'The mock wallet has no transaction executor.', 'NO_EXECUTOR');
      }
      var result = await execute(json, account.address, input.chain);
      var out = typeof result === 'string' ? { digest: result } : result || {};
      if (!out.digest) throw error('Error', 'The executor returned no digest.', 'NO_DIGEST');
      return {
        digest: String(out.digest),
        effects: out.effects || '',
        bytes: out.bytes || '',
        signature: out.signature || '',
      };
    }

    var features = {
      'standard:connect': { version: '1.0.0', connect: connect },
      'standard:disconnect': { version: '1.0.0', disconnect: disconnect },
      'standard:events': { version: '1.0.0', on: on },
      'sui:signPersonalMessage': { version: '1.1.0', signPersonalMessage: signPersonalMessage },
      'sui:signAndExecuteTransaction': { version: '2.0.0', signAndExecuteTransaction: signAndExecuteTransaction },
    };
    if (typeof (o.transactionSigner || w.__suiMockWalletSignTransaction) === 'function') {
      features['sui:signTransaction'] = { version: '2.0.0', signTransaction: async function (input) {
        await ready;
        var account = input && input.account;
        var active = exposed()[0];
        if (!active || !account || account.address !== active.address || state.locked) {
          throw error('AccountNotAuthorizedError', 'This account is not connected.', 4100);
        }
        if (chains.indexOf(input.chain) < 0) throw error('UnsupportedChainError', 'Unsupported chain.', 4901);
        var json = await input.transaction.toJSON();
        calls.push({ method: 'signTransaction', address: account.address, chain: input.chain, transaction: json });
        await behave(behavior.transaction);
        return (o.transactionSigner || w.__suiMockWalletSignTransaction)(json, account.address, input.chain);
      }};
    }
    omit.forEach(function (f) { delete features[f]; });
    Object.freeze(features);

    var icon = o.icon || DEFAULT_ICON;
    var wallet = Object.freeze({
      get version() { return '1.0.0'; },
      get name() { return name; },
      get icon() { return icon; },
      get chains() { return chains.slice(); },
      get accounts() { return exposed(); },
      get features() { return features; },
    });

    // Register exactly as @wallet-standard/wallet's registerWallet() does.
    var unregisters = [];
    function callback(api) {
      try {
        unregisters.push(api.register(wallet));
      } catch (e) {
        console.error('[mock wallet] registration failed', e);
      }
    }
    function onAppReady(event) {
      if (event && event.detail) callback(event.detail);
    }
    w.dispatchEvent(new CustomEvent('wallet-standard:register-wallet', { detail: callback }));
    w.addEventListener('wallet-standard:app-ready', onAppReady);

    var handle = {
      wallet: wallet,
      name: name,
      ready: null,
      get address() { return state.accounts[state.active] ? state.accounts[state.active].address : null; },
      get addresses() { return state.accounts.map(function (a) { return a.address; }); },
      get publicKey() { return state.keys[state.active] ? toBase64(state.keys[state.active].publicKey) : null; },
      get authorized() { return state.authorized; },
      get locked() { return state.locked; },
      get calls() { return calls.slice(); },
      setBehavior: function (next) {
        if (next && next.connect) behavior.connect = next.connect;
        if (next && next.sign) behavior.sign = next.sign;
        if (next && next.transaction) behavior.transaction = next.transaction;
      },
      switchAccount: async function (index) {
        await ready;
        if (index < 0 || index >= state.accounts.length) throw new Error('No account ' + index);
        state.active = index;
        persist();
        emitChange({ accounts: exposed() });
        return state.accounts[index].address;
      },
      addAccount: async function (seedHex) {
        await ready;
        var k = await importSeed(seedHex || randomSeedHex());
        state.keys.push(k);
        state.accounts.push(makeAccount(k));
        return k.address;
      },
      lock: function () {
        state.locked = true;
        emitChange({ accounts: [] });
      },
      unlock: function () {
        state.locked = false;
        emitChange({ accounts: exposed() });
      },
      revoke: function () {
        state.authorized = false;
        persist();
        emitChange({ accounts: [] });
      },
      forget: function () {
        try { w.localStorage.removeItem(storageKey); } catch (e) { /* ignore */ }
      },
      unregister: function () {
        w.removeEventListener('wallet-standard:app-ready', onAppReady);
        unregisters.forEach(function (fn) {
          try { fn(); } catch (e) { /* ignore */ }
        });
        unregisters = [];
        var index = handles.indexOf(handle);
        if (index >= 0) handles.splice(index, 1);
      },
    };
    handle.ready = ready.then(function () { return handle; });
    handles.push(handle);
    return handle;
  }

  w.__suiMockWallet = Object.freeze({
    version: 1,
    register: register,
    get wallets() { return handles.slice(); },
    blake2b256: blake2b256,
  });

  // Init scripts also run in documents that can't hold a wallet, such as a
  // new tab's first about:blank, which has no WebCrypto; skip those.
  var config = w.__SUI_MOCK_WALLET_CONFIG__;
  if (config && w.isSecureContext) {
    (Array.isArray(config) ? config : [config]).forEach(function (c) { register(c); });
  }
})();
