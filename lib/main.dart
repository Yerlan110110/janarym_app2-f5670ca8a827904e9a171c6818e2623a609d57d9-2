import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import 'logic/command_router.dart';
import 'openai_client.dart';
import 'voice/command_stt_service.dart';
import 'voice/wake_word_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const JanarymApp());
}

class JanarymApp extends StatelessWidget {
  const JanarymApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Janarym',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const JanarymHome(),
    );
  }
}

enum GptStatus { idle, loading, ok, error }

class JanarymHome extends StatefulWidget {
  const JanarymHome({super.key});

  @override
  State<JanarymHome> createState() => _JanarymHomeState();
}

class _JanarymHomeState extends State<JanarymHome>
    with WidgetsBindingObserver {
  final FlutterTts _tts = FlutterTts();
  final CommandRouter _router = CommandRouter();
  final OpenAiClient _openAi = OpenAiClient();
  late final CommandSttService _sttService;
  late final WakeWordService _wakeService;

  DateTime? _lastWakeAt;
  bool _micGranted = false;
  String _micMessage = 'Проверяю микрофон...';
  CameraController? _cameraController;
  bool _cameraGranted = false;
  bool _cameraStreaming = false;
  bool _cameraInitInProgress = false;
  String _cameraMessage = 'Проверяю камеру...';
  String _cameraError = '';
  DateTime? _lastFrameAt;
  _YuvFrame? _lastFrame;
  int _lastFrameMs = 0;
  GptStatus _gptStatus = GptStatus.idle;
  String _gptError = '';
  String _lastAnswer = '';

  bool _commandInFlight = false;
  String _lastLoggedFinal = '';
  static const int _maxFrameAgeMs = 8000;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sttService = CommandSttService();
    _wakeService = WakeWordService(onWakeWordDetected: _handleWakeDetected);
    _sttService.state.addListener(_handleSttStateChange);
    _wakeService.state.addListener(_handleWakeStateChange);
    _initTts();
    _initMicAndWake();
    _initCameraLive();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sttService.state.removeListener(_handleSttStateChange);
    _wakeService.state.removeListener(_handleWakeStateChange);
    _sttService.dispose();
    _wakeService.dispose();
    _openAi.dispose();
    _disposeCamera();
    _tts.stop();
    super.dispose();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('ru-RU');
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
  }

  Future<void> _initMicAndWake() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;

    if (status.isGranted) {
      setState(() {
        _micGranted = true;
        _micMessage = 'Микрофон доступен.';
      });
      await _wakeService.start();
    } else if (status.isPermanentlyDenied) {
      setState(() {
        _micGranted = false;
        _micMessage =
            'Доступ к микрофону запрещён. Разрешите в настройках приложения.';
      });
    } else {
      setState(() {
        _micGranted = false;
        _micMessage = 'Нужен доступ к микрофону для голосовых команд.';
      });
    }
  }

  Future<void> _initCameraLive() async {
    if (_cameraInitInProgress) return;
    _cameraInitInProgress = true;
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      if (status.isGranted) {
        setState(() {
          _cameraGranted = true;
          _cameraMessage = 'Камера доступна.';
          _cameraError = '';
        });
        await _startCameraStream();
      } else if (status.isPermanentlyDenied) {
        setState(() {
          _cameraGranted = false;
          _cameraMessage =
              'Доступ к камере запрещён. Разрешите в настройках приложения.';
        });
      } else {
        setState(() {
          _cameraGranted = false;
          _cameraMessage = 'Нужен доступ к камере для описания окружения.';
        });
      }
    } finally {
      _cameraInitInProgress = false;
    }
  }

  Future<void> _startCameraStream() async {
    if (_cameraStreaming) return;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _cameraError = 'Камера не найдена.';
        });
        return;
      }

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      await _cameraController?.dispose();
      _cameraController = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_onCameraImage);

      if (!mounted) return;
      setState(() {
        _cameraStreaming = true;
        _cameraMessage = 'Live: ON';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraStreaming = false;
        _cameraError = 'Camera start failed: $e';
        _cameraMessage = 'Live: OFF';
      });
    }
  }

  Future<void> _stopCameraStream() async {
    final controller = _cameraController;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _cameraStreaming = false;
        _cameraMessage = 'Live: OFF';
      });
    }
  }

  Future<void> _disposeCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  void _onCameraImage(CameraImage image) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFrameMs < 400) return;
    _lastFrameMs = now;
    if (image.planes.length < 3) return;

    final yPlane = Uint8List.fromList(image.planes[0].bytes);
    final uPlane = Uint8List.fromList(image.planes[1].bytes);
    final vPlane = Uint8List.fromList(image.planes[2].bytes);

    _lastFrame = _YuvFrame(
      width: image.width,
      height: image.height,
      y: yPlane,
      u: uPlane,
      v: vPlane,
      yRowStride: image.planes[0].bytesPerRow,
      uvRowStride: image.planes[1].bytesPerRow,
      uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
    );
    _lastFrameAt = DateTime.now();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _initCameraLive();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopCameraStream();
    }
  }

  void _handleSttStateChange() {
    final current = _sttService.state.value;
    if (current.finalWords.isNotEmpty &&
        current.finalWords != _lastLoggedFinal) {
      _lastLoggedFinal = current.finalWords;
      debugPrint('[STT] final: ${current.finalWords}');
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handleWakeStateChange() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handleWakeDetected() async {
    if (_commandInFlight) return;
    debugPrint('[Wake] detected');
    setState(() => _lastWakeAt = DateTime.now());
    await _runCommandFlow(reason: 'wake');
  }

  Future<void> _runCommandFlow({required String reason}) async {
    if (_commandInFlight) return;
    if (!_micGranted) return;

    _commandInFlight = true;
    try {
      await _wakeService.stop();
      debugPrint('[STT] start ($reason)');

      final text = await _sttService.startCommandListening(
        durationSeconds: 5,
      );

      final cleaned = (text ?? '').trim();
      if (cleaned.isNotEmpty) {
        await _handleUserText(cleaned);
      }
    } finally {
      await _wakeService.start();
      _commandInFlight = false;
    }
  }

  Future<void> _handleUserText(String text) async {
    final decision = _router.route(text);
    final userText = decision.cleanedText.isEmpty ? text : decision.cleanedText;
    if (decision.isRepeat) {
      await _repeatLastAnswer();
      return;
    }
    if (decision.isDescribe) {
      final describeText = decision.directionRu == null
          ? userText
          : 'Опиши что ${decision.directionRu}';
      await _describeWithVision(describeText);
      return;
    }
    await _askGpt(userText);
  }

  Future<void> _askGpt(String text, {String? systemPrompt}) async {
    setState(() {
      _gptStatus = GptStatus.loading;
      _gptError = '';
    });
    debugPrint('[GPT] start');

    try {
      final answer = await _openAi.askTextOnly(
        text,
        systemPrompt: systemPrompt,
      );
      if (!mounted) return;
      setState(() {
        _gptStatus = GptStatus.ok;
        _lastAnswer = answer;
      });
      debugPrint('[GPT] ok');
      await _speak(answer);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      debugPrint('[GPT] error: $e');
    }
  }

  Future<void> _askGptWithImage(
    String text,
    Uint8List imageBytes, {
    String? systemPrompt,
  }) async {
    setState(() {
      _gptStatus = GptStatus.loading;
      _gptError = '';
    });
    debugPrint('[GPT] vision start');

    try {
      final answer = await _openAi.askWithImage(
        text,
        imageBytes,
        systemPrompt: systemPrompt,
      );
      if (!mounted) return;
      setState(() {
        _gptStatus = GptStatus.ok;
        _lastAnswer = answer;
      });
      debugPrint('[GPT] vision ok');
      await _speak(answer);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      debugPrint('[GPT] vision error: $e');
    }
  }

  Future<void> _describeWithVision(String text) async {
    if (!_cameraGranted) {
      await _initCameraLive();
      if (!_cameraGranted) {
        await _speak('Нет доступа к камере.');
        return;
      }
    }

    if (!_cameraStreaming) {
      await _startCameraStream();
    }

    if (_lastFrame == null || _lastFrameAt == null) {
      await _speak('Камера ещё не готова. Попробуйте через секунду.');
      return;
    }
    final ageMs = DateTime.now().difference(_lastFrameAt!).inMilliseconds;
    if (ageMs > _maxFrameAgeMs) {
      await _speak('Кадр устарел. Повторите команду.');
      return;
    }

    debugPrint('[VISION] send last frame to GPT');
    final frame = _lastFrame!;
    final jpegBytes = await compute(_convertYuvToJpeg, frame.toMap());
    await _askGptWithImage(
      text,
      jpegBytes,
      systemPrompt: CommandRouter.visionSystemPrompt,
    );
  }

  Future<void> _repeatLastAnswer() async {
    if (_lastAnswer.trim().isEmpty) {
      await _speak('Пока нет ответа, который можно повторить.');
      return;
    }
    await _speak(_lastAnswer);
  }

  Future<void> _speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    debugPrint('[TTS] speak');
    await _tts.stop();
    await _tts.speak(t);
  }

  Future<void> _stopAll() async {
    debugPrint('[Stop] pressed');
    await _sttService.stop();
    await _tts.stop();
    if (_micGranted) {
      await _wakeService.start();
    }
  }

  Future<void> _stopTtsOnly() async {
    await _tts.stop();
  }

  String _formatTimestamp(DateTime? time) {
    if (time == null) return '—';
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _cameraStatusText() {
    if (!_cameraGranted) return _cameraMessage;
    final live = _cameraStreaming ? 'ON' : 'OFF';
    final last = _formatTimestamp(_lastFrameAt);
    final err = _cameraError.isEmpty ? '' : '\nОшибка: $_cameraError';
    return 'Live: $live\nLast frame: $last$err';
  }

  String _gptStatusLabel(GptStatus status) {
    switch (status) {
      case GptStatus.loading:
        return 'loading';
      case GptStatus.ok:
        return 'ok';
      case GptStatus.error:
        return 'error';
      case GptStatus.idle:
      default:
        return 'idle';
    }
  }

  @override
  Widget build(BuildContext context) {
    final wakeState = _wakeService.state.value;
    final sttState = _sttService.state.value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Janarym'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_micGranted)
                _InfoCard(
                  title: 'Микрофон',
                  text: _micMessage,
                  tone: _InfoTone.warning,
                )
              else
                _InfoCard(
                  title: 'Микрофон',
                  text: _micMessage,
                  tone: _InfoTone.ok,
                ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Камера Live',
                text: _cameraStatusText(),
                tone: _cameraGranted ? _InfoTone.ok : _InfoTone.warning,
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Voice Console',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Wake: ${wakeState.isListening ? 'ON' : 'OFF'} '
                      '(${wakeState.status.name})',
                    ),
                    Text('Last wake: ${_formatTimestamp(_lastWakeAt)}'),
                    if (wakeState.lastError != null &&
                        wakeState.lastError!.trim().isNotEmpty)
                      Text(
                        'Porcupine error: ${wakeState.lastError}',
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    const SizedBox(height: 10),
                    Text('STT: ${sttState.status.name}'),
                    Text(
                      'Live: ${sttState.liveWords.isEmpty ? '—' : sttState.liveWords}',
                    ),
                    Text(
                      'Final: ${sttState.finalWords.isEmpty ? '—' : sttState.finalWords}',
                    ),
                    if (sttState.lastError != null &&
                        sttState.lastError!.trim().isNotEmpty)
                      Text(
                        'STT error: ${sttState.lastError}',
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text('GPT: ${_gptStatusLabel(_gptStatus)}'),
                        ),
                        TextButton(
                          onPressed: _stopTtsOnly,
                          child: const Text('Stop TTS'),
                        ),
                      ],
                    ),
                    Text(
                      'Last answer: ${_lastAnswer.isEmpty ? '—' : _lastAnswer}',
                    ),
                    if (_gptStatus == GptStatus.error && _gptError.isNotEmpty)
                      Text(
                        'GPT error: $_gptError',
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              _SectionCard(
                title: 'Answer',
                child: Text(
                  _lastAnswer.isEmpty
                      ? 'Ответ появится здесь.'
                      : _lastAnswer,
                  style: const TextStyle(fontSize: 16, height: 1.35),
                ),
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _BigButton(
                      icon: Icons.mic,
                      text: 'Голос',
                      onPressed: () => _runCommandFlow(reason: 'manual'),
                      enabled: !_commandInFlight,
                      semanticLabel: 'Ручной запуск STT команды',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _BigButton(
                      icon: Icons.stop_circle_outlined,
                      text: 'Стоп',
                      onPressed: _stopAll,
                      enabled: true,
                      semanticLabel: 'Остановить STT и TTS',
                    ),
                  ),
                ],
              ),

            ],
          ),
        ),
      ),
    );
  }
}

