/// The `window.zunia` provider the in-app browser injects into a page, with
/// the same surface as extension 0.1.5's (zunia-extension/entrypoints/injected.ts)
/// and `mode: "mobile"`.
///
/// Keys never enter the WebView. Every call posts to the app through
/// `flutter_inappwebview.callHandler('zunia', …)` with a per-browser token: the
/// script installs itself in the top document only, so a cross-origin frame
/// inside a connected site neither sees the provider nor knows the token the
/// app requires, and cannot make calls in that site's name. Pages that are not
/// https (or http on this device) get no provider at all.
library;

import 'dart:convert';
import 'dart:math';

import 'package:zunia_mobile/config/app_identity.dart';

/// The handler name the script calls.
const kProviderHandlerName = 'zunia';

/// A fresh secret for one browser: 32 random bytes, hex.
String newProviderToken() {
  final random = Random.secure();
  return List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// What `window.zunia` says about itself. `version` is the provider API and
/// stays "0.1.0"; `appVersion` is this release; `features` names what this
/// build signs, in the extension's vocabulary.
Map<String, Object?> providerIdentity() => {
      'version': providerApiVersion,
      'isZunia': true,
      'mode': providerMode,
      'appVersion': appVersion,
      'features': providerFeatures,
    };

/// The document-start script for one browser. [token] is checked on every
/// call; [exposeKeplrAlias] is the setting when the page loads (the app also
/// pushes later changes through `__zuniaNative.settings`).
String buildProviderScript({required String token, required bool exposeKeplrAlias}) {
  return _template
      .replaceAll('__ZUNIA_TOKEN__', jsonEncode(token))
      .replaceAll('__ZUNIA_IDENTITY__', jsonEncode(providerIdentity()))
      .replaceAll('__ZUNIA_KEPLR__', exposeKeplrAlias ? 'true' : 'false');
}

/// JavaScript that delivers a wallet event to the page's provider.
String providerEventScript(String event, Object? data) =>
    'window.__zuniaNative && window.__zuniaNative.event(${jsonEncode(event)}, ${jsonEncode(data)});';

/// JavaScript that applies the signing settings to the page's provider.
String providerSettingsScript({required bool exposeKeplrAlias}) =>
    'window.__zuniaNative && window.__zuniaNative.settings(${jsonEncode({'exposeKeplrAlias': exposeKeplrAlias})});';

const _template = r'''
(function () {
  'use strict';
  try {
    if (window.top !== window.self) return;
  } catch (_) {
    return;
  }
  var loc = window.location;
  var host = String(loc.hostname || '').toLowerCase();
  var local = host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1';
  if (!(loc.protocol === 'https:' || (loc.protocol === 'http:' && local))) return;
  if (window.__zuniaProviderInstalled) return;
  Object.defineProperty(window, '__zuniaProviderInstalled', { value: true });

  var TOKEN = __ZUNIA_TOKEN__;
  var IDENTITY = __ZUNIA_IDENTITY__;
  var keplrAliasOn = false;
  var listeners = {};
  var callHandler = null;

  /** What a failed call rejects with: the wallet's message and a stable code. */
  class ZuniaProviderError extends Error {
    constructor(message, code) {
      super(message);
      this.name = 'ZuniaProviderError';
      this.code = code || 'INTERNAL';
    }
  }

  var ready = new Promise(function (resolve, reject) {
    function check() {
      var bridge = window.flutter_inappwebview;
      if (bridge && typeof bridge.callHandler === 'function') {
        callHandler = bridge.callHandler.bind(bridge);
        resolve();
        return true;
      }
      return false;
    }
    if (check()) return;
    window.addEventListener('flutterInAppWebViewPlatformReady', check, { once: true });
    var tries = 0;
    var timer = setInterval(function () {
      if (check()) {
        clearInterval(timer);
      } else if (++tries > 100) {
        clearInterval(timer);
        reject(new ZuniaProviderError('Zunia provider handshake timed out', 'INTERNAL'));
      }
    }, 50);
  });
  ready.catch(function () {});

  function request(method, args) {
    return ready
      .then(function () {
        return callHandler('zunia', {
          token: TOKEN,
          origin: window.location.origin,
          method: method,
          args: args || []
        });
      })
      .then(
        function (msg) {
          if (!msg || typeof msg !== 'object') {
            throw new ZuniaProviderError('Empty response from Zunia', 'INTERNAL');
          }
          if (msg.error) throw new ZuniaProviderError(String(msg.error), msg.code);
          return msg.result;
        },
        function (err) {
          if (err instanceof ZuniaProviderError) throw err;
          throw new ZuniaProviderError(String((err && err.message) || err), 'INTERNAL');
        }
      );
  }

  function emit(event, data) {
    var set = listeners[event];
    if (!set) return;
    set.forEach(function (handler) {
      try {
        handler(data);
      } catch (err) {
        console.error('[zunia] event handler error', err);
      }
    });
  }

  function on(event, handler) {
    if (typeof handler !== 'function') return;
    if (!listeners[event]) listeners[event] = new Set();
    listeners[event].add(handler);
  }

  function off(event, handler) {
    if (listeners[event]) listeners[event].delete(handler);
  }

  /** dApps written for Keplr listen on window, not on the provider object. */
  function dispatchWindowEvent(name) {
    window.dispatchEvent(new Event('zunia_' + name));
    if (keplrAliasOn) window.dispatchEvent(new Event('keplr_' + name));
  }

  /** Typed arrays do not survive the bridge as arrays; plain arrays do. */
  function wireBytes(value) {
    if (value instanceof Uint8Array) return Array.prototype.slice.call(value);
    if (value instanceof ArrayBuffer) return Array.prototype.slice.call(new Uint8Array(value));
    return value;
  }

  /** Plain arrays and a decimal string; the app re-encodes the exact SignDoc bytes. */
  function wireDirectSignDoc(signDoc) {
    if (!signDoc || typeof signDoc !== 'object') return signDoc;
    var accountNumber = signDoc.accountNumber;
    return {
      bodyBytes: wireBytes(signDoc.bodyBytes),
      authInfoBytes: wireBytes(signDoc.authInfoBytes),
      chainId: signDoc.chainId,
      accountNumber:
        accountNumber === undefined || accountNumber === null
          ? '0'
          : typeof accountNumber === 'object'
            ? String(accountNumber.toString())
            : String(accountNumber)
    };
  }

  /** Keplr's sign options: the call's own, then defaultOptions.sign. */
  function signOptionsFor(explicit) {
    var defaults = provider.defaultOptions && provider.defaultOptions.sign;
    var given = explicit && typeof explicit === 'object' ? explicit : {};
    var value = given.preferNoSetFee;
    if (value === undefined || value === null) value = defaults ? defaults.preferNoSetFee : undefined;
    return { preferNoSetFee: value === true };
  }

  async function signDirect(chainId, signer, signDoc, signOptions) {
    var response = await request('signDirect', [
      chainId,
      signer,
      wireDirectSignDoc(signDoc),
      signOptionsFor(signOptions)
    ]);
    // The app signed exactly the bytes of this document, so the caller gets
    // its own object back. When the user picked another fee tier only the
    // auth info changed, and the caller needs it to broadcast what was signed.
    var authInfoBytes = response && response.signed && response.signed.authInfoBytes;
    if (response && response.feeChanged === true && Array.isArray(authInfoBytes) && signDoc && typeof signDoc === 'object') {
      return {
        signed: Object.assign({}, signDoc, { authInfoBytes: Uint8Array.from(authInfoBytes) }),
        signature: response.signature
      };
    }
    return { signed: signDoc, signature: response.signature };
  }

  function getOfflineSigner(chainId) {
    return {
      getAccounts: async function () {
        var accounts = (await request('getAccounts', [chainId])) || [];
        return accounts.map(function (a) {
          return { address: a.address, algo: a.algo, pubkey: Uint8Array.from(a.pubkey || []) };
        });
      },
      signAmino: function (signerAddress, signDoc) {
        return request('signAmino', [chainId, signerAddress, signDoc, signOptionsFor(undefined)]);
      },
      signDirect: function (signerAddress, signDoc) {
        return signDirect(chainId, signerAddress, signDoc);
      }
    };
  }

  /** No signDirect: CosmJS picks direct signing whenever a signer offers it. */
  function getOfflineSignerOnlyAmino(chainId) {
    var signer = getOfflineSigner(chainId);
    return { getAccounts: signer.getAccounts, signAmino: signer.signAmino };
  }

  var provider = {
    version: IDENTITY.version,
    isZunia: true,
    mode: IDENTITY.mode,
    appVersion: IDENTITY.appVersion,
    features: Object.freeze(IDENTITY.features.slice()),
    defaultOptions: {},
    enable: async function (chainIds) {
      await request('enable', [chainIds]);
    },
    disable: async function (chainIds) {
      await request('disable', chainIds === undefined ? [] : [chainIds]);
    },
    getConnectedChains: async function () {
      return await request('getConnectedChains', []);
    },
    isLocked: async function () {
      return await request('isLocked', []);
    },
    getKey: async function (chainId) {
      var key = await request('getKey', [chainId]);
      return Object.assign({}, key, { pubKey: Uint8Array.from(key.pubKey || []) });
    },
    getAccounts: function (chainId) {
      return request('getAccounts', [chainId]);
    },
    getOfflineSigner: getOfflineSigner,
    getOfflineSignerOnlyAmino: getOfflineSignerOnlyAmino,
    getOfflineSignerAuto: async function (chainId) {
      return getOfflineSigner(chainId);
    },
    signAmino: function (chainId, signer, signDoc, signOptions) {
      return request('signAmino', [chainId, signer, signDoc, signOptionsFor(signOptions)]);
    },
    signDirect: function (chainId, signer, signDoc, signOptions) {
      return signDirect(chainId, signer, signDoc, signOptions);
    },
    signArbitrary: function (chainId, signer, data) {
      return request('signArbitrary', [chainId, signer, wireBytes(data)]);
    },
    verifyArbitrary: async function () {
      var args = Array.prototype.slice.call(arguments).map(function (arg, i) {
        return i === 2 ? wireBytes(arg) : arg;
      });
      return await request('verifyArbitrary', args);
    },
    sendTx: function (chainId, tx, mode) {
      return request('sendTx', [chainId, wireBytes(tx), mode]);
    },
    experimentalSuggestChain: async function (chainInfo) {
      await request('experimentalSuggestChain', [chainInfo]);
    },
    getChainInfosWithoutEndpoints: function () {
      return request('getChainInfosWithoutEndpoints', []);
    },
    getChainInfos: function () {
      return request('getChainInfos', []);
    },
    on: on,
    off: off
  };

  function applyKeplrAlias(enabled) {
    keplrAliasOn = enabled;
    if (enabled) {
      window.keplr = provider;
    } else if (window.keplr === provider) {
      try {
        delete window.keplr;
      } catch (_) {
        window.keplr = undefined;
      }
    }
  }

  function onWalletEvent(event, data) {
    if (event === 'accountsChanged') {
      emit('accountsChanged', data);
      emit('keplr_keystorechange', data);
      emit('accountChanged', data);
      dispatchWindowEvent('keystorechange');
    } else if (event === 'disconnect') {
      emit('disconnect', data);
      // Losing some chains is a key change for a Keplr-style dApp, which then
      // finds out which getKey calls stopped working.
      var partial = !!data && Array.isArray(data.chainIds);
      dispatchWindowEvent(partial ? 'keystorechange' : 'disconnect');
    } else if (event === 'locked') {
      emit('locked', data);
      window.dispatchEvent(new Event('zunia_locked'));
    } else if (event === 'chainChanged') {
      emit('chainChanged', data);
      window.dispatchEvent(new CustomEvent('zunia_chainchanged', { detail: data }));
    }
  }

  Object.defineProperty(window, '__zuniaNative', {
    value: Object.freeze({
      event: onWalletEvent,
      settings: function (settings) {
        applyKeplrAlias(!!(settings && settings.exposeKeplrAlias));
      }
    })
  });

  window.zunia = provider;
  // Keplr alias is off by default; the user turns it on in Zunia's settings.
  applyKeplrAlias(__ZUNIA_KEPLR__);

  window.dispatchEvent(new Event('zunia#initialized'));
})();
''';
