// Runs an integration test under `flutter drive`, which can build it in
// profile mode: the speed checks need real frame times (a debug build's are
// several times slower).
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
