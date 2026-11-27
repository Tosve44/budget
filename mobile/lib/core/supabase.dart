import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

typedef Row = Map<String, dynamic>;

class SupabaseError implements Exception {
  /// 'network', 'server', 'notSignedIn' or 'badResponse'.
  final String kind;
  final int status;
  final String? code;
  final String message;
  const SupabaseError(this.kind, {this.status = 0, this.code, this.message = ''});

  static const notSignedIn = SupabaseError('notSignedIn');
  static const badResponse = SupabaseError('badResponse');

  /// Messages a person can act on (same wording as the web app).
  String get friendly {
    switch (kind) {
      case 'network':
        return 'No connection. Your changes are saved on this phone and will sync later.';
      case 'notSignedIn':
        return 'Please sign in first.';
      case 'badResponse':
        return 'The server sent something unexpected. Try again later.';
    }
    const rules = [
      ['Invalid login credentials', 'Wrong email or password.'],
      ['already registered', 'This email already has an account. Sign in instead.'],
      ['already been registered', 'This email already has an account. Sign in instead.'],
      ['Password should be', 'Password is too short (at least 6 characters).'],
      ['invite code not found', 'That invite code was not found.'],
      ['household is full', 'That household already has two people.'],
      ['already in a household', 'This account is already in a household.'],
      ['Email not confirmed', 'Please confirm your email first (check your inbox), then sign in.'],
    ];
    final low = message.toLowerCase();
    for (final r in rules) {
      if (low.contains(r[0].toLowerCase())) return r[1];
    }
    return message;
  }

  @override
  String toString() => friendly;
}

/// A signed-in session. Kept in the phone's secure storage by the app.
class AuthSession {
  final String accessToken;
  final String refreshToken;

  /// Seconds since 1970.
  final double expiresAt;
  final String userId;
  final String? email;
  const AuthSession({required this.accessToken, required this.refreshToken, required this.expiresAt, required this.userId, this.email});

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
    accessToken: j['accessToken'] as String,
    refreshToken: j['refreshToken'] as String,
    expiresAt: (j['expiresAt'] as num).toDouble(),
    userId: j['userId'] as String,
    email: j['email'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt,
    'userId': userId,
    'email': email,
  };
}

/// Where the session is remembered between app launches.
abstract class SessionKeeper {
  AuthSession? load();
  Future<void> save(AuthSession? session);
}

class MemorySessionKeeper implements SessionKeeper {
  AuthSession? session;
  MemorySessionKeeper([this.session]);
  @override
  AuthSession? load() => session;
  @override
  Future<void> save(AuthSession? s) async => session = s;
}

/// Talks to a Supabase project over its web API: sign-in, tables, functions and photo storage.
/// Only the parts the budget app needs (a port of the iPhone app's Supabase.swift).
class SupabaseClient {
  final Uri url;
  final String anonKey;
  final http.Client _http;
  final SessionKeeper keeper;
  AuthSession? session;
  DateTime Function() now = DateTime.now;

  /// A hung connection must never freeze syncing: give up after this long (photos get longer).
  Duration requestTimeout = const Duration(seconds: 20);
  Duration uploadTimeout = const Duration(seconds: 90);

  SupabaseClient({required this.url, required this.anonKey, http.Client? client, SessionKeeper? keeper})
    : _http = client ?? http.Client(),
      keeper = keeper ?? MemorySessionKeeper() {
    session = this.keeper.load();
  }

  String? get userId => session?.userId;

  Uri _uri(String path, List<(String, String)> query) {
    final base = url.toString().endsWith('/') ? url.toString() : '${url.toString()}/';
    var s = '$base$path';
    if (query.isNotEmpty) {
      // "+" in a time zone ("+00:00") must not turn into a space, so everything is encoded.
      s += '?${query.map((q) => '${Uri.encodeQueryComponent(q.$1)}=${Uri.encodeQueryComponent(q.$2).replaceAll('+', '%20')}').join('&')}';
    }
    return Uri.parse(s);
  }

