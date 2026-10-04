import 'package:flutter/material.dart';

import 'ui/main_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 屏幕常亮改为「传输期间」按需开启，避免 App 装好后设备永不自动锁屏
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
