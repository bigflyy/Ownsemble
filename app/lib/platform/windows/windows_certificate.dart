import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../../contracts/certificate_verifier.dart';

// Windows can build an issuer chain using its intermediate cache/AIA, whereas
// Dart's Mozilla roots alone may reject a CDN's incomplete served chain. Never
// accept a failed certificate without a successful Windows SSL policy check.
class WindowsCertificateVerifier implements CertificateVerifier {
  final _rejected = <String, X509Certificate>{};
  final _verified = <String, ({String digest, DateTime until})>{};
  final _pending = <String, Future<bool>>{};
  @override
  bool accept(X509Certificate certificate, String host, int port) {
    if (!Platform.isWindows || port != 443) return false;
    final digest = sha256.convert(utf8.encode(certificate.pem)).toString();
    final known = _verified[host];
    if (known != null &&
        known.digest == digest &&
        DateTime.now().isBefore(known.until)) {
      return true;
    }
    _rejected[host] = certificate;
    return false;
  }

  @override
  Future<bool> verify(String host) async {
    if (!Platform.isWindows) return false;
    final certificate = _rejected[host];
    if (certificate == null) return false;
    final digest = sha256.convert(utf8.encode(certificate.pem)).toString();
    final key = '$host/$digest';
    return _pending.putIfAbsent(key, () async {
      try {
        final code = await verifyWindowsCertificate(
          certificate.pem,
          host,
        ).timeout(const Duration(seconds: 5));
        if (code != 0) return false;
        final until = DateTime.now().add(const Duration(minutes: 5));
        _verified[host] = (
          digest: digest,
          until: until.isBefore(certificate.endValidity)
              ? until
              : certificate.endValidity,
        );
        return true;
      } catch (_) {
        return false;
      }
    });
  }
}

Future<int> verifyWindowsCertificate(String pem, String host) =>
    Isolate.run(() => _verify((pem, host)));

final class _Usage extends Struct {
  @Uint32()
  external int count;
  external Pointer<Pointer<Utf8>> identifiers;
}

final class _UsageMatch extends Struct {
  @Uint32()
  external int type;
  external _Usage usage;
}

final class _ChainParameters extends Struct {
  @Uint32()
  external int size;
  external _UsageMatch requested;
  external _UsageMatch issuance;
  @Uint32()
  external int timeout;
  @Int32()
  external int checkFreshness;
  @Uint32()
  external int freshness;
  external Pointer<Void> resync;
  external Pointer<Void> strongSign;
  @Uint32()
  external int strongFlags;
}

final class _SslParameters extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int authType;
  @Uint32()
  external int checks;
  external Pointer<Utf16> server;
}

final class _PolicyParameters extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int flags;
  external Pointer<Void> extra;
}

final class _PolicyStatus extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int error;
  @Int32()
  external int chain;
  @Int32()
  external int element;
  external Pointer<Void> extra;
}

int _verify((String, String) input) {
  if (!Platform.isWindows || input.$1.length > 65536 || input.$2.length > 253) {
    return -1;
  }
  final dll = DynamicLibrary.open('crypt32.dll');
  final create = dll
      .lookupFunction<
        Pointer<Void> Function(Uint32, Pointer<Uint8>, Uint32),
        Pointer<Void> Function(int, Pointer<Uint8>, int)
      >('CertCreateCertificateContext');
  final freeCertificate = dll
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CertFreeCertificateContext');
  final build = dll
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<_ChainParameters>,
          Uint32,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<_ChainParameters>,
          int,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
        )
      >('CertGetCertificateChain');
  final freeChain = dll
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CertFreeCertificateChain');
  final check = dll
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<_PolicyParameters>,
          Pointer<_PolicyStatus>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<_PolicyParameters>,
          Pointer<_PolicyStatus>,
        )
      >('CertVerifyCertificateChainPolicy');
  final bytes = base64Decode(
    input.$1.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''),
  );
  final encoded = calloc<Uint8>(bytes.length)
    ..asTypedList(bytes.length).setAll(0, bytes);
  final certificate = create(1, encoded, bytes.length);
  final chain = calloc<Pointer<Void>>();
  final parameters = calloc<_ChainParameters>();
  final ssl = calloc<_SslParameters>();
  final policy = calloc<_PolicyParameters>();
  final status = calloc<_PolicyStatus>();
  final server = input.$2.toNativeUtf16();
  final usage = '1.3.6.1.5.5.7.3.1'.toNativeUtf8();
  final usages = calloc<Pointer<Utf8>>()..value = usage;
  try {
    if (certificate == nullptr) return -1;
    parameters.ref.size = sizeOf<_ChainParameters>();
    parameters.ref.timeout = 2000;
    parameters.ref.requested.usage.count = 1;
    parameters.ref.requested.usage.identifiers = usages;
    if (build(
          nullptr,
          certificate,
          nullptr,
          nullptr,
          parameters,
          0,
          nullptr,
          chain,
        ) ==
        0) {
      return -1;
    }
    ssl.ref.size = sizeOf<_SslParameters>();
    ssl.ref.authType = 2; // AUTHTYPE_SERVER; checks/ignore flags remain zero.
    ssl.ref.server = server;
    policy.ref.size = sizeOf<_PolicyParameters>();
    policy.ref.extra = ssl.cast();
    status.ref.size = sizeOf<_PolicyStatus>();
    if (check(Pointer<Void>.fromAddress(4), chain.value, policy, status) == 0) {
      return -1;
    }
    return status.ref.error;
  } finally {
    if (chain.value != nullptr) freeChain(chain.value);
    if (certificate != nullptr) freeCertificate(certificate);
    for (final pointer in [
      encoded.cast<Void>(),
      chain.cast<Void>(),
      parameters.cast<Void>(),
      ssl.cast<Void>(),
      policy.cast<Void>(),
      status.cast<Void>(),
      server.cast<Void>(),
      usage.cast<Void>(),
      usages.cast<Void>(),
    ]) {
      calloc.free(pointer);
    }
  }
}
