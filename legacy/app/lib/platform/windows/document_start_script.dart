import 'dart:convert';

import '../../media/audio_policy.dart';

/// Wait for native script registration before allowing the next navigation.
/// The protocol reply is checked locally; no page data or script is logged.
Future<void> registerWindowsDocumentStartScript(
  String source, {
  required Future<dynamic> Function(String, Map<String, dynamic>) callProtocol,
}) async {
  try {
    // Await the registration acknowledgement, not the plugin's queued-call flag.
    final nativeReply = await callProtocol(
      'Page.addScriptToEvaluateOnNewDocument',
      {'source': source},
    ).timeout(const Duration(seconds: 10));
    // Accept the map and JSON reply formats returned by supported plugin APIs.
    final acknowledgement = nativeReply is String
        ? jsonDecode(nativeReply)
        : nativeReply;
    // Reject an absent registration rather than navigating without its script.
    if (acknowledgement is! Map ||
        acknowledgement['identifier'] is! String ||
        (acknowledgement['identifier'] as String).isEmpty) {
      throw const ProofFailure('browser_document_start_failed');
    }
  } catch (_) {
    // Keep native errors and script contents out of the shared diagnostic path.
    throw const ProofFailure('browser_document_start_failed');
  }
}
