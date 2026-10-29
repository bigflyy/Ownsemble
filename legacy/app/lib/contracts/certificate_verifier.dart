import 'dart:io';

/// Extra trust is optional; the ordinary HttpClient TLS verification stays on.
abstract interface class CertificateVerifier {
  bool accept(X509Certificate certificate, String host, int port);
  Future<bool> verify(String host);
}

class StrictCertificateVerifier implements CertificateVerifier {
  const StrictCertificateVerifier();
  @override
  bool accept(X509Certificate certificate, String host, int port) => false;
  @override
  Future<bool> verify(String host) async => false;
}

CertificateVerifier strictCertificateVerifier() =>
    const StrictCertificateVerifier();
