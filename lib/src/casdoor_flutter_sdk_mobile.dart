// Copyright 2022 The casbin Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui';

import 'package:casdoor_flutter_sdk/casdoor_flutter_sdk.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class InAppAuthBrowser extends InAppBrowser {
  InAppAuthBrowser({
    int? windowId,
    UnmodifiableListView<UserScript>? initialUserScripts,
  }) : super(windowId: windowId, initialUserScripts: initialUserScripts);

  Function? onExitCallback;
  Future<NavigationActionPolicy> Function(Uri? url)?
  onShouldOverrideUrlLoadingCallback;

  void setOnExitCallback(Function cb) => (onExitCallback = cb);

  void setOnShouldOverrideUrlLoadingCallback(
    Future<NavigationActionPolicy> Function(Uri? url) cb,
  ) => onShouldOverrideUrlLoadingCallback = cb;

  @override
  void onExit() {
    if (onExitCallback != null) {
      onExitCallback!();
    }
  }

  @override
  Future<NavigationActionPolicy> shouldOverrideUrlLoading(
    NavigationAction navigationAction,
  ) async {
    if (onShouldOverrideUrlLoadingCallback != null) {
      return onShouldOverrideUrlLoadingCallback!(navigationAction.request.url);
    }

    return NavigationActionPolicy.ALLOW;
  }
}

// -----------------------------------------------------------------------------

class FullScreenAuthPage extends StatefulWidget {
  const FullScreenAuthPage({super.key, required this.params});

  final CasdoorSdkParams params;

  @override
  State<FullScreenAuthPage> createState() => _FullScreenAuthPageState();
}

class _FullScreenAuthPageState extends State<FullScreenAuthPage> {
  double progress = 0;
  InAppWebViewController? _webViewController;
  bool _isDisposed = false;
  String? _currentUrl; // YENİ: Mevcut URL'i takip et
  bool _webViewVisible = false; // WebView görünürlük kontrolü

