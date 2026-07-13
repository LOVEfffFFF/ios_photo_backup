import 'dart:async';

import 'package:flutter/material.dart';

import '../managers/backup_manager.dart';
import '../managers/restore_manager.dart';
import '../managers/record_store.dart';
import '../managers/web_server_manager.dart';

/// 主界面
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final BackupManager _backupManager = BackupManager();
  final RestoreManager _restoreManager = RestoreManager();
  final RecordStore _recordStore = RecordStore();
  final WebServerManager _webServerManager = WebServerManager();

  // 状态
  String _statusText = '就绪';
  double _progress = 0;
  int _completed = 0;
  int _total = 0;
  bool _isOperating = false;
  String? _serverUrl;
  bool _isServerRunning = false;

  // 日志
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  // 备份统计
  int _backedCount = 0;

  StreamSubscription? _backupSubscription;
  StreamSubscription? _restoreSubscription;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  @override
  void dispose() {
    _backupSubscription?.cancel();
    _restoreSubscription?.cancel();
    _webServerManager.stop();
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    try {
      final stats = await _backupManager.getBackupStats();
      if (mounted) {
        setState(() {
          _backedCount = stats['total'] ?? 0;
        });
      }
    } catch (e) {
      _addLog('加载统计信息失败: $e');
    }
  }

  void _addLog(String message) {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logs.insert(0, '[$time] $message');
      if (_logs.length > 200) {
        _logs.removeLast();
      }
    });

    // 自动滚动到最新日志
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _startBackup() async {
    if (_isOperating) return;

    setState(() {
      _isOperating = true;
      _progress = 0;
      _completed = 0;
      _total = 0;
      _statusText = '正在备份...';
    });

    _addLog('开始增量备份');

    final stream = _backupManager.startBackup();
    _backupSubscription = stream.listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _completed = progress.completed;
          _total = progress.total;
          _progress = progress.percentage;
          _statusText = progress.currentFile ?? '备份中...';

          if (progress.error != null) {
            _addLog('❌ ${progress.error}');
          }
        });

        if (progress.percentage >= 100 || progress.error != null) {
          _addLog(
            progress.error != null
                ? '备份出错: ${progress.error}'
                : '备份完成！共备份 ${progress.completed} 个文件',
          );
          _finishOperation();
          _loadStats();
        }
      },
      onError: (error) {
        _addLog('❌ 备份失败: $error');
        _finishOperation();
      },
      onDone: () {
        _finishOperation();
        _loadStats();
      },
    );
  }

  Future<void> _startRestore() async {
    if (_isOperating) return;

    setState(() {
      _isOperating = true;
      _progress = 0;
      _completed = 0;
      _total = 0;
      _statusText = '正在恢复...';
    });

    _addLog('开始恢复照片到相册');

    final stream = _restoreManager.startRestore();
    _restoreSubscription = stream.listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _completed = progress.completed;
          _total = progress.total;
          _progress = progress.percentage;
          _statusText = progress.currentFile ?? '恢复中...';

          if (progress.error != null) {
            _addLog('❌ ${progress.error}');
          }
        });

        if (progress.percentage >= 100 || progress.error != null) {
          _addLog(
            progress.error != null
                ? '恢复出错: ${progress.error}'
                : '恢复完成！成功恢复 ${progress.completed} 个文件',
          );
          _finishOperation();
        }
      },
      onError: (error) {
        _addLog('❌ 恢复失败: $error');
        _finishOperation();
      },
      onDone: () {
        _finishOperation();
      },
    );
  }

  void _finishOperation() {
    if (!mounted) return;
    setState(() {
      _isOperating = false;
      if (!_statusText.contains('完成') && !_statusText.contains('取消')) {
        _statusText = '操作完成';
      }
    });
  }

  void _cancelOperation() {
    _backupManager.cancel();
    _restoreManager.cancel();
    _backupSubscription?.cancel();
    _restoreSubscription?.cancel();
    setState(() {
      _isOperating = false;
      _statusText = '操作已取消';
    });
    _addLog('操作已取消');
  }

  Future<void> _toggleServer() async {
    if (_isServerRunning) {
      await _webServerManager.stop();
      setState(() {
        _isServerRunning = false;
        _serverUrl = null;
      });
      _addLog('WiFi 服务器已关闭');
    } else {
      final result = await _webServerManager.start();
      setState(() {
        _isServerRunning = result != null && !result.contains('失败');
        _serverUrl = result;
      });
      _addLog(result ?? '服务器启动失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F7),
      appBar: AppBar(
        title: const Text('相册备份'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1D1D1F),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 状态卡片
              _buildStatusCard(),
              const SizedBox(height: 16),

              // 进度区域
              _buildProgressCard(),
              const SizedBox(height: 16),

              // 按钮区域
              _buildButtonCard(),
              const SizedBox(height: 16),

              // 日志区域
              _buildLogCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem('已备份', '$_backedCount', Icons.cloud_done_outlined),
                _buildStatItem('状态', _isOperating ? '运行中' : '就绪', Icons.info_outline),
                _buildStatItem('WiFi', _isServerRunning ? '已开启' : '未开启',
                    Icons.wifi),
              ],
            ),
            if (_serverUrl != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.link, size: 16, color: Colors.blue.shade700),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _serverUrl!,
                        style: TextStyle(
                          color: Colors.blue.shade700,
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.blue, size: 24),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _buildProgressCard() {
    if (_total == 0 && !_isOperating) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('进度', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                Text(
                  _total > 0 ? '$_completed / $_total' : '',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _total > 0 ? _progress / 100 : 0,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_progress.toStringAsFixed(1)}%',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            ),
            if (_statusText.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _statusText,
                style: const TextStyle(fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildButtonCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '操作',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildButton(
                    label: '开始备份',
                    icon: Icons.backup_outlined,
                    color: Colors.blue,
                    onPressed: _isOperating ? null : _startBackup,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildButton(
                    label: '恢复到相册',
                    icon: Icons.restore_outlined,
                    color: Colors.green,
                    onPressed: _isOperating ? null : _startRestore,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildButton(
                    label: _isServerRunning ? '关闭 WiFi 服务器' : '开启 WiFi 服务器',
                    icon: _isServerRunning ? Icons.wifi_off : Icons.wifi,
                    color: _isServerRunning ? Colors.orange : Colors.teal,
                    onPressed: _toggleServer,
                  ),
                ),
                if (_isOperating) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildButton(
                      label: '取消操作',
                      icon: Icons.cancel_outlined,
                      color: Colors.red,
                      onPressed: _cancelOperation,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton({
    required String label,
    required IconData icon,
    required Color color,
    VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 48,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontSize: 14)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
          disabledForegroundColor: Colors.grey.shade500,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildLogCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '操作日志',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                if (_logs.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _logs.clear();
                      });
                    },
                    child: const Text('清空', style: TextStyle(fontSize: 13)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无日志',
                        style: TextStyle(color: Color(0xFF86868B)),
                      ),
                    )
                  : ListView.builder(
                      controller: _logScrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Text(
                          _logs[index],
                          style: const TextStyle(
                            color: Color(0xFF98C379),
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
