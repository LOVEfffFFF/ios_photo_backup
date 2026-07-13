import 'dart:convert';
import 'package:flutter/material.dart';
import 'ui/main_page.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  runApp(const PhotoBackupApp());
}

class PhotoBackupApp extends StatelessWidget {
  const PhotoBackupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '相册备份',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const MainPage(),
    );
  }
}