enum _InfoTone { ok, warning }

class _InfoCard extends StatelessWidget {
  final String title;
  final String text;
  final _InfoTone tone;

  const _InfoCard({
    required this.title,
    required this.text,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final color = tone == _InfoTone.ok
        ? Colors.greenAccent.withOpacity(0.2)
        : Colors.orangeAccent.withOpacity(0.2);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(text),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onPressed;
  final bool enabled;
  final String semanticLabel;

  const _BigButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    required this.enabled,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        height: 56,
        child: FilledButton.icon(
          onPressed: enabled ? onPressed : null,
          icon: Icon(icon),
          label: Text(text, style: const TextStyle(fontSize: 18)),
        ),
      ),
    );
  }
}

class _YuvFrame {
  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  const _YuvFrame({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'y': y,
        'u': u,
        'v': v,
        'yRowStride': yRowStride,
        'uvRowStride': uvRowStride,
        'uvPixelStride': uvPixelStride,
      };
}

Uint8List _convertYuvToJpeg(Map<String, dynamic> args) {
  final width = args['width'] as int;
  final height = args['height'] as int;
  final yPlane = args['y'] as Uint8List;
  final uPlane = args['u'] as Uint8List;
  final vPlane = args['v'] as Uint8List;
  final yRowStride = args['yRowStride'] as int;
  final uvRowStride = args['uvRowStride'] as int;
  final uvPixelStride = args['uvPixelStride'] as int;

  final image = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    final yRow = yRowStride * y;
    final uvRow = uvRowStride * (y >> 1);
    for (int x = 0; x < width; x++) {
      final uvIndex = uvRow + (x >> 1) * uvPixelStride;
      final yp = yPlane[yRow + x];
      final up = uPlane[uvIndex];
      final vp = vPlane[uvIndex];

      int r = (yp + 1.370705 * (vp - 128)).round();
      int g = (yp - 0.337633 * (up - 128) - 0.698001 * (vp - 128)).round();
      int b = (yp + 1.732446 * (up - 128)).round();

      r = r.clamp(0, 255);
      g = g.clamp(0, 255);
      b = b.clamp(0, 255);

      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: 85));
}
