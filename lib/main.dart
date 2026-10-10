import 'package:flutter/material.dart';

import 'app_info.dart';
import 'services/log_service.dart';
import 'ui/main_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 全局异常捕获必须包住 runApp：runApp 之后抛出的未捕获错误会被
  // FlutterError.onError / PlatformDispatcher.onError 接住，
  // runZonedGuarded 负责兜住异步未 await 的异常。
  // 三层都装上，任何一处崩溃都能留下日志。
  LogService.runGuarded(() async {
    final logs = LogService.instance;
    await logs.init();
    logs.write(LogLevel.info, 'app', '应用启动，${AppInfo.display}');
    runApp(const PhotoBackupApp());
  });
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