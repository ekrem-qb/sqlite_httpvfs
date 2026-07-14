/// Configuration for the HTTP range-request VFS.
class HttpVfsConfig {
  /// The server mode: either "full" or "chunked".
  final String serverMode;

  /// Page/chunk size in bytes requested from the server.
  final int requestChunkSize;

  /// Optional cache bust query parameter.
  final String? cacheBust;

  /// The remote database URL (only used in "full" mode).
  final String? url;

  /// The prefix for chunk URLs (only used in "chunked" mode).
  final String? urlPrefix;

  /// The size of each chunk file in bytes (only used in "chunked" mode).
  final int? serverChunkSize;

  /// The total size of the database file in bytes (only used in "chunked" mode).
  final int? databaseLengthBytes;

  /// The length of the numeric chunk suffix (only used in "chunked" mode).
  final int? suffixLength;

  HttpVfsConfig({
    required this.serverMode,
    required this.requestChunkSize,
    this.cacheBust,
    this.url,
    this.urlPrefix,
    this.serverChunkSize,
    this.databaseLengthBytes,
    this.suffixLength,
  });

  factory HttpVfsConfig.fromJson(Map<String, dynamic> json) {
    return HttpVfsConfig(
      serverMode: json['serverMode'] as String,
      requestChunkSize: json['requestChunkSize'] as int,
      cacheBust: json['cacheBust'] as String?,
      url: json['url'] as String?,
      urlPrefix: json['urlPrefix'] as String?,
      serverChunkSize: json['serverChunkSize'] as int?,
      databaseLengthBytes: json['databaseLengthBytes'] as int?,
      suffixLength: json['suffixLength'] as int?,
    );
  }
}
