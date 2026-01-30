class CommandDecision {
  final String cleanedText;
  final bool isDescribe;
  final bool isRepeat;
  final String? directionRu;
  const CommandDecision({
    required this.cleanedText,
    required this.isDescribe,
    required this.isRepeat,
    this.directionRu,
  });
}

class CommandRouter {
  static const List<String> wakeWordVariants = [
    'жанарым',
    'жанаром',
    'жанарам',
    'жанрам',
    'шмарым',
    'janarym',
    'zhanarym',
  ];

  static const List<String> describeTriggers = [
    'опиши',
    'что вокруг',
    'что впереди',
    'справа',
    'слева',
    'сзади',
    'позади',
    'вокруг',
  ];

  static const List<String> repeatTriggers = [
    'повтори',
    'еще раз',
    'ещё раз',
    'повтор',
  ];

  static const String blindSystemPrompt =
      'Ты ассистент для незрячего пользователя. '
      'Отвечай коротко и по делу. '
      'Не задавай уточняющих вопросов. '
      'Если не хватает данных — честно скажи что без камеры не видишь и предложи включить камеру позже.';

  static const String visionSystemPrompt =
      'Ты ассистент для незрячего пользователя. '
      'Опиши изображение коротко и по делу. '
      'Не задавай уточняющих вопросов. '
      'Если что-то не видно, честно скажи об этом.';

  String normalize(String text) {
    var t = text.toLowerCase().replaceAll('ё', 'е');
    t = t.replaceAll(RegExp(r'[\n\r]'), ' ');
    t = t.replaceAll(RegExp(r'[.,!?;:"()\[\]{}]'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  String stripWakeWords(String text) {
    var t = text;
    for (final w in wakeWordVariants) {
      t = t.replaceAll(RegExp(r'\b' + RegExp.escape(w) + r'\b'), ' ');
    }
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  CommandDecision route(String text) {
    final normalized = normalize(text);
    final cleaned = stripWakeWords(normalized);
    final target = cleaned.isEmpty ? normalized : cleaned;
    final direction = _directionFromText(target);
    final isRepeat = repeatTriggers.any(target.contains);
    final isDescribe = direction != null || describeTriggers.any(target.contains);
    return CommandDecision(
      cleanedText: target,
      isDescribe: isDescribe,
      isRepeat: isRepeat,
      directionRu: direction,
    );
  }

  String? _directionFromText(String text) {
    if (text.contains('что впереди') || text.contains('впереди') || text.contains('спереди')) {
      return 'впереди';
    }
    if (text.contains('что слева') || text.contains('слева')) {
      return 'слева';
    }
    if (text.contains('что справа') || text.contains('справа')) {
      return 'справа';
    }
    if (text.contains('что сзади') || text.contains('сзади') || text.contains('позади')) {
      return 'сзади';
    }
    if (text.contains('что вокруг') || text.contains('вокруг')) {
      return 'вокруг';
    }
    return null;
  }
}
