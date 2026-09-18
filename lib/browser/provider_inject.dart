/// Injected Cosmos wallet provider for the in-app dApp browser.
///
/// Keys never enter the WebView. Every privileged call posts to Flutter via
/// `window.flutter_inappwebview.callHandler('zunia')` and awaits a response.
library;

/// Document-start user script. Exposes `window.zunia` and a Keplr-compatible
/// alias so Osmosis / Astroport / Skip and other Cosmos dApps discover the wallet.
const String kZuniaProviderInjectScript = r'''
(function () {
  if (window.__zuniaProviderInjected) return;
  window.__zuniaProviderInjected = true;

  var pending = {};
  var listeners = {};

  function emit(event, data) {
    var set = listeners[event];
    if (!set) return;
    set.forEach(function (handler) {
      try { handler(data); } catch (e) { console.error('[zunia]', e); }
    });
  }

  window.addEventListener('flutterInAppWebViewPlatformReady', function () {});

  function request(method, args) {
    args = args || [];
    return new Promise(function (resolve, reject) {
      var id = Math.random().toString(36).slice(2) + Date.now().toString(36);
      pending[id] = { resolve: resolve, reject: reject };
      try {
        window.flutter_inappwebview.callHandler('zunia', {
          id: id,
          method: method,
          args: args
        }).then(function (msg) {
          var waiter = pending[id];
          if (!waiter) return;
          delete pending[id];
          if (!msg) {
            waiter.reject(new Error('Empty response from Zunia'));
            return;
          }
          if (msg.error) waiter.reject(new Error(msg.error));
          else waiter.resolve(msg.result);
        }).catch(function (err) {
          delete pending[id];
          reject(err instanceof Error ? err : new Error(String(err)));
        });
      } catch (err) {
        delete pending[id];
        reject(err instanceof Error ? err : new Error(String(err)));
      }
    });
  }

  function on(event, handler) {
    if (!listeners[event]) listeners[event] = new Set();
    listeners[event].add(handler);
  }
  function off(event, handler) {
    if (listeners[event]) listeners[event].delete(handler);
  }

  function bytesToArray(u8) {
    return Array.prototype.slice.call(u8);
  }

  function getOfflineSigner(chainId) {
    return {
      getAccounts: async function () {
        var accounts = await request('getAccounts', [chainId]);
        return (accounts || []).map(function (a) {
          return {
            address: a.address,
            algo: a.algo || 'secp256k1',
            pubkey: Uint8Array.from(a.pubkey || a.pubKey || [])
          };
        });
      },
      signAmino: function (signerAddress, signDoc) {
        return request('signAmino', [chainId, signerAddress, signDoc]);
      },
      signDirect: function (signerAddress, signDoc) {
        return request('signDirect', [chainId, signerAddress, signDoc]);
      }
    };
  }

  var provider = {
    version: '0.1.0',
    mode: 'mobile',
    // Discovery flags used by Osmosis, Skip, and other Cosmos frontends.
    isZunia: true,
    isKeplr: true,
    defaultOptions: {},
    enable: function (chainIds) {
      return request('enable', [chainIds]);
    },
    getKey: async function (chainId) {
      var key = await request('getKey', [chainId]);
      return Object.assign({}, key, {
        pubKey: Uint8Array.from(key.pubKey || [])
      });
    },
    getAccounts: function (chainId) {
      return request('getAccounts', [chainId]);
    },
    getOfflineSigner: getOfflineSigner,
    getOfflineSignerOnlyAmino: getOfflineSigner,
    getOfflineSignerAuto: async function (chainId) {
      return getOfflineSigner(chainId);
    },
    signAmino: function (chainId, signer, signDoc) {
      return request('signAmino', [chainId, signer, signDoc]);
    },
    signDirect: function (chainId, signer, signDoc) {
      return request('signDirect', [chainId, signer, signDoc]);
    },
    signArbitrary: function (chainId, signer, data) {
      return request('signArbitrary', [chainId, signer, data]);
    },
    verifyArbitrary: function () {
      return request('verifyArbitrary', Array.prototype.slice.call(arguments));
    },
    disable: function (chainIds) {
      return request('disable', chainIds === undefined ? [] : [chainIds]);
    },
    experimentalSuggestChain: function (chainInfo) {
      return request('experimentalSuggestChain', [chainInfo]);
    },
    getChainInfosWithoutEndpoints: function () {
      return request('getChainInfosWithoutEndpoints', []);
    },
    getChainInfos: function () {
      return request('getChainInfos', []);
    },
    sendTx: function (chainId, tx, mode) {
      return request('sendTx', [chainId, tx, mode]);
    },
    on: on,
    off: off
  };

  window.zunia = provider;
  // In the dedicated wallet browser, Cosmos dApps expect a Keplr-shaped API.
  window.keplr = provider;
  window.getOfflineSigner = getOfflineSigner;
  window.getOfflineSignerOnlyAmino = getOfflineSigner;

  try {
    window.dispatchEvent(new Event('zunia#initialized'));
    window.dispatchEvent(new Event('keplr#initialized'));
    window.dispatchEvent(new Event('keplr_keystorechange'));
  } catch (_) {}
})();
''';