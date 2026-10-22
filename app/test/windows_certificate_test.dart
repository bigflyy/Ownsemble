import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ownsemble/media/windows_certificate.dart';

void main() {
  test(
    'Windows SSL policy rejects a generated untrusted certificate',
    () async {
      final pem = await File('test/fixtures/generated-tls-cert.pem')
          .readAsString();
      expect(
        await verifyWindowsCertificate(pem, 'generated-ownsemble.invalid'),
        isNot(0),
      );
      expect(
        await verifyWindowsCertificate(pem, 'different.invalid'),
        isNot(0),
      );
    },
    skip: !Platform.isWindows,
  );
}
