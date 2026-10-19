import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A published GitHub release with the APK that fits this phone.
class AppRelease {
  AppRelease({
    required this.version,
    required this.notes,
    required this.url,
    required this.assetName,
    required this.assetUrl,
    required this.size,
    this.sha256,
    this.publishedAt,
  });

  final String version;
  final String notes;
  final String url;
  final String assetName;
  final String assetUrl;
  final int size;
  final String? sha256;
  final DateTime? publishedAt;
}

/// The system download of an update APK (android Updater.kt); it survives the app being closed.
class UpdateDownload {
  UpdateDownload(this.json);
  final Map<String, dynamic> json;

  /// none, pending, running, paused, done or failed.
  String get status => json['status'] as String? ?? 'none';
  int get reason => (json['reason'] as num?)?.toInt() ?? 0;
  int get downloaded => (json['downloaded'] as num?)?.toInt() ?? 0;
  int get total => (json['total'] as num?)?.toInt() ?? -1;
  String? get version => json['version'] as String?;

  bool get active => status == 'pending' || status == 'running' || status == 'paused';
  double? get progress => total > 0 ? (downloaded / total).clamp(0, 1).toDouble() : null;

  /// DownloadManager's PAUSED_* and ERROR_* reasons, in words.
  String? get reasonText => switch ((status, reason)) {
    ('paused', 1) => 'Retrying shortly',
    ('paused', 2) => 'Waiting for a network connection',
    ('paused', 3) => 'Waiting for Wi-Fi',
    ('paused', _) => 'Paused',
    ('failed', 1006) => 'Not enough storage space',
    ('failed', 1008) => 'The download could not be resumed',
    ('failed', 1004 || 1002) => 'The connection was interrupted',
    ('failed', >= 400 && < 600) => 'The server answered HTTP $reason',
    ('failed', _) => 'The download failed',
    _ => null,
  };
}

enum UpdatePhase { idle, checking, upToDate, available, downloading, ready, failed }

/// Checks GitHub releases for a newer APK and drives the download and install. GitHub (full) build only.
class Updater extends ChangeNotifier {
  Updater._();
  static final instance = Updater._();

  /// Set by the release workflow (`--dart-define=UPDATE_REPO=owner/name`), so forks update from themselves.
  static const repo = String.fromEnvironment('UPDATE_REPO', defaultValue: 'seseegy/andropi');
  static const _channel = MethodChannel('andropi/updater');
  static const _autoInterval = Duration(hours: 6);

  bool supported = false;
  bool initialized = false;
  String currentVersion = '';
  List<String> abis = const [];

  AppRelease? latest;
  UpdateDownload download = UpdateDownload(const {});
  UpdatePhase phase = UpdatePhase.idle;
  String? error;

  bool autoCheck = true;
  String? skippedVersion;
  DateTime? lastCheck;

  /// Set when a run of the app finishes the download in the foreground; the UI offers to install right away.
  final readyToInstall = StreamController<void>.broadcast();

  /// True after the user was sent to the "install unknown apps" setting; install resumes when they come back.
  bool awaitingPermission = false;

  Timer? _poll;

  /// Loads the saved state and picks up a download started before the app was closed.
  /// Returns the version just installed, if this launch is the first after an update.
  Future<String?> init() async {
    if (initialized) return null;
    initialized = true;
    if (!Platform.isAndroid || appFlavor == 'play') return null;
    try {
      final info = (await _channel.invokeMapMethod<String, dynamic>('info'))!;
      supported = info['supported'] == true;
      currentVersion = info['version'] as String? ?? '';
      abis = (info['abis'] as List? ?? const []).cast<String>();
      final prefs = (await _channel.invokeMapMethod<String, dynamic>('prefs')) ?? const {};
      autoCheck = prefs['autoCheck'] as bool? ?? true;
      skippedVersion = prefs['skipped'] as String?;
      final last = (prefs['lastCheck'] as num?)?.toInt();
      lastCheck = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    } on PlatformException {
      supported = false;
    }
    if (!supported) return null;

    String? justUpdated;
    await _refreshDownload();
    final v = download.version;
    if (download.status != 'none' && v != null && compareVersions(v, currentVersion) <= 0) {
      // The update was installed (or an older download is lying around): free the space.
      if (v == currentVersion && download.status == 'done') justUpdated = v;
      await _channel.invokeMethod('cancel');
      download = UpdateDownload(const {});
    }
    _syncPhase();
    notifyListeners();
    return justUpdated;
  }

  bool get dueForAutoCheck =>
      supported && autoCheck && (lastCheck == null || DateTime.now().difference(lastCheck!) > _autoInterval);

  /// Whether to bring the update up on its own (not skipped, nothing already under way).
  bool get shouldPrompt => phase == UpdatePhase.available && latest?.version != skippedVersion;

  Future<void> check({bool manual = false}) async {
    if (!supported || phase == UpdatePhase.checking) return;
    phase = UpdatePhase.checking;
    error = null;
    notifyListeners();
    try {
      latest = await _fetchLatest();
      lastCheck = DateTime.now();
      await _setPref('lastCheck', lastCheck!.millisecondsSinceEpoch);
    } catch (e) {
      // A background check that fails stays quiet; a manual one says why.
      if (manual) error = '$e';
    }
    phase = UpdatePhase.idle;
    _syncPhase(keepError: true);
    notifyListeners();
  }

