import 'package:flutter/material.dart';

void main() => runApp(const SemanticsApp());

/// A counter and a text field, each with a test id: a client finds them in
/// the semantics tree, taps the button and sets the field's text by node.
/// Each change prints a line (COUNT n, TEXT t) for a test to wait on.
class SemanticsApp extends StatefulWidget {
  const SemanticsApp({super.key});

  @override
  State<SemanticsApp> createState() => _SemanticsAppState();
}

class _SemanticsAppState extends State<SemanticsApp> {
  var _count = 0;

  void _increment() {
    setState(() => _count++);
    debugPrint('COUNT $_count');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(left: 100, top: 50),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                identifier: 'count',
                child: Text('Count $_count'),
              ),
              Semantics(
                identifier: 'increment',
                child: SizedBox(
                  width: 200,
                  height: 60,
                  child: ElevatedButton(
                    onPressed: _increment,
                    child: const Text('Increment'),
                  ),
                ),
              ),
              Semantics(
                identifier: 'name',
                child: SizedBox(
                  width: 300,
                  child: TextField(
                    decoration: const InputDecoration(hintText: 'Name'),
                    onChanged: (text) => debugPrint('TEXT $text'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
