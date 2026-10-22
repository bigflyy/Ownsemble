// All callbacks stay inside the provider boundary. No page/account data is
// returned; the ordering controls which document receives the extraction guard.
Future<void> prepareLibraryDocument({
  required bool fromTop,
  required Future<void> Function() requireMusicRoute,
  required Future<void> Function() reload,
  required Future<void> Function() requirePersonal,
  required Future<void> Function() install,
  required Future<void> Function() reset,
}) async {
  if (fromTop) {
    await requireMusicRoute();
    await reload();
  }
  await requirePersonal();
  await install();
  if (fromTop) await reset();
}
