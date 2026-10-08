import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../helpers/photo_library_helper.dart';
import '../managers/backup_manager.dart';
import '../managers/restore_manager.dart';
import '../services/server_client.dart';
import '../services/server_config.dart';

/// 主界面
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final BackupManager _backupManager = BackupManager();
  final RestoreManager _restoreManager = RestoreManager();

  // 服务器配置
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _limitController = TextEditingController();
  ServerConfig _config = ServerConfig.empty;
  bool _testing = false;
  bool _connectionOk = false;
  String? _connectionHint;

  // 运行状态
  String _statusText = '就绪';
  double _progress = 0;
  int _completed = 0;
  int _total = 0;
  int _uploadedBytes = 0;
  bool _isOperating = false;

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
    _loadConfig();
    _loadStats();
  }

  @override
  void dispose() {
    _backupSubscription?.cancel();
    _restoreSubscription?.cancel();
    _addressController.dispose();
    _tokenController.dispose();
    _limitController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await ServerConfig.load();
    if (!mounted) return;
    setState(() {
      _config = config;
      if (config.isConfigured) {
        _addressController.text = config.displayAddress;
        _tokenController.text = config.token;
      }
      if (config.backupLimit > 0) {
        _limitController.text = config.backupLimit.toString();
      }
    });
  }

  /// 读取「本次最多备份」输入框，非法或留空按 0（不限制）处理
  int _parseLimit() {
    final value = int.tryParse(_limitController.text.trim()) ?? 0;
    return value < 0 ? 0 : value;
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
    if (!mounted) return;
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _logs.insert(0, '[$time] $message');
      if (_logs.length > 200) {
        _logs.removeLast();
      }
    });

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

  /// 解析输入框里的地址与数量上限，非法时返回 null
  ServerConfig? _parseInput() {
    return ServerConfig.parseAddress(
      _addressController.text,
      token: _tokenController.text,
      backupLimit: _parseLimit(),
    );
  }

  Future<void> _saveAndTest() async {
    final parsed = _parseInput();
    if (parsed == null) {
      setState(() {
        _connectionOk = false;
        _connectionHint = '地址格式不正确，示例：192.168.1.10:8080 或 nas.local:8080';
      });
      return;
    }

    await parsed.save();
    if (!mounted) return;
    setState(() {
      _config = parsed;
      _connectionOk = false;
      _connectionHint = '正在请求本地网络权限，若弹出「允许访问本地网络」请点允许...';
      _testing = true;
    });

    // iOS 14+ 首次访问局域网必须授权，单播连接不足以触发系统询问，
    // 这里主动做一次 Bonjour 探测把授权窗逼出来
    await PhotoLibraryHelper.requestLocalNetworkPermission();
    if (!mounted) return;
    setState(() {
      _connectionHint = '正在测试连接...';
    });

    final error = await ServerClient(parsed).testConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _connectionOk = error == null;
      _connectionHint = error ?? '连接正常，可以开始备份';
    });
    _addLog(error == null
        ? '服务器连接正常：${parsed.baseUrl}'
        : '服务器连接异常：$error');
  }

  Future<void> _startBackup() async {
    if (_isOperating) return;

    // 传输期间保持屏幕常亮，防止息屏导致中断
    await WakelockPlus.enable();

    setState(() {
      _isOperating = true;
      _progress = 0;
      _completed = 0;
      _total = 0;
      _uploadedBytes = 0;
      _statusText = '正在备份...';
    });

    final limit = _parseLimit();
    _addLog('开始增量备份 → ${_config.isConfigured ? _config.baseUrl : '未配置服务器'}'
        '${limit > 0 ? '（本次最多 $limit 个）' : ''}');

    _backupSubscription = _backupManager.startBackup(limit: limit).listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _completed = progress.completed;
          _total = progress.total;
          _progress = progress.percentage;
          _uploadedBytes = progress.uploadedBytes;
          if (progress.currentFile != null) {
            _statusText = progress.currentFile!;
          }
        });

        // 单文件失败只记日志，不中断整批（fatal 才是终止信号）
        if (progress.error != null) {
          _addLog(progress.fatal ? '❌ ${progress.error}' : '⚠️ ${progress.error}');
        }

        if (progress.fatal) {
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

    // 下载期间保持屏幕常亮
    await WakelockPlus.enable();

    setState(() {
      _isOperating = true;
      _progress = 0;
      _completed = 0;
      _total = 0;
      _uploadedBytes = 0;
      _statusText = '正在从电脑恢复...';
    });

    _addLog('开始恢复：从 ${_config.isConfigured ? _config.baseUrl : '未配置服务器'} 拉回相册');

    _restoreSubscription = _restoreManager.startRestore().listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _completed = progress.completed;
          _total = progress.total;
          _progress = progress.percentage;
          _uploadedBytes = progress.downloadedBytes;
          if (progress.currentFile != null) {
            _statusText = progress.currentFile!;
          }
        });

        if (progress.error != null) {
          _addLog(progress.fatal ? '❌ ${progress.error}' : '⚠️ ${progress.error}');
        }

        if (progress.fatal) {
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
    WakelockPlus.disable();
    setState(() {
      _isOperating = false;
      if (!_statusText.contains('完成') &&
          !_statusText.contains('取消') &&
          !_statusText.contains('结束')) {
        _statusText = '操作结束';
      }
    });
  }

  void _cancelOperation() {
    _backupManager.cancel();
    _restoreManager.cancel();
    _backupSubscription?.cancel();
    _restoreSubscription?.cancel();
    WakelockPlus.disable();
    setState(() {
      _isOperating = false;
      _statusText = '操作已取消';
    });
    _addLog('操作已取消');
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
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
        // 数字键盘没有「收起」键，点页面空白处主动收起
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildStatusCard(),
                const SizedBox(height: 16),
                _buildServerCard(),
                const SizedBox(height: 16),
                _buildProgressCard(),
                const SizedBox(height: 16),
                _buildActionCard(),
                const SizedBox(height: 16),
                _buildLogCard(),
              ],
            ),
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStatItem('已备份', '$_backedCount', Icons.cloud_done_outlined),
            _buildStatItem('状态', _isOperating ? '运行中' : '就绪', Icons.info_outline),
            _buildStatItem(
              '服务器',
              _config.isConfigured ? '已配置' : '未配置',
              Icons.dns_outlined,
            ),
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

  Widget _buildServerCard() {
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
              '服务器设置',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              '在电脑上运行接收端脚本后，把下面地址填成电脑的 IP 或域名',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _addressController,
              enabled: !_isOperating,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '电脑地址（可带端口）',
                hintText: '例如 192.168.1.10:8080',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              enabled: !_isOperating,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '访问密钥（接收端未启用可留空）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _limitController,
              enabled: !_isOperating,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '本次最多备份数量（留空 = 全部）',
                hintText: '例如填 10，用于小批量测试',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            _buildButton(
              label: _testing ? '测试中...' : '保存并测试连接',
              icon: Icons.wifi_tethering,
              color: Colors.teal,
              onPressed: (_isOperating || _testing) ? null : _saveAndTest,
            ),
            if (_connectionHint != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _connectionOk ? Icons.check_circle : Icons.error_outline,
                    size: 16,
                    color: _connectionOk ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _connectionHint!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _connectionOk
                            ? Colors.green.shade700
                            : Colors.orange.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
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
                const Text(
                  '进度',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_progress.toStringAsFixed(1)}%',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                ),
                if (_uploadedBytes > 0)
                  Text(
                    '已传输 ${_formatBytes(_uploadedBytes)}',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                  ),
              ],
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

  Widget _buildActionCard() {
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
                    label: '备份到电脑',
                    icon: Icons.cloud_upload_outlined,
                    color: Colors.blue,
                    onPressed: _isOperating ? null : _startBackup,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildButton(
                    label: '从电脑恢复',
                    icon: Icons.cloud_download_outlined,
                    color: Colors.green,
                    onPressed: _isOperating ? null : _startRestore,
                  ),
                ),
              ],
            ),
            if (_isOperating) ...[
              const SizedBox(height: 12),
              _buildButton(
                label: '取消操作',
                icon: Icons.cancel_outlined,
                color: Colors.red,
                onPressed: _cancelOperation,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '备份会跳过已传输的；恢复只导入尚未恢复过的照片，可重复点击不会重复导入。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
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
