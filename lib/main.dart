import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

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

enum CircleState { idle, wake, listening, thinking, speaking, end }

class JanarymHome extends StatefulWidget {
  const JanarymHome({super.key});

  @override
  State<JanarymHome> createState() => _JanarymHomeState();
}

class _JanarymHomeState extends State<JanarymHome>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _sfxPlayer = AudioPlayer();
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
  bool _followUpActive = false;
  bool _wakeHandling = false;
  bool _thinkingSoundPlayed = false;
  bool _vibrationAvailable = false;
  bool _isSpeaking = false;
  int _requestId = 0;
  late final AnimationController _circleController;
  late final Animation<double> _circlePulse;
  CircleState _circleState = CircleState.idle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _circleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _circlePulse = Tween<double>(begin: 0.95, end: 1.15).animate(
      CurvedAnimation(parent: _circleController, curve: Curves.easeInOutQuad),
    );
    _sttService = CommandSttService();
    _wakeService = WakeWordService(onWakeWordDetected: _handleWakeDetected);
    _sttService.state.addListener(_handleSttStateChange);
    _wakeService.state.addListener(_handleWakeStateChange);
    _initTts();
    _initVibration();
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
    _sfxPlayer.dispose();
    _tts.stop();
    _circleController.dispose();
    super.dispose();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('ru-RU');
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _initVibration() async {
    try {
      final hasVibrator = await Vibration.hasVibrator();
      _vibrationAvailable = hasVibrator ?? false;
    } catch (_) {
      _vibrationAvailable = false;
    }
  }

  Future<void> _vibrateStart() async {
    if (!_vibrationAvailable) return;
    // мягкий короткий двойной импульс
    try {
      await Vibration.vibrate(pattern: [0, 40, 60, 40], amplitude: 64);
    } catch (_) {}
  }

  Future<void> _vibrateThinking() async {
    if (!_vibrationAvailable) return;
    // мягкий одиночный импульс
    try {
      await Vibration.vibrate(duration: 35, amplitude: 50);
    } catch (_) {}
  }

  Future<void> _vibrateEnd() async {
    if (!_vibrationAvailable) return;
    // мягкий “затухающий” двойной импульс
    try {
      await Vibration.vibrate(pattern: [0, 60, 80, 30], amplitude: 40);
    } catch (_) {}
  }

  Future<void> _playStartCue() async {
    try {
      await _sfxPlayer.stop();
      await _sfxPlayer.play(AssetSource('sounds/start.wav'), volume: 0.7);
    } catch (_) {}
  }

  Future<void> _playEndCue() async {
    try {
      await _sfxPlayer.stop();
      await _sfxPlayer.play(AssetSource('sounds/end.wav'), volume: 0.7);
    } catch (_) {}
  }

  Future<void> _playThinkingCue() async {
    try {
      await _sfxPlayer.stop();
      await _sfxPlayer.play(AssetSource('sounds/thinking.wav'), volume: 0.6);
    } catch (_) {}
  }

  void _setCircleState(CircleState state) {
    if (_circleState == state) return;
    setState(() => _circleState = state);
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
    final canBargeIn =
        _isSpeaking || _gptStatus == GptStatus.loading || _followUpActive;
    if (_wakeHandling && !canBargeIn) return;
    _wakeHandling = true;
    debugPrint('[Wake] detected');
    setState(() => _lastWakeAt = DateTime.now());
    _requestId++;
    await _tts.stop();
    await _playStartCue();
    await _vibrateStart();
    if (_followUpActive) {
      await _sttService.stop();
      _followUpActive = false;
    }
    _commandInFlight = false;
    _setCircleState(CircleState.wake);
    await _runCommandFlow(reason: 'wake');
    _wakeHandling = false;
  }

  Future<void> _runCommandFlow({required String reason}) async {
    if (_commandInFlight) return;
    if (!_micGranted) return;

    _commandInFlight = true;
    final localRequestId = _requestId;
    try {
      await _wakeService.stop();
      debugPrint('[STT] start ($reason)');
      _setCircleState(CircleState.listening);

      final text = await _sttService.startCommandListening(
        durationSeconds: 5,
      );

      // Restart wake-word immediately after STT to allow barge-in
      await _wakeService.start();

      if (localRequestId != _requestId) return;
      final cleaned = (text ?? '').trim();
      if (cleaned.isNotEmpty) {
        await _handleUserText(cleaned);
      } else {
        await _playEndCue();
        await _vibrateEnd();
        _setCircleState(CircleState.end);
      }
    } finally {
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
    final describeText = decision.directionRu == null
        ? userText
        : 'Опиши что ${decision.directionRu}';
    await _describeWithVision(describeText);
  }

  Future<void> _askGpt(String text, {String? systemPrompt}) async {
    setState(() {
      _gptStatus = GptStatus.loading;
      _gptError = '';
    });
    debugPrint('[GPT] start');
    final localRequestId = _requestId;
    if (!_thinkingSoundPlayed) {
      _thinkingSoundPlayed = true;
      await _playThinkingCue();
      await _vibrateThinking();
    }
    _setCircleState(CircleState.thinking);
    await Future.delayed(const Duration(milliseconds: 450));

    try {
      final answer = await _openAi.askTextOnly(
        text,
        systemPrompt: systemPrompt,
      );
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.ok;
        _lastAnswer = answer;
      });
      debugPrint('[GPT] ok');
    _setCircleState(CircleState.speaking);
      await _speak(answer);
      await _startFollowUpWindow();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      debugPrint('[GPT] error: $e');
    }
    _thinkingSoundPlayed = false;
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
    final localRequestId = _requestId;
    if (!_thinkingSoundPlayed) {
      _thinkingSoundPlayed = true;
      await _playThinkingCue();
      await _vibrateThinking();
    }

    try {
      final answer = await _openAi.askWithImage(
        text,
        imageBytes,
        systemPrompt: systemPrompt,
      );
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.ok;
        _lastAnswer = answer;
      });
      debugPrint('[GPT] vision ok');
      _setCircleState(CircleState.speaking);
      await _speak(answer);
      await _startFollowUpWindow();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      debugPrint('[GPT] vision error: $e');
    }
    _thinkingSoundPlayed = false;
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

  bool _isNegativeResponse(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return false;
    return t == 'нет' ||
        t.startsWith('нет ') ||
        t.contains('не нужно') ||
        t.contains('не надо') ||
        t.contains('спасибо') ||
        t.contains('не хочу');
  }

  Future<void> _startFollowUpWindow() async {
    if (_followUpActive) return;
    if (!_micGranted) return;
    _followUpActive = true;
    final localRequestId = _requestId;

    try {
      await _playStartCue();
      await _vibrateStart();
      await _speak('Нужно еще что-то?');
      debugPrint('[STT] follow-up start');
      final text = await _sttService.startCommandListening(durationSeconds: 5);
      final cleaned = (text ?? '').trim();
      if (localRequestId != _requestId) return;
      if (cleaned.isNotEmpty) {
        if (_isNegativeResponse(cleaned)) {
          await _playEndCue();
          await _vibrateEnd();
        } else {
          await _handleUserText(cleaned);
        }
      } else {
        await _playEndCue();
        await _vibrateEnd();
      }
    } finally {
      _followUpActive = false;
    }
  }

  Future<void> _speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    debugPrint('[TTS] speak');
    _isSpeaking = true;
    await _tts.stop();
    await _tts.speak(t);
    _isSpeaking = false;
  }

  Future<void> _stopAll() async {
    debugPrint('[Stop] pressed');
    await _sttService.stop();
    await _tts.stop();
    _followUpActive = false;
    await _playEndCue();
    await _vibrateEnd();
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

  String _circleLabel() {
    switch (_circleState) {
      case CircleState.wake:
        return 'Жду команду';
      case CircleState.listening:
        return 'Слушаю';
      case CircleState.thinking:
        return 'Думаю';
      case CircleState.speaking:
        return 'Говорю';
      case CircleState.end:
        return 'Готов к работе';
      case CircleState.idle:
      default:
        return 'Готов к работе';
    }
  }

  _AssistantOrbTheme _orbThemeForState(CircleState state) {
    switch (state) {
      case CircleState.wake:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFFE0E7FF), Color(0xFFD0D4FF), Color(0xFF94A3B8)],
          glow: Color(0xFF94A3B8),
          inner: Color(0xFF0F172A),
          accent: Color(0xFF94A3B8),
          pulseFactor: 0.5,
        );
      case CircleState.listening:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFFFDE68A), Color(0xFFF97316), Color(0xFFEA580C)],
          glow: Color(0xFFFBBF24),
          inner: Color(0xFF2B1B0F),
          accent: Color(0xFFF59E0B),
          pulseFactor: 0.9,
        );
      case CircleState.thinking:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFF8B5CF6), Color(0xFF7C3AED), Color(0xFF6D28D9)],
          glow: Color(0xFFAEA0FF),
          inner: Color(0xFF0C0F2C),
          accent: Color(0xFF8B5CF6),
          pulseFactor: 0.75,
        );
      case CircleState.speaking:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFF10B981), Color(0xFF059669), Color(0xFF047857)],
          glow: Color(0xFF34D399),
          inner: Color(0xFF042B1C),
          accent: Color(0xFF34D399),
          pulseFactor: 0.7,
        );
      case CircleState.end:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFF1E293B), Color(0xFF0F172A), Color(0xFF020617)],
          glow: Color(0xFF64748B),
          inner: Color(0xFF080C16),
          accent: Color(0xFF94A3B8),
          pulseFactor: 0.5,
        );
      case CircleState.idle:
      default:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFF1E293B), Color(0xFF0F172A), Color(0xFF020617)],
          glow: Color(0xFF475569),
          inner: Color(0xFF080C16),
          accent: Color(0xFF94A3B8),
          pulseFactor: 0.35,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = _orbThemeForState(_circleState);
    final statusText = _circleState == CircleState.listening
        ? 'Слушаю'
        : (_circleState == CircleState.thinking
            ? 'Думаю'
            : 'Готов к команде');

    return Scaffold(
      backgroundColor: const Color(0xFF020617),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF020617), Color(0xFF09021A), Color(0xFF140230)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  statusText,
                  style: const TextStyle(
                    color: Color(0xFFD9298F),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                if (_followUpActive)
                  Text(
                    'Жду вашего «же»...',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 14,
                    ),
                  ),
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: () => _runCommandFlow(reason: 'manual'),
                  child: AnimatedBuilder(
                    animation: _circlePulse,
                    builder: (context, child) {
                      return Transform.scale(scale: _circlePulse.value, child: child);
                    },
                    child: _AssistantOrb(
                      state: _circleState,
                      label: _circleLabel(),
                      theme: theme,
                    ),
                  ),
                ),
              ],
            ),
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

