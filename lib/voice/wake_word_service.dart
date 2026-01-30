import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';

enum WakeWordStatus { armed, listening, error }

class WakeWordState {
  final WakeWordStatus status;
  final String? lastError;
  final String keywordMode;
  final String keywordLabel;

  const WakeWordState({
    required this.status,
    required this.keywordMode,
    required this.keywordLabel,
    this.lastError,
  });

  bool get isListening => status == WakeWordStatus.listening;
}

class WakeWordService {
  WakeWordService({required this.onWakeWordDetected});

  final VoidCallback onWakeWordDetected;

  final ValueNotifier<WakeWordState> state = ValueNotifier(
    const WakeWordState(
      status: WakeWordStatus.armed,
      keywordMode: 'jarvis',
      keywordLabel: 'jarvis',
    ),
  );

  PorcupineManager? _manager;
  bool _initializing = false;

  Future<void> start() async {
    if (_initializing) return;
    if (_manager == null) {
      await _initManager();
    }
    if (_manager == null) return;

    try {
      await _manager!.start();
      _setState(status: WakeWordStatus.listening);
    } on PorcupineException catch (e) {
      _setError(e.message ?? 'Porcupine error');
    } catch (e) {
      _setError('Porcupine start failed: $e');
    }
  }

  Future<void> stop() async {
    if (_manager == null) return;
    try {
      await _manager!.stop();
      _setState(status: WakeWordStatus.armed);
    } catch (e) {
      _setError('Porcupine stop failed: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _manager?.delete();
    } catch (_) {}
  }

  Future<void> _initManager() async {
    if (_initializing) return;
    _initializing = true;
    try {
      final accessKey = (dotenv.env['PICOVOICE_ACCESS_KEY'] ?? '').trim();
      if (accessKey.isEmpty) {
        _setError('PICOVOICE_ACCESS_KEY не задан (проверь .env)');
        return;
      }

      final mode = (dotenv.env['KEYWORD_MODE'] ?? 'jarvis').toLowerCase().trim();
      if (mode == 'custom') {
        const assetPath = 'assets/keywords/janarym.ppn';
        final hasCustom = await _assetExists(assetPath);
        if (hasCustom) {
          _manager = await PorcupineManager.fromKeywordPaths(
            accessKey,
            [assetPath],
            _onWakeWord,
            errorCallback: _onError,
          );
          _setState(
            status: WakeWordStatus.armed,
            keywordMode: 'custom',
            keywordLabel: 'janarym',
            clearError: true,
          );
          return;
        } else {
          _setError(
            'Custom keyword not found: $assetPath. Fallback to jarvis.',
          );
        }
      }

      _manager = await PorcupineManager.fromBuiltInKeywords(
        accessKey,
        [BuiltInKeyword.JARVIS],
        _onWakeWord,
        errorCallback: _onError,
      );
      _setState(
        status: WakeWordStatus.armed,
        keywordMode: 'jarvis',
        keywordLabel: 'jarvis',
        clearError: true,
      );
    } on PorcupineException catch (e) {
      _setError(e.message ?? 'Porcupine error');
    } catch (e) {
      _setError('Porcupine init failed: $e');
    } finally {
      _initializing = false;
    }
  }

  Future<bool> _assetExists(String assetPath) async {
    try {
      await rootBundle.load(assetPath);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onWakeWord(int keywordIndex) {
    onWakeWordDetected();
  }

  void _onError(PorcupineException error) {
    _setError(error.message ?? 'Porcupine error');
  }

  void _setError(String? message) {
    _setState(
      status: WakeWordStatus.error,
      lastError: message ?? 'Porcupine error',
    );
  }

  void _setState({
    required WakeWordStatus status,
    String? keywordMode,
    String? keywordLabel,
    String? lastError,
    bool clearError = false,
  }) {
    final current = state.value;
    state.value = WakeWordState(
      status: status,
      keywordMode: keywordMode ?? current.keywordMode,
      keywordLabel: keywordLabel ?? current.keywordLabel,
      lastError: clearError ? null : (lastError ?? current.lastError),
    );
  }
}
