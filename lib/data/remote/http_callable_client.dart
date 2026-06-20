import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

/// Calls Firebase HTTPS callable functions over HTTP.
///
/// Used on desktop platforms where the [cloud_functions] plugin is unavailable.
class HttpCallableClient {
  HttpCallableClient({
    required this.projectId,
    this.region = 'us-central1',
    FirebaseAuth? auth,
    http.Client? httpClient,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _http = httpClient ?? http.Client();

  final String projectId;
  final String region;
  final FirebaseAuth _auth;
  final http.Client _http;

  Uri _uriFor(String name) => Uri.parse(
    'https://$region-$projectId.cloudfunctions.net/$name',
  );

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> data,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Sign in required.');
    }

    final token = await user.getIdToken();
    final response = await _http.post(
      _uriFor(name),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'data': data}),
    );

    final body = response.body.trim();
    if (body.isEmpty) {
      throw Exception('Cloud function "$name" returned an empty response.');
    }
    if (body.startsWith('<')) {
      throw Exception(
        'Cloud function "$name" is not available. Run '
        '`firebase deploy --only functions` from the project root, then try again.',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw Exception(
        'Cloud function "$name" returned an invalid response '
        '(${response.statusCode}).',
      );
    }

    if (decoded is Map && decoded['error'] != null) {
      final error = Map<String, dynamic>.from(decoded['error'] as Map);
      throw Exception(error['message'] as String? ?? 'Cloud function failed.');
    }

    if (response.statusCode >= 400) {
      throw Exception('Cloud function failed (${response.statusCode}).');
    }

    if (decoded is! Map || decoded['result'] is! Map) {
      throw Exception('Unexpected cloud function response.');
    }

    return Map<String, dynamic>.from(decoded['result'] as Map);
  }
}
