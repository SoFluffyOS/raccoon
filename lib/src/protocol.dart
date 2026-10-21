/// Constants shared by the runner and its Dart clients.
abstract final class RaccoonProtocol {
  /// Bumped on incompatible changes. A runner refuses a client with a newer
  /// major version.
  static const int version = 1;

  /// The environment variable the runner sets for every app it hosts. Its
  /// value is the runner's endpoint, `unix:<path>` or `tcp:<host>:<port>`.
  static const String endpointVariable = 'RACCOON_ENDPOINT';
}
