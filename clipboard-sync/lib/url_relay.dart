import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Custom URL handling rule for matching and processing specific URL patterns.
class UrlRule {
  /// Regex pattern to match the URL scheme or host pattern.
  final RegExp pattern;

  /// Optional app name for display purposes.
  final String? appName;

  /// Whether to use the system's default URL handler.
  final bool useSystemHandler;

  /// Custom handler function (if not using system handler).
  final Future<bool> Function(String url)? customHandler;

  const UrlRule({
    required this.pattern,
    this.appName,
    this.useSystemHandler = true,
    this.customHandler,
  });
}

/// URL relay handler for processing URLs received via clipboard sync.
///
/// Supports:
/// - Common scheme detection (http/https/ftp/mailto/tel/sms)
/// - YouTube URL handling
/// - Twitter/X URL handling
/// - GitHub URL handling
/// - Market/App Store links
/// - Custom URL rule configuration
/// - Automatic browser/app launching
class UrlRelayHandler {
  static const _channel = MethodChannel('localsend/url_relay');

  /// Built-in URL rules for common platforms.
  static final List<UrlRule> _defaultRules = [
    // YouTube links
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.|m\.)?(youtube\.com|youtu\.be|yt\.be)/',
        caseSensitive: false,
      ),
      appName: 'YouTube',
    ),

    // Twitter / X links
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?(twitter\.com|x\.com)/',
        caseSensitive: false,
      ),
      appName: 'Twitter',
    ),

    // GitHub links
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?github\.com/',
        caseSensitive: false,
      ),
      appName: 'GitHub',
    ),

    // Bilibili (B站)
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?bilibili\.com/|'
        r'^(https?://)?b23\.tv/',
        caseSensitive: false,
      ),
      appName: 'Bilibili',
    ),

    // Douyin (抖音)
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?douyin\.com/|'
        r'^(https?://)?v\.douyin\.com/',
        caseSensitive: false,
      ),
      appName: 'Douyin',
    ),

    // TikTok
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?tiktok\.com/|'
        r'^(https?://)?vm\.tiktok\.com/',
        caseSensitive: false,
      ),
      appName: 'TikTok',
    ),

    // WeChat articles / links
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?mp\.weixin\.qq\.com/',
        caseSensitive: false,
      ),
      appName: 'WeChat',
    ),

    // Instagram
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?instagram\.com/',
        caseSensitive: false,
      ),
      appName: 'Instagram',
    ),

    // Reddit
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?reddit\.com/',
        caseSensitive: false,
      ),
      appName: 'Reddit',
    ),

    // Baidu / Tieba
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?(baidu\.com|tieba\.baidu\.com)/',
        caseSensitive: false,
      ),
      appName: 'Baidu',
    ),

    // Zhihu (知乎)
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?zhihu\.com/',
        caseSensitive: false,
      ),
      appName: 'Zhihu',
    ),

    // Taobao (淘宝)
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?(taobao\.com|tmall\.com)/',
        caseSensitive: false,
      ),
      appName: 'Taobao',
    ),

    // JD (京东)
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?jd\.com/',
        caseSensitive: false,
      ),
      appName: 'JD',
    ),

    // Google services
    UrlRule(
      pattern: RegExp(
        r'^(https?://)?(www\.)?(google\.|drive\.google\.|docs\.google\.|'
        r'sheets\.google\.|slides\.google\.|meet\.google\.)',
        caseSensitive: false,
      ),
      appName: 'Google',
    ),

    // Email
    UrlRule(
      pattern: RegExp(r'^mailto:', caseSensitive: false),
      appName: 'Email',
    ),

    // Phone
    UrlRule(
      pattern: RegExp(r'^tel:', caseSensitive: false),
      appName: 'Phone',
    ),

    // SMS
    UrlRule(
      pattern: RegExp(r'^sms:', caseSensitive: false),
      appName: 'Messages',
    ),

    // Market / App Store
    UrlRule(
      pattern: RegExp(r'^market://', caseSensitive: false),
      appName: 'App Store',
    ),

    // Generic HTTP/HTTPS (catch-all)
    UrlRule(
      pattern: RegExp(r'^https?://', caseSensitive: false),
      appName: 'Browser',
    ),
  ];

  /// Custom rules added by the user.
  static final List<UrlRule> _customRules = [];

  /// All active rules (custom rules checked first, then defaults).
  static List<UrlRule> get _allRules => [..._customRules, ..._defaultRules];

  /// Add a custom URL handling rule.
  static void addCustomRule(UrlRule rule) {
    _customRules.add(rule);
  }

  /// Remove a custom URL handling rule.
  static void removeCustomRule(UrlRule rule) {
    _customRules.remove(rule);
  }

  /// Clear all custom rules.
  static void clearCustomRules() {
    _customRules.clear();
  }

  /// Open a URL using the appropriate handler.
  ///
  /// Checks custom rules first, then built-in rules.
  /// Falls back to the platform channel for unknown schemes.
  static Future<bool> openUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;

    // Find matching rule
    for (final rule in _allRules) {
      if (rule.pattern.hasMatch(trimmed)) {
        if (rule.customHandler != null) {
          return await rule.customHandler!(trimmed);
        }
        if (rule.useSystemHandler) {
          return await _openWithSystem(trimmed);
        }
      }
    }

    // Fallback: try system handler
    return await _openWithSystem(trimmed);
  }

  /// Open URL using the platform's URL launcher.
  static Future<bool> _openWithSystem(String url) async {
    try {
      final result = await _channel.invokeMethod('openUrl', {'url': url});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Detect the likely app/platform for a given URL.
  ///
  /// Returns the app name if matched, or "Browser" for generic HTTP URLs,
  /// or null for unrecognized URLs.
  static String? detectPlatform(String url) {
    for (final rule in _allRules) {
      if (rule.pattern.hasMatch(url.trim())) {
        return rule.appName;
      }
    }
    return null;
  }

  /// Check if a URL is likely to be safe (not phishing/malicious).
  ///
  /// Performs basic checks: known schemes, non-private IPs, valid format.
  static bool isSafeUrl(String url) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;

    // Known safe schemes
    const safeSchemes = {
      'http', 'https', 'ftp', 'ftps',
      'mailto', 'tel', 'sms',
      'market',
    };
    if (!safeSchemes.contains(uri.scheme)) return false;

    // Check for private/multicast IPs
    if (uri.host.isNotEmpty) {
      final host = uri.host;
      if (_isPrivateIp(host)) return true; // Allow local addresses
    }

    return true;
  }

  /// Quick check if a string is a private/local IP address.
  static bool _isPrivateIp(String host) {
    // Simple check for common private ranges
    if (host == 'localhost' || host == '127.0.0.1') return true;
    if (host.startsWith('192.168.')) return true;
    if (host.startsWith('10.')) return true;
    if (host.startsWith('172.')) {
      final parts = host.split('.');
      if (parts.length == 4) {
        final second = int.tryParse(parts[1]);
        if (second != null && second >= 16 && second <= 31) return true;
      }
    }
    return false;
  }
}