  static const Color primaryColor = Color(0xFF00897C);
  static const Color secondaryColor = Color(0xFFEC6608);

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _webViewController = null;
    super.dispose();
  }

  // YENİ: URL kontrolü metodu
  bool _checkUrl(String url) {
    if (_currentUrl == url) return false;
    _currentUrl = url;

    debugPrint('📍 URL changed: $url');

    // onUrlChange callback
    widget.params.onUrlChange?.call(url);

    // Callback URL scheme kontrolü (mevcut)
    final uri = Uri.parse(url);
    if (uri.scheme == widget.params.callbackUrlScheme) {
      debugPrint('✅ Callback URL detected: $url');
      return true; // URL eşleşti
    }

    // YENİ: Custom string filtreler - URL'de belirli string varsa kapat
    if (widget.params.urlContainsFilters != null) {
      for (final filter in widget.params.urlContainsFilters!) {
        if (url.contains(filter)) {
          debugPrint('✅ URL filter matched: "$filter" in $url');
          return true; // URL eşleşti
        }
      }
    }

    return false; // URL eşleşmedi
  }

  // YENİ: JavaScript injection ile URL monitoring ve click interception
  Future<void> _injectUrlMonitor(InAppWebViewController controller) async {
    if (!widget.params.monitorUrlChanges) return;

    try {
      // href click filters'ı JavaScript'e hazırla
      final hrefFilters = widget.params.hrefClickFilters ?? [];
      final hrefFiltersJson = jsonEncode(hrefFilters);

      await controller.evaluateJavascript(
        source:
            '''
        (function() {
          if (window._casdoorMonitorInjected) return;
          window._casdoorMonitorInjected = true;
          
          let lastUrl = window.location.href;
          
          // Href click filters
          const hrefClickFilters = $hrefFiltersJson;
          
          function notifyUrlChange() {
            const currentUrl = window.location.href;
            if (currentUrl !== lastUrl) {
              lastUrl = currentUrl;
              // Flutter tarafına mesaj gönder
              if (typeof flutter_inappwebview !== 'undefined' && 
                  typeof flutter_inappwebview.callHandler === 'function') {
                flutter_inappwebview.callHandler('urlChanged', currentUrl);
              }
            }
          }
          
          // YENİ: Link click interceptor
          function setupClickListener() {
            document.addEventListener('click', function(event) {
              // Tıklanan elementi ve parent'larını kontrol et
              let target = event.target;
              let clickedLink = null;
              
              // Parent'lara doğru çık, <a> tag'i bul
              for (let i = 0; i < 5 && target; i++) {
                if (target.tagName === 'A' && target.href) {
                  clickedLink = target;
                  break;
                }
                target = target.parentElement;
              }
              
              if (!clickedLink) return;
              
              const href = clickedLink.href;
              console.log('🔗 Link clicked:', href);
              
              // Href filters'ı kontrol et
              let shouldIntercept = false;
              for (const filter of hrefClickFilters) {
                if (href.includes(filter) || href === filter) {
                  console.log('✅ Href filter matched:', filter, 'in', href);
                  shouldIntercept = true;
                  break;
                }
              }
              
              if (shouldIntercept) {
                event.preventDefault();
                event.stopPropagation();
                
                // Flutter'a bildir
                if (typeof flutter_inappwebview !== 'undefined' && 
                    typeof flutter_inappwebview.callHandler === 'function') {
                  flutter_inappwebview.callHandler('hrefClicked', href);
                }
              }
            }, true); // capture phase'de yakala
            
            console.log('✅ Click listener setup complete. Monitoring hrefs:', hrefClickFilters);
          }
          
          // History API'yi override et
          const originalPushState = history.pushState;
          const originalReplaceState = history.replaceState;
          
          history.pushState = function() {
            originalPushState.apply(history, arguments);
            setTimeout(notifyUrlChange, 100);
          };
          
          history.replaceState = function() {
            originalReplaceState.apply(history, arguments);
            setTimeout(notifyUrlChange, 100);
          };
          
          // Hash değişikliklerini dinle
          window.addEventListener('hashchange', notifyUrlChange);
          
          // Periyodik kontrol (fallback)
          setInterval(notifyUrlChange, ${widget.params.urlCheckIntervalMs});
          
          // DOM hazır olduğunda click listener'ı kur
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', setupClickListener);
          } else {
            setupClickListener();
          }
          
          // İlk URL'i bildir
          notifyUrlChange();
        })();
      ''',
      );
      debugPrint('✅ URL monitor & click interceptor JavaScript injected');
      debugPrint('📍 Monitoring href clicks: $hrefFilters');
    } catch (e) {
      debugPrint('⚠️ JavaScript injection error: $e');
    }
  }

  Future<bool> _onWillPop() async {
    if (_webViewController != null) {
      final canGoBack = await _webViewController!.canGoBack();
      if (canGoBack) {
        await _webViewController!.goBack();
        return false; // Sayfayı kapatma
      }
    }
    return true; // Sayfayı kapat
  }

  Widget webViewWidget(BuildContext ctx) {
    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri.uri(Uri.parse(widget.params.url)),
      ),
      initialSettings: InAppWebViewSettings(
        userAgent: CASDOOR_USER_AGENT,
        useShouldOverrideUrlLoading: true,
        useOnLoadResource: true,
        // Cache ve session yönetimi
        cacheEnabled: false,
        clearCache: true,
        clearSessionCache: true,
        incognito: true,
        javaScriptEnabled: true, // YENİ: JavaScript'i açık tut
      ),
      // YENİ: JavaScript handler ekle
      onWebViewCreated: (controller) {
        _webViewController = controller;

        // JavaScript'ten gelen URL değişikliklerini dinle
        controller.addJavaScriptHandler(
          handlerName: 'urlChanged',
          callback: (args) {
            if (args.isNotEmpty && !_isDisposed && mounted) {
              final url = args[0].toString();
              final shouldClose = _checkUrl(url);

              if (shouldClose) {
                // WebView'ı kapat ve URL'i döndür
                Navigator.pop(ctx, url);
              }
            }
          },
        );

        // YENİ: Href click handler
        controller.addJavaScriptHandler(
          handlerName: 'hrefClicked',
          callback: (args) {
            if (args.isNotEmpty && !_isDisposed && mounted) {
              final clickedHref = args[0].toString();
              debugPrint('🔗 Href clicked (from JS): $clickedHref');

              // JavaScript tarafı zaten filtreledi, direkt kapat
              // onUrlChange callback'i çağır
              widget.params.onUrlChange?.call(clickedHref);

              // WebView'ı kapat ve href'i döndür
              Navigator.pop(ctx, clickedHref);
            }
          },
        );
      },
      // YENİ: URL navigation kontrolü
      onLoadStart: (controller, url) {
        if (url != null && !_isDisposed && mounted) {
          final shouldClose = _checkUrl(url.toString());

          if (shouldClose) {
            // Loading'i durdur ve sayfayı kapat
            controller.stopLoading().catchError((e) {
              debugPrint('⚠️ Stop loading error: $e');
            });
            Navigator.pop(ctx, url.toString());
          }
        }
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url!;
        final url = uri.toString();

        // YENİ: URL kontrolü yap
        final shouldClose = _checkUrl(url);

        if (shouldClose) {
          // Callback URL yakalandı
          if (!_isDisposed && mounted) {
            // Loading'i durdur ve sayfayı kapat
            try {
              await controller.stopLoading();
            } catch (e) {
              debugPrint('⚠️ Stop loading error: $e');
            }

            // Navigator'ı kapat ve callback URL'i döndür
            Navigator.pop(ctx, url);
          }
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
      onProgressChanged: (controller, progress) {
        if (mounted) {
          setState(() {
            this.progress = progress / 100;
          });
        }
      },
      onLoadStop: (controller, url) async {
        // YENİ: Sayfa yüklendikten sonra JavaScript inject et
        if (url != null && !_isDisposed && mounted) {
          _checkUrl(url.toString());
          await _injectUrlMonitor(controller);
        }

        // Sayfa tamamen render olması için ekstra bekleme
        await Future.delayed(const Duration(milliseconds: 800));

        // WebView'ı görünür yap
        if (!_isDisposed && mounted) {
          setState(() {
            _webViewVisible = true;
          });
        }

        // Fade-in tamamlansın diye kısa bekle
        await Future.delayed(const Duration(milliseconds: 300));

        // Sayfa tamamen yüklendi callback'i
        if (!_isDisposed && mounted) {
          widget.params.onPageCompleted?.call();
        }
      },
      // YENİ: History değişikliklerini yakala
      onUpdateVisitedHistory: (controller, url, isReload) {
        if (url != null && !_isDisposed && mounted && !(isReload ?? false)) {
          final shouldClose = _checkUrl(url.toString());

          if (shouldClose) {
            Navigator.pop(context, url.toString());
          }
        }
      },
    );
  }

  Widget materialAuthWidget(BuildContext ctx) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        final shouldPop = await _onWillPop();
        if (shouldPop && ctx.mounted) {
          Navigator.of(ctx).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          top: false,
          bottom: false,
          left: false,
          right: false,
          child: AnimatedOpacity(
            opacity: _webViewVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: webViewWidget(ctx),
          ),
        ),
      ),
    );
  }

  Widget cupertinoAuthWidget(BuildContext ctx) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        final shouldPop = await _onWillPop();
        if (shouldPop && ctx.mounted) {
          Navigator.of(ctx).pop();
        }
      },
      child: CupertinoPageScaffold(
        backgroundColor: Colors.transparent,
        child: SafeArea(
          top: false,
          bottom: false,
          left: false,
          right: false,
          child: AnimatedOpacity(
            opacity: _webViewVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: webViewWidget(ctx),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return (widget.params.isMaterialStyle)
        ? materialAuthWidget(context)
        : cupertinoAuthWidget(context);
  }
}

// -----------------------------------------------------------------------------

class CasdoorFlutterSdkMobile extends CasdoorFlutterSdkPlatform {
  CasdoorFlutterSdkMobile() : super.create();

  WebAuthenticationSession? session;
  bool willClearCache = false;

  static void registerWith() {
    CasdoorFlutterSdkPlatform.instance = CasdoorFlutterSdkMobile();
  }

  @override
  Future<bool> clearCache() async {
    final CookieManager cookieManager = CookieManager.instance();
    cookieManager.deleteAllCookies();
    if (defaultTargetPlatform == TargetPlatform.android) {
      await cookieManager.removeSessionCookies();
    }
    await InAppWebViewController.clearAllCache();
    willClearCache = true;
    return true;
  }

  Future<String> _fullScreenAuth(CasdoorSdkParams params) async {
    // Route'u push et - transparent route ile splash ekranı görünsün
    final result = await Navigator.push(
      params.buildContext!,
      PageRouteBuilder(
        opaque: false, // Transparent route
        barrierColor: Colors.transparent,
        pageBuilder: (BuildContext ctx, _, __) =>
            FullScreenAuthPage(params: params),
        transitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // Fade transition
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );

    // Route kapandıktan sonra ek cleanup
    // Bir sonraki açılışta eski state kalmasın
    await Future.delayed(const Duration(milliseconds: 300));

    if (result is String && result.isNotEmpty) {
      return result;
    }

    throw CasdoorAuthCancelledException;
  }

  // YENİ: InAppBrowser için de URL monitoring ekle
  Future<String> _inAppBrowserAuth(CasdoorSdkParams params) async {
    final Completer<String> isFinished = Completer<String>();
    final InAppAuthBrowser browser = InAppAuthBrowser();

    // YENİ: URL kontrolü için helper fonksiyon
    bool checkUrl(Uri? returnUrl) {
      if (returnUrl == null) return false;

      final url = returnUrl.toString();

      // onUrlChange callback
      params.onUrlChange?.call(url);

      // Callback URL scheme kontrolü
      if (returnUrl.scheme == params.callbackUrlScheme) {
        debugPrint('✅ InAppBrowser: Callback URL detected');
        return true;
      }

      // YENİ: Custom string filtreler
      if (params.urlContainsFilters != null) {
        for (final filter in params.urlContainsFilters!) {
          if (url.contains(filter)) {
            debugPrint('✅ InAppBrowser: URL filter matched: "$filter"');
            return true;
          }
        }
      }

      return false;
    }

    browser.setOnExitCallback(() {
      if (!isFinished.isCompleted) {
        isFinished.completeError(CasdoorAuthCancelledException);
      }
    });

    browser.setOnShouldOverrideUrlLoadingCallback((returnUrl) async {
      // YENİ: Her URL değişikliğinde kontrol et
      final shouldClose = checkUrl(returnUrl);

      if (shouldClose && returnUrl != null) {
        if (!isFinished.isCompleted) {
          isFinished.complete(returnUrl.toString());
          browser.close();
        }
        return NavigationActionPolicy.CANCEL;
      }

      return NavigationActionPolicy.ALLOW;
    });

    await browser.openUrlRequest(
      urlRequest: URLRequest(url: WebUri.uri(Uri.parse(params.url))),
      settings: InAppBrowserClassSettings(
        webViewSettings: InAppWebViewSettings(
          userAgent: CASDOOR_USER_AGENT,
          useOnLoadResource: true,
          useShouldOverrideUrlLoading: true,
          javaScriptEnabled: true, // YENİ: JavaScript aktif
        ),
        browserSettings: InAppBrowserSettings(
          hideUrlBar: true,
          toolbarTopFixedTitle: 'Login',
          hideToolbarBottom: true,
        ),
      ),
    );

    return isFinished.future;
  }

  Future<String> _webAuthSession(CasdoorSdkParams params) async {
    if ((session != null) || (!await WebAuthenticationSession.isAvailable())) {
      throw CasdoorMobileWebAuthSessionNotAvailableException;
    }

    bool hasStarted = false;
    final Completer<String> isFinished = Completer<String>();

    session = await WebAuthenticationSession.create(
      url: WebUri(params.url),
      callbackURLScheme: params.callbackUrlScheme,
      initialSettings: WebAuthenticationSessionSettings(
        prefersEphemeralWebBrowserSession: params.clearCache,
      ),
      onComplete:
          (WebUri? returnUrl, WebAuthenticationSessionError? error) async {
            if (returnUrl != null) {
              // YENİ: URL kontrolü ve callback
              final url = returnUrl.rawValue;
              params.onUrlChange?.call(url);

              isFinished.complete(url);
            }
            await session?.dispose();
            session = null;
            if (!isFinished.isCompleted) {
              isFinished.completeError(CasdoorAuthCancelledException);
            }
          },
    );

    if (await session?.canStart() ?? false) {
      hasStarted = await session?.start() ?? false;
    }
    if (!hasStarted) {
      throw CasdoorMobileWebAuthSessionFailedException;
    }

    return isFinished.future;
  }

  @override
  Future<String> authenticate(CasdoorSdkParams params) async {
    final CasdoorSdkParams newParams = (willClearCache == true)
        ? params.copyWith(clearCache: true)
        : params;

    if (newParams.clearCache == true) {
      await clearCache();
      willClearCache = false;
    }

    if (([
          TargetPlatform.android,
          TargetPlatform.iOS,
        ].contains(defaultTargetPlatform)) &&
        (params.showFullscreen == true)) {
      return _fullScreenAuth(newParams);
    } else if ((defaultTargetPlatform == TargetPlatform.iOS) &&
        (params.showFullscreen != true)) {
      return _webAuthSession(newParams);
    }

    return _inAppBrowserAuth(newParams);
  }

  @override
  Future<String> getPlatformVersion() async {
    return 'mobile';
  }
}
