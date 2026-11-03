import 'package:flutter/material.dart';

import 'recognizer.dart';
import 'scan_page.dart';
import 'write_page.dart';

void main() => runApp(const HandWriteApp());

class HandWriteApp extends StatelessWidget {
  const HandWriteApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HandWrite AI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final recognizer = DigitRecognizer();
  bool ready = false;
  String? error;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    recognizer.load().then((_) {
      if (mounted) setState(() => ready = true);
    }).catchError((Object e) {
      if (mounted) setState(() => error = e.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Model load nahi hua:\n$error'),
          ),
        ),
      );
    }
    if (!ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: IndexedStack(
        index: tab,
        children: [
          CalculatorPage(recognizer: recognizer),
          ScanPage(recognizer: recognizer),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.edit), label: 'Likho'),
          NavigationDestination(
              icon: Icon(Icons.document_scanner_outlined), label: 'Scan'),
        ],
      ),
    );
  }
}