  Future<http.Response> request(
    String method,
    String path, {
    List<(String, String)> query = const [],
    Object? json,
    Uint8List? body,
    Map<String, String> headers = const {},
    bool auth = true,
    Duration? timeout,
  }) async {
    final token = auth ? await validAccessToken() : null;
    http.Request build() {
      final req = http.Request(method, _uri(path, query));
      req.headers['apikey'] = anonKey;
      if (token != null) {
        req.headers['Authorization'] = 'Bearer $token';
      } else if (anonKey.startsWith('eyJ')) {
        // Old-style anon keys are tokens and go in both headers. New "sb_publishable_…" keys
        // are not tokens and must only be sent as apikey.
        req.headers['Authorization'] = 'Bearer $anonKey';
      }
      if (json != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(json);
      } else if (body != null) {
        req.bodyBytes = body;
      }
      req.headers.addAll(headers);
      return req;
    }

    // A connection kept open from an earlier request may have been closed by the server or the
    // phone's network meanwhile. Requests that are safe to repeat (reads, upserts by id, photo
    // uploads that overwrite) get one more try on a fresh connection.
    final repeatable = !path.startsWith('rest/v1/rpc/') && !path.startsWith('auth/');
    http.Response res;
    for (var attempt = 0; ; attempt++) {
      try {
        final streamed = await _http.send(build()).timeout(timeout ?? requestTimeout);
        res = await http.Response.fromStream(streamed).timeout(timeout ?? requestTimeout);
        break;
      } on TimeoutException {
        throw const SupabaseError('network', message: 'Timed out');
      } on SupabaseError {
        rethrow;
      } catch (e) {
        if (repeatable && attempt == 0 && _staleConnection(e)) continue;
        throw SupabaseError('network', message: '$e');
      }
    }
    if (res.statusCode < 200 || res.statusCode >= 300) throw _error(res.statusCode, res.bodyBytes);
    return res;
  }

  static bool _staleConnection(Object e) {
    final m = '$e';
    return m.contains('Broken pipe') || m.contains('Connection closed before') || m.contains('Connection reset');
  }

  static SupabaseError _error(int status, List<int> data) {
    Map obj = {};
    try {
      final v = jsonDecode(utf8.decode(data));
      if (v is Map) obj = v;
    } catch (_) {}
    final msg = obj['message'] ?? obj['msg'] ?? obj['error_description'] ?? obj['error'];
    final code = obj['code'] ?? obj['error_code'];
    return SupabaseError(
      'server',
      status: status,
      code: code is String ? code : null,
      message: msg is String ? msg : 'Request failed ($status).',
    );
  }

  dynamic _json(http.Response r) {
    if (r.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw SupabaseError.badResponse;
    }
  }

  // ---- sign-in ----