class _AssistantOrbTheme {
  final List<Color> gradient;
  final Color glow;
  final Color inner;
  final Color accent;
  final double pulseFactor;

  const _AssistantOrbTheme({
    required this.gradient,
    required this.glow,
    required this.inner,
    required this.accent,
    required this.pulseFactor,
  });
}

class _AssistantOrb extends StatelessWidget {
  final CircleState state;
  final String label;
  final _AssistantOrbTheme theme;

  const _AssistantOrb({
    required this.state,
    required this.label,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      height: 210,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 210,
            height: 210,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: theme.gradient,
                center: const Alignment(-0.3, -0.4),
                radius: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.glow.withOpacity(0.5),
                  blurRadius: 45,
                  spreadRadius: 10,
                ),
              ],
            ),
          ),
          Container(
            width: 164,
            height: 164,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.inner,
            ),
            child: Center(
              child: ClipOval(
                child: Image.asset(
                  'icon.png',
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          if (state == CircleState.listening)
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: theme.accent.withOpacity(0.8), width: 3),
              ),
            ),
          if (state == CircleState.thinking)
            SizedBox(
              width: 140,
              height: 140,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                valueColor: AlwaysStoppedAnimation<Color>(theme.accent),
              ),
            ),
        ],
      ),
    );
  }
}
