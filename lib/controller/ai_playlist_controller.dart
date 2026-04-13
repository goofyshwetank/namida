import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:namida/class/track.dart';
import 'package:namida/core/constants.dart';

class AIPlaylistResult {
  final String playlistName;
  final List<Track> tracks;
  final List<String> moods;

  const AIPlaylistResult({
    required this.playlistName,
    required this.tracks,
    required this.moods,
  });
}

class AIPlaylistController {
  static AIPlaylistController get inst => _instance;
  static final AIPlaylistController _instance = AIPlaylistController._internal();
  AIPlaylistController._internal();

  static const _endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent';

  Future<AIPlaylistResult> generatePlaylistForMood({
    required String apiKey,
    required String moodPrompt,
    int maxTracks = 30,
  }) async {
    final trimmedKey = apiKey.trim();
    final trimmedMood = moodPrompt.trim();
    if (trimmedKey.isEmpty) throw Exception('Gemini API key is empty');
    if (trimmedMood.isEmpty) throw Exception('Mood prompt is empty');

    final tracks = allTracksInLibrary.toList();
    if (tracks.isEmpty) {
      throw Exception('Library is empty');
    }

    final availableMoods = tracks
        .expand((e) => e.effectiveMoods)
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final availableGenres = tracks
        .expand((e) => e.genresList)
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final payload = {
      'contents': [
        {
          'parts': [
            {
              'text': '''You are helping generate local music playlists.
User mood: "$trimmedMood"

Available moods in library: ${availableMoods.take(120).join(', ')}
Available genres in library: ${availableGenres.take(120).join(', ')}

Return strict JSON only with no markdown and no extra text:
{
  "playlist_name": "short playlist name",
  "moods": ["mood1", "mood2"],
  "genres": ["genre1", "genre2"],
  "include_terms": ["keyword1", "keyword2"]
}

Rules:
- Prefer moods/genres from the available lists.
- Keep each list 2 to 8 elements.
- Keep playlist name under 40 chars.''',
            },
          ],
        },
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'temperature': 0.5,
      },
    };

    final client = HttpClient();
    final request = await client.postUrl(Uri.parse('$_endpoint?key=$trimmedKey'));
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    client.close();

    if (response.statusCode < 200 || response.statusCode > 299) {
      throw Exception('Gemini request failed (${response.statusCode})');
    }

    final parsed = jsonDecode(body);
    final textResponse = _extractModelText(parsed);
    final json = _extractModelJson(textResponse);

    final modelMoods = _extractStringList(json['moods']);
    final modelGenres = _extractStringList(json['genres']);
    final includeTerms = _extractStringList(json['include_terms']);
    final playlistName = (json['playlist_name']?.toString().trim().isNotEmpty == true)
        ? json['playlist_name'].toString().trim()
        : 'AI Mood Playlist';

    final selected = _pickTracks(
      tracks: tracks,
      moods: modelMoods,
      genres: modelGenres,
      includeTerms: includeTerms,
      maxTracks: maxTracks,
    );

    return AIPlaylistResult(
      playlistName: playlistName,
      tracks: selected,
      moods: modelMoods,
    );
  }

  String _extractModelText(dynamic responseJson) {
    if (responseJson is! Map) return '{}';
    final candidates = responseJson['candidates'];
    if (candidates is! List || candidates.isEmpty) return '{}';
    final first = candidates.first;
    if (first is! Map) return '{}';
    final content = first['content'];
    if (content is! Map) return '{}';
    final parts = content['parts'];
    if (parts is! List || parts.isEmpty) return '{}';
    final part = parts.first;
    if (part is! Map) return '{}';
    return part['text']?.toString() ?? '{}';
  }

  Map<String, dynamic> _extractModelJson(String textResponse) {
    final cleaned = textResponse.trim().replaceAll('```json', '').replaceAll('```', '').trim();
    final decoded = jsonDecode(cleaned);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.map((k, v) => MapEntry(k.toString(), v));
    return {};
  }

  List<String> _extractStringList(dynamic value) {
    if (value is! List) return [];
    return value.map((e) => e.toString().trim().toLowerCase()).where((e) => e.isNotEmpty).toSet().toList();
  }

  List<Track> _pickTracks({
    required List<Track> tracks,
    required List<String> moods,
    required List<String> genres,
    required List<String> includeTerms,
    required int maxTracks,
  }) {
    final random = Random();
    final scored = <MapEntry<Track, int>>[];

    for (final tr in tracks) {
      final trMoods = tr.effectiveMoods.map((e) => e.toLowerCase()).toList();
      final trGenres = tr.genresList.map((e) => e.toLowerCase()).toList();
      final searchable = '${tr.title.toLowerCase()} ${tr.originalArtist.toLowerCase()} ${tr.originalAlbum.toLowerCase()} ${tr.tagsList.join(' ').toLowerCase()}';

      int score = 0;
      if (moods.any((m) => trMoods.any((tm) => tm.contains(m) || m.contains(tm)))) score += 5;
      if (genres.any((g) => trGenres.any((tg) => tg.contains(g) || g.contains(tg)))) score += 3;
      if (includeTerms.any((term) => searchable.contains(term))) score += 2;
      if (score > 0) {
        scored.add(MapEntry(tr, score));
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    final picked = <Track>[];
    for (final entry in scored.take(maxTracks * 2)) {
      if (picked.length >= maxTracks) break;
      picked.add(entry.key);
    }

    if (picked.isEmpty) {
      final fallback = tracks.toList()..shuffle(random);
      final fallbackCount = max(1, min(maxTracks, tracks.length));
      return fallback.take(fallbackCount).toList();
    }

    return picked.toList()..shuffle(random);
  }
}