  Future<AuthSession?> _takeSession(http.Response r) async {
    final obj = _json(r);
    if (obj is! Map) throw SupabaseError.badResponse;
    final access = obj['access_token'], refresh = obj['refresh_token'], user = obj['user'];
    if (access is! String || refresh is! String || user is! Map || user['id'] is! String) return null;
    final expiresIn = (obj['expires_in'] as num?)?.toDouble() ?? 3600;
    final s = AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: now().millisecondsSinceEpoch / 1000 + expiresIn,
      userId: user['id'] as String,
      email: user['email'] as String?,
    );
    session = s;
    await keeper.save(s);
    return s;
  }

  /// Creates an account. Returns false when the project asks for an email confirmation first.
  Future<bool> signUp(String email, String password) async {
    final r = await request('POST', 'auth/v1/signup', json: {'email': email, 'password': password}, auth: false);
    return await _takeSession(r) != null;
  }

  Future<void> signIn(String email, String password) async {
    final r = await request(
      'POST',
      'auth/v1/token',
      query: [('grant_type', 'password')],
      json: {'email': email, 'password': password},
      auth: false,
    );
    if (await _takeSession(r) == null) throw SupabaseError.badResponse;
  }

  Future<void> signOut() async {
    if (session != null) {
      try {
        await request('POST', 'auth/v1/logout');
      } catch (_) {}
    }
    session = null;
    await keeper.save(null);
  }

  Future<String>? _refreshing;

  /// The access token, renewed shortly before it runs out.
  Future<String> validAccessToken() async {
    final s = session;
    if (s == null) throw SupabaseError.notSignedIn;
    if (s.expiresAt - now().millisecondsSinceEpoch / 1000 > 60) return s.accessToken;
    // Several requests at once share one refresh (a refresh token can be used only once).
    return _refreshing ??= _refresh(s).whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh(AuthSession s) async {
    try {
      final r = await request(
        'POST',
        'auth/v1/token',
        query: [('grant_type', 'refresh_token')],
        json: {'refresh_token': s.refreshToken},
        auth: false,
      );
      final fresh = await _takeSession(r);
      if (fresh == null) throw SupabaseError.badResponse;
      return fresh.accessToken;
    } on SupabaseError catch (e) {
      if (e.kind == 'server' && (e.status == 400 || e.status == 401)) {
        session = null;
        await keeper.save(null);
        throw SupabaseError.notSignedIn;
      }
      rethrow;
    }
  }

  // ---- tables ----

  /// Rows of a table. [filters] are PostgREST filters such as ("server_updated_at", "gt.2026-…").
  Future<List<Row>> select(String table, {List<(String, String)> filters = const [], String? order, int? limit, int? offset}) async {
    final q = <(String, String)>[('select', '*'), ...filters];
    if (order != null) q.add(('order', order));
    if (limit != null) q.add(('limit', '$limit'));
    if (offset != null) q.add(('offset', '$offset'));
    final v = _json(await request('GET', 'rest/v1/$table', query: q));
    if (v is! List) throw SupabaseError.badResponse;
    return v.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Inserts or updates rows by id. Returns the ids the server accepted.
  Future<List<String>> upsert(String table, List<Row> rows) async {
    final v = _json(
      await request(
        'POST',
        'rest/v1/$table',
        query: [('on_conflict', 'id'), ('select', 'id')],
        json: rows,
        headers: {'Prefer': 'resolution=merge-duplicates,return=representation'},
      ),
    );
    if (v is! List) throw SupabaseError.badResponse;
    return [
      for (final r in v)
        if (r is Map && r['id'] is String) r['id'] as String,
    ];
  }

  Future<void> update(String table, Row values, String column, String equals) async {
    await request('PATCH', 'rest/v1/$table', query: [(column, 'eq.$equals')], json: values);
  }

  /// Calls a database function (create_household, join_household).
  Future<dynamic> rpc(String name, Row params) async => _json(await request('POST', 'rest/v1/rpc/$name', json: params));

  /// PostgREST "in" filter for a list of ids.
  static String inList(List<String> ids) => 'in.(${ids.map((i) => '"${i.replaceAll('"', '')}"').join(',')})';

  // ---- photo storage ----

  Future<void> upload(String bucket, String path, Uint8List jpeg) async {
    await request(
      'POST',
      'storage/v1/object/$bucket/$path',
      body: jpeg,
      headers: {'Content-Type': 'image/jpeg', 'x-upsert': 'true', 'cache-control': 'max-age=3600'},
      timeout: uploadTimeout,
    );
  }

  Future<Uint8List> download(String bucket, String path) async =>
      (await request('GET', 'storage/v1/object/authenticated/$bucket/$path', timeout: uploadTimeout)).bodyBytes;

  Future<void> remove(String bucket, List<String> paths) async {
    await request('DELETE', 'storage/v1/object/$bucket', json: {'prefixes': paths});
  }
}