  Future<AppRelease?> _fetchLatest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$repo/releases/latest'));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'AndroPI/$currentVersion');
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404) return null;
      if (res.statusCode == 403 || res.statusCode == 429) {
        throw 'GitHub is limiting requests right now. Try again later.';
      }
      if (res.statusCode != 200) throw 'GitHub answered HTTP ${res.statusCode}';
      final json = jsonDecode(body) as Map<String, dynamic>;
      final assets = (json['assets'] as List? ?? const []).cast<Map>();
      final asset = _pickAsset(assets);
      if (asset == null) return null;
      final digest = asset['digest'] as String?;
      return AppRelease(
        version: (json['tag_name'] as String).replaceFirst(RegExp('^v'), ''),
        notes: (json['body'] as String? ?? '').trim(),
        url: json['html_url'] as String? ?? 'https://github.com/$repo/releases',
        assetName: asset['name'] as String,
        assetUrl: asset['browser_download_url'] as String,
        size: (asset['size'] as num?)?.toInt() ?? 0,
        sha256: digest != null && digest.startsWith('sha256:') ? digest.substring(7) : null,
        publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      );
    } on SocketException {
      throw 'No internet connection';
    } on TimeoutException {
      throw 'GitHub did not answer in time';
    } finally {
      client.close();
    }
  }

  /// The APK built for this phone's preferred ABI, else a universal one.
  Map? _pickAsset(List<Map> assets) {
    final apks = assets.where((a) => (a['name'] as String? ?? '').endsWith('.apk')).toList();
    for (final abi in abis) {
      for (final a in apks) {
        if ((a['name'] as String).contains(abi)) return a;
      }
    }
    for (final a in apks) {
      if ((a['name'] as String).contains('universal')) return a;
    }
    return null;
  }

  Future<void> startDownload() async {
    final release = latest;
    if (release == null) return;
    error = null;
    download = UpdateDownload(
      (await _channel.invokeMapMethod<String, dynamic>('download', {
        'url': release.assetUrl,
        'version': release.version,
        'name': release.assetName,
        'sha256': release.sha256,
      }))!,
    );
    _syncPhase();
    notifyListeners();
  }

  Future<void> cancelDownload() async {
    download = UpdateDownload((await _channel.invokeMapMethod<String, dynamic>('cancel'))!);
    awaitingPermission = false;
    _syncPhase();
    notifyListeners();
  }

  /// Opens the system installer. Returns null when it opened, else what to tell the user.
  Future<String?> install() async {
    final outcome = await _channel.invokeMethod<String>('install') ?? 'error';
    awaitingPermission = outcome == 'permission';
    switch (outcome) {
      case 'started':
      case 'permission':
        return null;
      case 'corrupt':
        await _refreshDownload();
        _syncPhase();
        notifyListeners();
        return 'The download was damaged and has been removed. Please download it again.';
      case 'missing':
        await _refreshDownload();
        _syncPhase();
        notifyListeners();
        return 'The downloaded file is gone. Please download it again.';
      default:
        return outcome.startsWith('error:') ? outcome.substring(6) : 'Could not open the installer';
    }
  }

  /// Called when the app comes back to the foreground.
  Future<void> onResume() async {
    if (!supported) return;
    await _refreshDownload();
    _syncPhase();
    notifyListeners();
    if (awaitingPermission) {
      awaitingPermission = false;
      final info = await _channel.invokeMapMethod<String, dynamic>('info');
      if (info?['canInstall'] == true && phase == UpdatePhase.ready) await install();
    }
  }

  Future<void> skip(String version) async {
    skippedVersion = version;
    await _setPref('skipped', version);
    notifyListeners();
  }

  Future<void> setAutoCheck(bool on) async {
    autoCheck = on;
    await _setPref('autoCheck', on);
    notifyListeners();
  }

  Future<void> _setPref(String key, Object? value) => _channel.invokeMethod('setPref', {'key': key, 'value': value});

  Future<void> _refreshDownload() async {
    final s = await _channel.invokeMapMethod<String, dynamic>('status');
    final wasActive = download.active;
    download = UpdateDownload(s ?? const {});
    if (download.active) {
      _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _poll?.cancel();
      _poll = null;
      if (wasActive && download.status == 'done') readyToInstall.add(null);
    }
  }

  Future<void> _tick() async {
    await _refreshDownload();
    _syncPhase();
    notifyListeners();
  }

  void _syncPhase({bool keepError = false}) {
    if (!keepError && download.status != 'failed') error = null;
    phase = switch (download.status) {
      'pending' || 'running' || 'paused' => UpdatePhase.downloading,
      'done' => UpdatePhase.ready,
      'failed' => UpdatePhase.failed,
      _ when phase == UpdatePhase.checking => UpdatePhase.checking,
      _ when latest != null && compareVersions(latest!.version, currentVersion) > 0 => UpdatePhase.available,
      _ when lastCheck != null && error == null => UpdatePhase.upToDate,
      _ => UpdatePhase.idle,
    };
    if (phase == UpdatePhase.failed) error = download.reasonText;
  }

  @override
  void dispose() {
    _poll?.cancel();
    readyToInstall.close();
    super.dispose();
  }
}

/// Compares dotted versions ("0.1.12" vs "0.1.9"); a build suffix (+N) or pre-release tag is ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp('^v'), '')
      .split(RegExp(r'[+-]'))
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// "37.4 MB" and the like.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
