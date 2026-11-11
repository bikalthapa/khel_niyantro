import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep the controller in landscape orientation.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  runApp(const ControllerApp());
}

enum ControlMode { mono, dual, accelerometer }

class ControllerApp extends StatelessWidget {
  const ControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'WiFi Controller',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF10151C),
        useMaterial3: true,
      ),
      home: const ControllerScreen(),
    );
  }
}

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  WebSocketChannel? _channel;

  String _url = 'ws://192.168.1.5:8080';
  String _status = 'Disconnected';

  bool _connected = false;
  bool _isLoadingSettings = true;
  String? _settingsLoadError;
  ControlMode _mode = ControlMode.mono;

  Offset _left = Offset.zero;
  Offset _right = Offset.zero;

  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  Offset _accelerometer = Offset.zero;
  Offset _smoothedAccelerometer = Offset.zero;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final loadingStartedAt = DateTime.now();

    if (mounted) {
      setState(() {
        _isLoadingSettings = true;
        _settingsLoadError = null;
      });
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;

      const minimumLoadingDuration = Duration(milliseconds: 700);
      final remainingLoadingDuration =
          minimumLoadingDuration - DateTime.now().difference(loadingStartedAt);
      if (remainingLoadingDuration > Duration.zero) {
        await Future<void>.delayed(remainingLoadingDuration);
      }
      if (!mounted) return;

      final savedMode = prefs.getString('control_mode');

      setState(() {
        _url = prefs.getString('ws_url') ?? _url;

        switch (savedMode) {
          case 'dual':
            _mode = ControlMode.dual;
            break;
          case 'accelerometer':
            _mode = ControlMode.accelerometer;
            break;
          default:
            _mode = ControlMode.mono;
        }

        _isLoadingSettings = false;
      });

      if (_mode == ControlMode.accelerometer) {
        _startAccelerometer();
      }
    } catch (error) {
      debugPrint('Settings load error: $error');

      if (mounted) {
        setState(() {
          _isLoadingSettings = false;
          _settingsLoadError = 'Could not load saved settings.';
        });
      }
    }
  }

  Future<bool> _connect(String url) async {
    WebSocketChannel? newChannel;

    try {
      final uri = Uri.parse(url);

      if (!['ws', 'wss'].contains(uri.scheme) || uri.host.isEmpty) {
        throw Exception('Enter a valid WebSocket URL');
      }

      await _disconnect();

      if (mounted) {
        setState(() => _status = 'Connecting...');
      }

      newChannel = WebSocketChannel.connect(uri);
      await newChannel.ready.timeout(const Duration(seconds: 8));

      if (!mounted) {
        await newChannel.sink.close();
        return false;
      }

      _channel = newChannel;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ws_url', url);

      if (!mounted) return false;

      setState(() {
        _url = url;
        _connected = true;
        _status = 'Connected';
      });

      newChannel.stream.listen(
        (message) {
          // Handle server-to-phone messages here if needed.
          debugPrint('Server message: $message');
        },
        onDone: () {
          if (_channel == newChannel && mounted) {
            setState(() {
              _channel = null;
              _connected = false;
              _status = 'Disconnected';
            });
          }
        },
        onError: (error) {
          debugPrint('WebSocket stream error: $error');

          if (_channel == newChannel && mounted) {
            setState(() {
              _channel = null;
              _connected = false;
              _status = 'Connection error';
            });
          }
        },
      );

      _sendState();
      return true;
    } catch (error) {
      debugPrint('WebSocket connection error: $error');

      try {
        await newChannel?.sink.close();
      } catch (_) {
        // Ignore errors while closing a failed connection.
      }

      if (mounted) {
        setState(() {
          _connected = false;
          _status = 'Connection failed';
        });
      }

      return false;
    }
  }

  Future<void> _disconnect() async {
    final oldChannel = _channel;
    _channel = null;

    if (mounted) {
      setState(() {
        _connected = false;
        _status = 'Disconnected';
      });
    }

    try {
      await oldChannel?.sink.close();
    } catch (error) {
      debugPrint('WebSocket close error: $error');
    }
  }

  void _sendState() {
    if (!_connected || _channel == null) return;

    final Map<String, dynamic> data;

    switch (_mode) {
      case ControlMode.mono:
        data = {
          'mode': 'mono',
          'joystick': {'x': _left.dx * 5, 'y': _left.dy * 5},
        };
        break;

      case ControlMode.dual:
        data = {
          'mode': 'dual',
          'left': {'x': _left.dx * 5, 'y': _left.dy * 5},
          'right': {'x': _right.dx * 5, 'y': _right.dy * 5},
        };
        break;

      case ControlMode.accelerometer:
        data = {
          'mode': 'accelerometer',
          'accelerometer': {
            'x': _accelerometer.dx * 5,
            'y': _accelerometer.dy * 5,
          },
        };
        break;
    }

    try {
      _channel!.sink.add(jsonEncode(data));
    } catch (error) {
      debugPrint('WebSocket send error: $error');
    }
  }

  void _updateLeft(Offset value) {
    setState(() => _left = value);
    _sendState();
  }

  void _updateRight(Offset value) {
    setState(() => _right = value);
    _sendState();
  }

  void _startAccelerometer() {
    if (_accelerometerSubscription != null) return;

    _accelerometerSubscription = accelerometerEventStream().listen(
      (event) {
        const gravity = 9.81;
        const smoothing = 0.20;
        const deadZone = 0.08;

        // Normalize acceleration to approximately -1.0 through +1.0.
        // Positive X means right. Positive Y means up in the controller UI.
        // Swap X and Y sensor axes
        final rawX = (event.y / gravity).clamp(-1.0, 1.0).toDouble();
        final rawY = (-event.x / gravity).clamp(-1.0, 1.0).toDouble();

        // Smooth readings to reduce jitter.
        final smoothX =
            _smoothedAccelerometer.dx +
            (rawX - _smoothedAccelerometer.dx) * smoothing;
        final smoothY =
            _smoothedAccelerometer.dy +
            (rawY - _smoothedAccelerometer.dy) * smoothing;

        var nextValue = Offset(smoothX, smoothY);

        // Keep the combined X/Y magnitude inside a unit circle.
        final distance = math.sqrt(
          nextValue.dx * nextValue.dx + nextValue.dy * nextValue.dy,
        );

        if (distance > 1.0) {
          nextValue = Offset(nextValue.dx / distance, nextValue.dy / distance);
        }

        // Ignore tiny movements around the neutral position.
        nextValue = Offset(
          nextValue.dx.abs() < deadZone ? 0.0 : nextValue.dx,
          nextValue.dy.abs() < deadZone ? 0.0 : nextValue.dy,
        );

        _smoothedAccelerometer = nextValue;

        if (!mounted || _mode != ControlMode.accelerometer) return;

        setState(() {
          _accelerometer = nextValue;
        });

        _sendState();
      },
      onError: (error) {
        debugPrint('Accelerometer error: $error');
      },
    );
  }

  void _stopAccelerometer() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;

    _accelerometer = Offset.zero;
    _smoothedAccelerometer = Offset.zero;
  }

  Future<void> _changeMode(ControlMode mode) async {
    if (_mode == ControlMode.accelerometer) {
      _stopAccelerometer();
    }

    setState(() {
      _mode = mode;
      _left = Offset.zero;
      _right = Offset.zero;
      _accelerometer = Offset.zero;
    });

    if (mode == ControlMode.accelerometer) {
      _startAccelerometer();
    }

    final prefs = await SharedPreferences.getInstance();

    final modeName = switch (mode) {
      ControlMode.mono => 'mono',
      ControlMode.dual => 'dual',
      ControlMode.accelerometer => 'accelerometer',
    };

    await prefs.setString('control_mode', modeName);
    _sendState();
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          initialUrl: _url,
          connected: _connected,
          status: _status,
          onConnect: _connect,
          onDisconnect: _disconnect,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isLoadingSettings || _settingsLoadError != null
          ? null
          : AppBar(
              toolbarHeight: 55,
              title: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Image.asset(
                  'assets/icon/wordmark.png',
                  height: 40,
                  fit: BoxFit.contain,
                  semanticLabel: 'Khel Niyantro',
                ),
              ),
              actions: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _connected
                          ? Colors.green.withOpacity(0.15)
                          : Colors.red.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 9,
                          color: _connected ? Colors.green : Colors.red,
                        ),
                        const SizedBox(width: 6),
                        Text(_status, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings),
                  tooltip: 'Configuration',
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: _isLoadingSettings
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.gamepad, color: Colors.cyan, size: 42),
                  const SizedBox(height: 16),
                  const Text(
                    'Loading WiFi Controller',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 20),
                  const SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.cyan,
                    ),
                  ),
                ],
              ),
            )
          : _settingsLoadError != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Colors.orangeAccent,
                    size: 40,
                  ),
                  const SizedBox(height: 12),
                  Text(_settingsLoadError!),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _loadSettings,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: SegmentedButton<ControlMode>(
                    segments: const [
                      ButtonSegment(
                        value: ControlMode.mono,
                        label: Text('Mono'),
                        icon: Icon(Icons.gamepad_outlined),
                      ),
                      ButtonSegment(
                        value: ControlMode.dual,
                        label: Text('Dual'),
                        icon: Icon(Icons.sports_esports),
                      ),
                      ButtonSegment(
                        value: ControlMode.accelerometer,
                        label: Text('Motion'),
                        icon: Icon(Icons.screen_rotation),
                      ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (selection) {
                      _changeMode(selection.first);
                    },
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final padSize = math.max(
                        100.0,
                        math.min(220.0, constraints.maxHeight - 30),
                      );

                      if (_mode == ControlMode.accelerometer) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: padSize,
                                height: padSize,
                                child: CustomPaint(
                                  painter: JoystickPainter(_accelerometer),
                                  child: const Center(
                                    child: Text(
                                      'TILT PHONE',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        letterSpacing: 2,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Tilt your phone to control movement',
                                style: TextStyle(color: Colors.white60),
                              ),
                            ],
                          ),
                        );
                      }

                      if (_mode == ControlMode.mono) {
                        return Center(
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: JoystickPad(
                              size: padSize,
                              value: _left,
                              label: 'MAIN JOYSTICK',
                              onChanged: _updateLeft,
                            ),
                          ),
                        );
                      }

                      return Row(
                        children: [
                          Expanded(
                            child: Center(
                              child: JoystickPad(
                                size: padSize,
                                value: _left,
                                label: 'LEFT JOYSTICK',
                                onChanged: _updateLeft,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Center(
                              child: JoystickPad(
                                size: padSize,
                                value: _right,
                                label: 'RIGHT JOYSTICK',
                                onChanged: _updateRight,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: 6,
                    left: 12,
                    right: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_mode == ControlMode.accelerometer) ...[
                        _coordinate('AX', _accelerometer.dx * 5),
                        const SizedBox(width: 20),
                        _coordinate('AY', _accelerometer.dy * 5),
                      ] else ...[
                        _coordinate('LX', _left.dx * 5),
                        const SizedBox(width: 20),
                        _coordinate('LY', _left.dy * 5),
                        if (_mode == ControlMode.dual) ...[
                          const SizedBox(width: 25),
                          _coordinate('RX', _right.dx * 5),
                          const SizedBox(width: 20),
                          _coordinate('RY', _right.dy * 5),
                        ],
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _coordinate(String label, double value) {
    return Text(
      '$label: ${value.toStringAsFixed(2)}',
      style: const TextStyle(
        fontSize: 12,
        color: Colors.cyan,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

// Reusable virtual joystick.

class JoystickPad extends StatelessWidget {
  final double size;
  final Offset value;
  final String label;
  final ValueChanged<Offset> onChanged;

  const JoystickPad({
    super.key,
    required this.size,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  Offset _calculate(Offset position) {
    final radius = size / 2 - 38;

    if (radius <= 0) return Offset.zero;

    double dx = (position.dx - size / 2) / radius;
    double dy = (size / 2 - position.dy) / radius;

    final distance = math.sqrt(dx * dx + dy * dy);

    if (distance > 1) {
      dx /= distance;
      dy /= distance;
    }

    return Offset(dx, dy);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          onChanged(_calculate(details.localPosition));
        },
        onPanUpdate: (details) {
          onChanged(_calculate(details.localPosition));
        },
        onPanEnd: (_) {
          onChanged(Offset.zero);
        },
        onPanCancel: () {
          onChanged(Offset.zero);
        },
        child: CustomPaint(
          painter: JoystickPainter(value),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 10,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class JoystickPainter extends CustomPainter {
  final Offset value;

  JoystickPainter(this.value);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 38;

    final background = Paint()
      ..color = const Color(0xFF1C2935)
      ..style = PaintingStyle.fill;

    final border = Paint()
      ..color = Colors.cyan.withOpacity(0.6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;

    canvas.drawCircle(center, radius + 32, background);
    canvas.drawCircle(center, radius + 32, border);
    canvas.drawCircle(center, radius, grid);

    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      grid,
    );

    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      grid,
    );

    final knobPosition = Offset(
      center.dx + value.dx * radius,
      center.dy - value.dy * radius,
    );

    final knobPaint = Paint()
      ..color = Colors.cyan
      ..style = PaintingStyle.fill;

    canvas.drawCircle(knobPosition, 32, knobPaint);

    final knobBorder = Paint()
      ..color = Colors.white.withOpacity(0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(knobPosition, 32, knobBorder);
  }

  @override
  bool shouldRepaint(covariant JoystickPainter oldDelegate) {
    return oldDelegate.value != value;
  }
}

// WebSocket configuration page.

class SettingsPage extends StatefulWidget {
  final String initialUrl;
  final bool connected;
  final String status;
  final Future<bool> Function(String) onConnect;
  final Future<void> Function() onDisconnect;

  const SettingsPage({
    super.key,
    required this.initialUrl,
    required this.connected,
    required this.status,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _urlController;

  bool _loading = false;
  bool _connected = false;
  String _status = 'Disconnected';

  @override
  void initState() {
    super.initState();

    _urlController = TextEditingController(text: widget.initialUrl);
    _connected = widget.connected;
    _status = widget.status;
  }

  Future<void> _connect() async {
    setState(() => _loading = true);

    final success = await widget.onConnect(_urlController.text.trim());

    if (!mounted) return;

    setState(() {
      _loading = false;
      _connected = success;
      _status = success ? 'Connected' : 'Connection failed';
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Connected successfully'
              : 'Could not connect. Check URL and server.',
        ),
      ),
    );
  }

  Future<void> _disconnect() async {
    await widget.onDisconnect();

    if (!mounted) return;

    setState(() {
      _connected = false;
      _status = 'Disconnected';
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuration')),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 550),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.wifi, color: Colors.cyan, size: 35),
                  const SizedBox(height: 15),
                  const Text(
                    'WebSocket Connection',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Enter the WebSocket server address of your laptop.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 25),
                  TextField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'WebSocket URL',
                      hintText: 'ws://192.168.1.5:8080',
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 10,
                        color: _connected ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Text(_status),
                    ],
                  ),
                  const SizedBox(height: 25),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _loading || _connected ? null : _connect,
                          icon: _loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.wifi),
                          label: const Text('Connect'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _connected ? _disconnect : null,
                          icon: const Icon(Icons.link_off),
                          label: const Text('Disconnect'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 25),
                  const Divider(),
                  const Text(
                    'Connection instructions',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '1. Connect your phone and laptop to the same Wi-Fi.\n'
                    '2. Start your laptop WebSocket server.\n'
                    '3. Find your laptop IPv4 address.\n'
                    '4. Enter ws://YOUR_IP:8080 here.\n'
                    '5. Tap Connect.',
                    style: TextStyle(color: Colors.white60, height: 1.8),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
