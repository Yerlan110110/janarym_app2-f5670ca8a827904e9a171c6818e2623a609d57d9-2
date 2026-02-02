import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class OpenAiClient {
  OpenAiClient({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  static const String _defaultModel = 'gpt-4.1-mini';

  final http.Client _httpClient;

  Future<String> askTextOnly(String userText, {String? systemPrompt}) async {
    final apiKey = (dotenv.env['OPENAI_API_KEY'] ?? '').trim();
    if (apiKey.isEmpty) {
      throw Exception('OPENAI_API_KEY не задан (проверь .env)');
    }

    final model = (dotenv.env['OPENAI_MODEL'] ?? _defaultModel).trim();
    final input = <Map<String, dynamic>>[];

    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      input.add({
        'role': 'system',
        'content': [
          {'type': 'input_text', 'text': systemPrompt.trim()},
        ],
      });
    }

    input.add({
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': userText.trim()},
      ],
    });

    final body = {
      'model': model,
      'input': input,
      'max_output_tokens': 350,
    };

    final res = await _httpClient.post(
      Uri.parse('https://api.openai.com/v1/responses'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('OpenAI HTTP ${res.statusCode}: ${res.body}');
    }

    return _extractText(jsonDecode(res.body));
  }

  Future<String> askWithImage(
    String userText,
    Uint8List imageBytes, {
    String? systemPrompt,
  }) async {
    final apiKey = (dotenv.env['OPENAI_API_KEY'] ?? '').trim();
    if (apiKey.isEmpty) {
      throw Exception('OPENAI_API_KEY не задан (проверь .env)');
    }
    if (imageBytes.isEmpty) {
      throw Exception('Пустой кадр изображения.');
    }

    final model = (dotenv.env['OPENAI_VISION_MODEL'] ??
            dotenv.env['OPENAI_MODEL'] ??
            _defaultModel)
        .trim();
    final input = <Map<String, dynamic>>[];

    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      input.add({
        'role': 'system',
        'content': [
          {'type': 'input_text', 'text': systemPrompt.trim()},
        ],
      });
    }

    final base64Image = base64Encode(imageBytes);
    input.add({
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': userText.trim()},
        {
          'type': 'input_image',
          'image_url': 'data:image/jpeg;base64,$base64Image',
        },
      ],
    });

    final body = {
      'model': model,
      'input': input,
      'max_output_tokens': 350,
    };

    final res = await _httpClient.post(
      Uri.parse('https://api.openai.com/v1/responses'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('OpenAI HTTP ${res.statusCode}: ${res.body}');
    }

    return _extractText(jsonDecode(res.body));
  }

  String _extractText(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      final outputText = decoded['output_text'];
      if (outputText is String && outputText.trim().isNotEmpty) {
        return outputText.trim();
      }

      final output = decoded['output'];
      if (output is List) {
        final buffer = StringBuffer();
        for (final item in output) {
          if (item is Map<String, dynamic>) {
            final content = item['content'];
            if (content is List) {
              for (final c in content) {
                if (c is Map<String, dynamic> &&
                    c['type'] == 'output_text' &&
                    c['text'] is String) {
                  buffer.writeln(c['text']);
                }
              }
            }
          }
        }
        final t = buffer.toString().trim();
        if (t.isNotEmpty) return t;
      }
    }

    return 'Не удалось извлечь текст ответа.';
  }

  void dispose() {
    _httpClient.close();
  }
}
