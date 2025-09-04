import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// ===== Config =====
const inputArb = 'lib/src/l10n/quill_en.arb';
const outputDir = 'lib/src/l10n';
const sourceLocale = 'en';
const googleTranslateApiKey = 'AIzaSyAVA4zzYj72go3r55FdqcMpfXw0Bb01ll8';

bool _isMetaKey(String k) => k.startsWith('@') || k == '@@locale';

final _icuMsgRe = RegExp(
  r'{\s*\w+\s*,\s*(plural|select|selectordinal|number|date|time)\b',
  caseSensitive: false,
);
bool _looksLikeIcu(String s) => _icuMsgRe.hasMatch(s);

final _phRe = RegExp(r'\{(\w+)\}');
String _protect(String s, Map<String, String> mapOut) {
  var i = 0;
  return s.replaceAllMapped(_phRe, (m) {
    final token = '__PH_${i}__';
    mapOut[token] = '{${m.group(1)!}}';
    i++;
    return token;
  });
}
String _restore(String s, Map<String, String> mapIn) {
  var out = s;
  mapIn.forEach((k, v) => out = out.replaceAll(k, v));
  return out;
}

String mapToGoogleTarget(String locale) {
  switch (locale) {
    case 'zh-Hans':
      return 'zh-CN';
    case 'zh-Hant':
      return 'zh-TW';
    case 'nb':
      return 'no';
    case 'pt-BR':
      return 'pt-BR';
    case 'pt-PT':
      return 'pt-PT';
    case 'sr-Latn':
      return 'sr-Latn';
    default:
      return locale;
  }
}

String normalizeLocale(String locale) {
  switch (locale) {
    case 'iw':
      return 'he'; // Hebrew
    case 'in':
      return 'id'; // Indonesian
    case 'ji':
      return 'yi'; // Yiddish
    default:
      return locale;
  }
}

Future<List<String>> fetchSupportedLanguages() async {
  final uri = Uri.parse(
      'https://translation.googleapis.com/language/translate/v2/languages?key=$googleTranslateApiKey&target=$sourceLocale');
  final resp = await http.get(uri);

  if (resp.statusCode != 200) {
    throw Exception('Failed to fetch languages: ${resp.body}');
  }

  final data = json.decode(resp.body) as Map<String, dynamic>;
  final langs = (data['data']['languages'] as List)
      .map((e) => e['language'] as String)
      .toList();

  // Always keep unique + sorted
  final unique = langs.toSet().toList()..sort();
  return unique;
}

Future<List<String>> translateBatch(List<String> texts, String target) async {
  final uri = Uri.parse(
      'https://translation.googleapis.com/language/translate/v2?key=$googleTranslateApiKey');

  final resp = await http.post(
    uri,
    headers: {'Content-Type': 'application/json; charset=utf-8'},
    body: json.encode({
      'q': texts,
      'source': sourceLocale,
      'target': mapToGoogleTarget(target),
      'format': 'text',
    }),
  );

  if (resp.statusCode != 200) {
    throw Exception('Translate error ${resp.statusCode}: ${resp.body}');
  }

  final data = json.decode(resp.body) as Map<String, dynamic>;
  return (data['data']['translations'] as List)
      .map((e) => (e['translatedText'] as String))
      .map(_unescapeHtml)
      .toList();
}

String _unescapeHtml(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&#39;', "'")
    .replaceAll('&quot;', '"')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>');

Future<void> _writeJson(String path, Map<String, dynamic> data) async {
  final enc = const JsonEncoder.withIndent('  ');
  await Directory(File(path).parent.path).create(recursive: true);
  await File(path).writeAsString('${enc.convert(data)}\n');
}

String? _baseFallbackOf(String locale) {
  final parts = locale.split(RegExp('[-_]'));
  return parts.length > 1 ? parts.first : null;
}

Future<void> _ensureBaseFallbackFromVariant(
    String variantLocale, Map<String, dynamic> variantData) async {
  final base = _baseFallbackOf(variantLocale);
  if (base == null) return;

  final normalizedBase = normalizeLocale(base);
  final basePath = '$outputDir/quill_${normalizedBase.replaceAll('-', '_')}.arb';
  final file = File(basePath);

  Map<String, dynamic> baseData = {'@@locale': normalizedBase};
  if (file.existsSync()) {
    baseData = json.decode(await file.readAsString()) as Map<String, dynamic>;
  }

  final hasRealStrings = baseData.keys.any((k) => !_isMetaKey(k));

  if (!hasRealStrings) {
    final seeded = <String, dynamic>{};
    variantData.forEach((k, v) {
      if (!_isMetaKey(k) && v is String) seeded[k] = v;
    });
    seeded['@@locale'] = normalizedBase.replaceAll('-', '_');
    await _writeJson(basePath, seeded);
    stdout.writeln('✓ seeded fallback $basePath from $variantLocale');
  }
}

Future<void> main() async {
  final baseFile = File(inputArb);
  if (!baseFile.existsSync()) {
    stderr.writeln('Missing $inputArb');
    exit(1);
  }
  final base =
  json.decode(await baseFile.readAsString()) as Map<String, dynamic>;

  final enStrings = <String, String>{};
  base.forEach((k, v) {
    if (!_isMetaKey(k) && v is String) enStrings[k] = v;
  });

  final targetLocales = await fetchSupportedLanguages();
  stdout.writeln('Fetched ${targetLocales.length} supported languages');

  for (final locale in targetLocales) {
    if (locale == sourceLocale) continue; // skip EN itself
    try {
      final normalized = normalizeLocale(locale);
      final arbFileName = 'quill_${normalized.replaceAll('-', '_')}.arb';
      final outPath = '$outputDir/$arbFileName';

      Map<String, dynamic> existing = {};
      if (File(outPath).existsSync()) {
        existing = json.decode(await File(outPath).readAsString())
        as Map<String, dynamic>;
      }

      final out = Map<String, dynamic>.from(base)..addAll(existing);
      out['@@locale'] = normalized.replaceAll('-', '_');

      final todoKeys = <String>[];
      final protectedTexts = <String>[];
      final stashes = <Map<String, String>>[];

      enStrings.forEach((key, enValue) {
        final alreadyTranslated =
            out.containsKey(key) && (out[key] is String) && out[key] != enValue;

        if (alreadyTranslated) return;

        if (_looksLikeIcu(enValue)) {
          out[key] = out[key] ?? enValue;
          return;
        }

        final stash = <String, String>{};
        final protected = _protect(enValue, stash);
        todoKeys.add(key);
        protectedTexts.add(protected);
        stashes.add(stash);
      });

      const chunkSize = 100;
      for (var i = 0; i < protectedTexts.length; i += chunkSize) {
        final chunk = protectedTexts.sublist(
            i,
            i + chunkSize > protectedTexts.length
                ? protectedTexts.length
                : i + chunkSize);

        final translated = await translateBatch(chunk, locale);

        for (var j = 0; j < translated.length; j++) {
          final idx = i + j;
          final key = todoKeys[idx];
          final restored = _restore(translated[j], stashes[idx]);
          out[key] = restored;
        }
      }

      await _writeJson(outPath, out);
      stdout.writeln('✓ wrote $outPath');

      await _ensureBaseFallbackFromVariant(locale, out);
    } catch (e) {
      stderr.writeln('✗ $locale failed: $e');
    }
  }

  stdout.writeln('All done. Now run: flutter gen-l10n');
}
