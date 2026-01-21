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
          Future<NavigationActionPolicy> Function(Uri? url) cb) =>
      onShouldOverrideUrlLoadingCallback = cb;

  @override
  void onExit() {
    if (onExitCallback != null) {
      onExitCallback!();
    }
  }

  @override
  Future<NavigationActionPolicy> shouldOverrideUrlLoading(
      NavigationAction navigationAction) async {
    if (onShouldOverrideUrlLoadingCallback != null) {
      return onShouldOverrideUrlLoadingCallback!(navigationAction.request.url);
    }

    return NavigationActionPolicy.ALLOW;
  }
}

// -----------------------------------------------------------------------------

class FullScreenAuthPage extends StatefulWidget {
  const FullScreenAuthPage({
    super.key,
    required this.params,
  });

  final CasdoorSdkParams params;

  @override
  State<FullScreenAuthPage> createState() => _FullScreenAuthPageState();
}

class _FullScreenAuthPageState extends State<FullScreenAuthPage> {
  double progress = 0;
  bool _isLoading = true;
  Timer? _minimumDisplayTimer;
  bool _webViewReady = false;
  InAppWebViewController? _webViewController;
  bool _isDisposed = false; // Disposed kontrolü

  static const Color primaryColor = Color(0xFF00897C);
  static const Color secondaryColor = Color(0xFFEC6608);

  @override
  void initState() {
    super.initState();
    // Minimum 2 saniye overlay göster
    _minimumDisplayTimer = Timer(const Duration(milliseconds: 2000), () {
      if (_webViewReady && mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _minimumDisplayTimer?.cancel();
    _webViewController = null;
    super.dispose();
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
      initialUrlRequest:
          URLRequest(url: WebUri.uri(Uri.parse(widget.params.url))),
      initialSettings: InAppWebViewSettings(
        userAgent: CASDOOR_USER_AGENT,
        useShouldOverrideUrlLoading: true,
        useOnLoadResource: true,
        // Cache ve session yönetimi
        cacheEnabled: false, // Cache'i devre dışı bırak
        clearCache: true, // Her açılışta cache temizle
        clearSessionCache: true, // Session cache temizle
        incognito: true, // Incognito mode - hiçbir şey saklanmaz
      ),
      onWebViewCreated: (controller) {
        _webViewController = controller;
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url!;

        if (uri.scheme == widget.params.callbackUrlScheme) {
          // Callback URL yakalandı
          if (!_isDisposed && mounted) {
            // Loading'i durdur ve sayfayı kapat
            try {
              await controller.stopLoading();
            } catch (e) {
              print('⚠️ Stop loading error: $e');
            }

            // Navigator'ı kapat ve callback URL'i döndür
            Navigator.pop(ctx, uri.toString());
          }
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
      onProgressChanged: (controller, progress) {
        setState(() {
          this.progress = progress / 100;
        });
      },
      onLoadStop: (controller, url) async {
        // Sayfa yüklendi, ek 500ms bekle (render için)
        await Future.delayed(const Duration(milliseconds: 500));

        _webViewReady = true;

        // Timer bittiyse overlay'i kapat
        if (!(_minimumDisplayTimer?.isActive ?? false) && mounted) {
          setState(() {
            _isLoading = false;
          });
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
        backgroundColor: primaryColor,
        body: Stack(
          children: [
            // WebView (arka planda)
            SafeArea(
              top: false,
              bottom: false,
              left: false,
              right: false,
              child: webViewWidget(ctx),
            ),

            // Loading Overlay
            if (_isLoading)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: Container(
                    color: primaryColor.withOpacity(0.95),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 70,
                            height: 70,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.15),
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(14),
                            child: const CircularProgressIndicator(
                              strokeWidth: 4,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                secondaryColor,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'Giriş ekranı yükleniyor...',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Lütfen bekleyin',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: 200,
                            child: LinearProgressIndicator(
                              value: progress,
                              backgroundColor: Colors.white.withOpacity(0.2),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                secondaryColor,
                              ),
                              minHeight: 3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
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
        backgroundColor: primaryColor,
        child: Stack(
          children: [
            SafeArea(
              top: false,
              bottom: false,
              left: false,
              right: false,
              child: webViewWidget(ctx),
            ),
            if (_isLoading)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: Container(
                    color: primaryColor.withOpacity(0.95),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 70,
                            height: 70,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.15),
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(14),
                            child: const CupertinoActivityIndicator(
                              radius: 20,
                              color: secondaryColor,
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'Giriş ekranı yükleniyor...',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Lütfen bekleyin',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
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
    // Route'u push et
    final result = await Navigator.push(
      params.buildContext!,
      MaterialPageRoute(
        builder: (BuildContext ctx) => FullScreenAuthPage(params: params),
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

  Future<String> _inAppBrowserAuth(CasdoorSdkParams params) async {
    final Completer<String> isFinished = Completer<String>();
    final InAppAuthBrowser browser = InAppAuthBrowser();

    browser.setOnExitCallback(() {
      if (!isFinished.isCompleted) {
        isFinished.completeError(CasdoorAuthCancelledException);
      }
    });

    browser.setOnShouldOverrideUrlLoadingCallback((returnUrl) async {
      if (returnUrl != null) {
        if (returnUrl.scheme == params.callbackUrlScheme) {
          isFinished.complete(returnUrl.toString());
          browser.close();
          return NavigationActionPolicy.CANCEL;
        }
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
          isFinished.complete(returnUrl.rawValue);
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
    final CasdoorSdkParams newParams =
        (willClearCache == true) ? params.copyWith(clearCache: true) : params;

    if (newParams.clearCache == true) {
      await clearCache();
      willClearCache = false;
    }

    if (([TargetPlatform.android, TargetPlatform.iOS]
            .contains(defaultTargetPlatform)) &&
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
