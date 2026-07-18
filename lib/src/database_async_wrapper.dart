import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite_httpvfs/sqlite_httpvfs.dart';
import 'package:sqlite_httpvfs/src/http_vfs_config.dart';

const int _kMaxAttempts = 100;

/// Exception thrown when a query fails to complete because the maximum retry
/// limit for fetching pending VFS data was exceeded.
class DatabaseRetryLimitExceededException implements Exception {
  final String? sql;
  final int attempts;
  final SqliteException cause;

  DatabaseRetryLimitExceededException({
    this.sql,
    required this.attempts,
    required this.cause,
  });

  @override
  String toString() {
    final sqlPart = sql != null ? ' SQL: $sql\n' : '';
    return 'DatabaseRetryLimitExceededException: Failed to complete operation after $attempts attempts.\n'
        '$sqlPart'
        'Cause: $cause';
  }
}

class DatabaseAsyncWrapper {
  final Database _db;
  final AsyncHttpFetcher _fetcher;
  final HttpClient _httpClient;
  final bool _isHttpClientOwned;
  final HttpVfs _vfs;

  DatabaseAsyncWrapper._({
    required Database database,
    required AsyncHttpFetcher fetcher,
    required HttpClient httpClient,
    required bool isHttpClientOwned,
    required HttpVfs vfs,
  })  : _db = database,
        _fetcher = fetcher,
        _httpClient = httpClient,
        _isHttpClientOwned = isHttpClientOwned,
        _vfs = vfs;

  void close() {
    sqlite3.unregisterVirtualFileSystem(_vfs);
    _db.close();
    _fetcher.close();
    if (_isHttpClientOwned) {
      _httpClient.close();
    }
  }

  static Future<DatabaseAsyncWrapper> open(
    String url, {
    String vfsName = 'httpvfs',
    HttpVfs? vfs,
    OpenMode mode = OpenMode.readOnly,
    bool uri = false,
    bool? mutex,
    HttpClient? httpClient,
  }) async {
    final bool isHttpClientOwned;
    switch (httpClient) {
      case null:
        httpClient = HttpClient();
        isHttpClientOwned = true;
      case HttpClient():
        isHttpClientOwned = false;
    }

    var isVfsRegistered = false;
    AsyncHttpFetcher? createdFetcher;
    try {
      HttpVfsConfig? config;
      Uri? configUri;

      if (url.endsWith('.json')) {
        configUri = Uri.parse(url);
        final configRequest = await httpClient.getUrl(configUri);
        final configResponse = await configRequest.close();
        final configString = await utf8.decodeStream(configResponse);
        final jsonMap = json.decode(configString) as Map<String, Object?>;
        config = HttpVfsConfig.fromJson(jsonMap);
      }

      final fetcher = vfs?.fetcher ??
          (createdFetcher = AsyncHttpFetcher(httpClient: httpClient));

      vfs ??= HttpVfs(
        name: vfsName,
        fetcher: fetcher,
        config: config,
        configUri: configUri,
      );

      sqlite3.registerVirtualFileSystem(vfs);
      isVfsRegistered = true;

      final db = await _waitForValid(
        action: () => sqlite3.open(
          url,
          vfs: vfsName,
          mode: mode,
          uri: uri,
          mutex: mutex,
        ),
        fetcher: fetcher,
      );

      return DatabaseAsyncWrapper._(
        database: db,
        fetcher: fetcher,
        httpClient: httpClient,
        isHttpClientOwned: isHttpClientOwned,
        vfs: vfs,
      );
    } catch (e) {
      if (isVfsRegistered) {
        sqlite3.unregisterVirtualFileSystem(vfs!);
      }
      createdFetcher?.close();
      if (isHttpClientOwned) {
        httpClient.close();
      }
      rethrow;
    }
  }

  Future<ResultSet> select(String sql) {
    return _waitForValid(
      action: () => _db.select(sql),
      fetcher: _fetcher,
      sql: sql,
    );
  }

  static Future<T> _waitForValid<T>({
    required T Function() action,
    required AsyncHttpFetcher fetcher,
    String? sql,
  }) async {
    int attempts = 0;
    while (true) {
      try {
        return action();
      } on SqliteException catch (e) {
        switch (e) {
          case SqliteException(extendedResultCode: 1):
            if (!fetcher.hasPending) {
              rethrow;
            }
            attempts++;
            if (attempts >= _kMaxAttempts) {
              throw DatabaseRetryLimitExceededException(
                sql: sql,
                attempts: attempts,
                cause: e,
              );
            }
            await fetcher.loadPending();
          default:
            rethrow;
        }
      }
    }
  }

  void execute(String _) =>
      throw VfsException(SqlExtendedError.SQLITE_IOERR_WRITE);
}
