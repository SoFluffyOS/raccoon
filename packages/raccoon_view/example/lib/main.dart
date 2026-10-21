// Connects to a runner's socket and shows its app full-window.
//
//   flutter run -d linux --dart-define=RACCOON_SOCKET=/run/user/1000/raccoon/hello.sock
//
// Without the define it uses the runtime's default endpoint for this host.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/raccoon_view.dart';

const _socket = String.fromEnvironment('RACCOON_SOCKET');

void main() => runApp(const ViewerApp());

class ViewerApp extends StatefulWidget {
  const ViewerApp({super.key});

  @override
  State<ViewerApp> createState() => _ViewerAppState();
}

class _ViewerAppState extends State<ViewerApp> {
  RunnerClient? _client;
  String _status = 'connecting';

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final endpoint = _socket.isNotEmpty
        ? UnixSocketEndpoint(_socket)
        : RunnerEndpoint.forHost(
            operatingSystem: Platform.operatingSystem,
            environment: Platform.environment,
            temporaryDirectory: Directory.systemTemp.path,
          );
    try {
      final client = await RunnerClient.connect(endpoint);
      debugPrint('raccoon_viewer: connected to ${endpoint.uri}');
      if (!mounted) return;
      setState(() => _client = client);
    } on SocketException catch (error) {
      if (!mounted) return;
      setState(
        () => _status = 'no runner at ${endpoint.uri}: ${error.message}',
      );
    }
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: switch (_client) {
        final client? => RaccoonView(connection: client),
        null => ColoredBox(
          color: const Color(0xFF202020),
          child: Center(
            child: Text(
              _status,
              style: const TextStyle(color: Color(0xFFFFFFFF)),
            ),
          ),
        ),
      },
    );
  }
}
