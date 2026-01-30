import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

enum CommandSttStatus { idle, listening, error }

class CommandSttState {
  final CommandSttStatus status;
  final String liveWords;
  final String finalWords;
  final String? lastError;

  const CommandSttState({
    required this.status,
    required this.liveWords,
    required this.finalWords,
    this.lastError,
  });

  bool get isListening => status == CommandSttStatus.listening;
}

class CommandSttService {
  CommandSttService();

  final ValueNotifier<CommandSttState> state = ValueNotifier(
    const CommandSttState(
      status: CommandSttStatus.idle,
      liveWords: '',
      finalWords: '',
    ),
  );

  final stt.SpeechToText _stt = stt.SpeechToText();
  Timer? _timeoutTimer;
  Completer<String?>? _completer;
  bool _finishing = false;
  String? _localeId;

  bool get isListening => state.value.isListening;

  Future<String?> startCommandListening({int durationSeconds = 4}) async {
    if (_completer != null) return _completer!.future;
    _completer = Completer<String?>();
    final completer = _completer!;

    _setState(
      status: CommandSttStatus.listening,
      liveWords: '',
      finalWords: '',
      clearError: true,
    );

    final available = await _stt.initialize(
      onError: _handleError,
      onStatus: _handleStatus,
      debugLogging: kDebugMode,
      options: [
        stt.SpeechToText.androidIntentLookup,
        stt.SpeechToText.androidAlwaysUseStop,
        stt.SpeechToText.androidNoBluetooth,
      ],
    );

    if (!available) {
      _setError('STT недоступен на этом устройстве');
      _complete(null);
      return completer.future;
    }

    await _ensureLocale();

    try {
      await _stt.listen(
        localeId: _localeId ?? 'ru_RU',
        listenMode: stt.ListenMode.confirmation,
        partialResults: true,
        listenFor: Duration(seconds: durationSeconds),
        pauseFor: const Duration(seconds: 2),
        onResult: _handleResult,
      );

      _timeoutTimer = Timer(Duration(seconds: durationSeconds + 1), () async {
        await stop();
      });
    } catch (e) {
      _setError('STT start failed: $e');
      await stop();
    }

    return completer.future;
  }

  Future<void> stop() async {
    await _finish();
  }

  Future<void> dispose() async {
    await _finish();
  }

  void _handleResult(SpeechRecognitionResult result) {
    if (result.recognizedWords.isEmpty) return;
    if (result.finalResult) {
      _setState(finalWords: result.recognizedWords, liveWords: '');
      stop();
    } else {
      _setState(liveWords: result.recognizedWords);
    }
  }

  void _handleError(SpeechRecognitionError error) {
    _setError('STT error: ${error.errorMsg}');
  }

  void _handleStatus(String status) {
    if (status == 'done' || status == 'notListening') {
      stop();
    }
  }

  Future<void> _ensureLocale() async {
    if (_localeId != null) return;
    try {
      final locales = await _stt.locales();
      final ruLocale = locales.firstWhere(
        (l) => l.localeId.toLowerCase().startsWith('ru'),
        orElse: () => locales.isNotEmpty ? locales.first : stt.LocaleName('ru_RU', 'Russian'),
      );
      _localeId = ruLocale.localeId;
    } catch (_) {
      try {
        final sys = await _stt.systemLocale();
        _localeId = sys?.localeId ?? 'ru_RU';
      } catch (_) {
        _localeId = 'ru_RU';
      }
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;

    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    try {
      await _stt.stop();
    } catch (_) {}

    if (state.value.finalWords.isEmpty && state.value.liveWords.isNotEmpty) {
      _setState(finalWords: state.value.liveWords, liveWords: '');
    }

    _setState(status: CommandSttStatus.idle, liveWords: '');
    _complete(state.value.finalWords.isEmpty ? null : state.value.finalWords);

    _finishing = false;
  }

  void _setError(String message) {
    _setState(status: CommandSttStatus.error, lastError: message);
  }

  void _setState({
    CommandSttStatus? status,
    String? liveWords,
    String? finalWords,
    String? lastError,
    bool clearError = false,
  }) {
    final current = state.value;
    state.value = CommandSttState(
      status: status ?? current.status,
      liveWords: liveWords ?? current.liveWords,
      finalWords: finalWords ?? current.finalWords,
      lastError: clearError ? null : (lastError ?? current.lastError),
    );
  }

  void _complete(String? text) {
    if (_completer == null) return;
    final completer = _completer!;
    _completer = null;
    if (!completer.isCompleted) {
      completer.complete(text);
    }
  }
}
