import '../media/audio_policy.dart';

Future<void> waitUntil(
  bool Function() condition,
  String category, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw ProofFailure(category);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
