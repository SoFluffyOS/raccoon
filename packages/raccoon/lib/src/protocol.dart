/// Constants shared by the runner and its Dart clients.
abstract final class RaccoonProtocol {
  /// Bumped on incompatible changes. A runner refuses a client with a newer
  /// major version.
  static const int version = 1;

  /// The environment variable the runner sets for every app it hosts. Its
  /// value is the runner's endpoint, `unix:<path>`, a socket file on every
  /// host, Windows included.
  static const String endpointVariable = 'RACCOON_ENDPOINT';
}
