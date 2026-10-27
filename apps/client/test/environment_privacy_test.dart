import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/features/utilities/environment_snapshot.dart';

void main() {
  Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));
  test('JSON nested secrets and recognizable credentials are redacted without exporting private home paths', () {
    final preview = SnapshotPrivacy.config(
      r'C:\Users\Example\settings.json',
      bytes(
        jsonEncode({
          'theme': 'dark',
          'provider': {
            'apiKey': 'fixture-key',
            'password': 'fixture-password',
            'nested': [
              {'access_token': 'fixture-token'},
            ],
          },
          'link': 'https://example.invalid/?token=fixture-query&ok=1',
          'home': r'C:\Users\Example\workspace',
          'authorization': 'Bearer fixture-auth',
        }),
      ),
      profile: r'C:\Users\Example',
    );
    expect(preview.rejected, isEmpty);
    final text = utf8.decode(preview.content);
    for (final secret in [
      'fixture-key',
      'fixture-password',
      'fixture-token',
      'fixture-query',
      'fixture-auth',
      r'C:\Users\Example',
    ]) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, contains('dark'));
    expect(text, contains('%USERPROFILE%'));
    expect(preview.redactions, greaterThanOrEqualTo(5));
  });
  test('YAML blocks, token lines and bearer strings are protected; ambiguous multiline configs rejected', () {
    final preview = SnapshotPrivacy.config(
      'config.yaml',
      bytes(
        'theme: dark\npassword: |\n  line-one-secret\n  line-two-secret\nregular: safe\napi_key: another-secret\nauth: Bearer opaque-value',
      ),
    );
    final text = utf8.decode(preview.content);
    for (final secret in [
      'line-one-secret',
      'line-two-secret',
      'another-secret',
      'opaque-value',
    ]) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, contains('regular: safe'));
    expect(text, contains('theme: dark'));
    expect(
      SnapshotPrivacy.config(
        'config.toml',
        bytes("token = '''\nunknown-block\n'''"),
      ).rejected,
      isNotEmpty,
    );
  });
  test('credential files, private key blocks, invalid JSON, binary and oversize are never copied', () {
    for (final name in [
      '.env',
      '.env.local',
      'id_rsa',
      'secret.ppk',
      'key.pem',
    ]) {
      expect(
        SnapshotPrivacy.config(name, bytes('valid-looking text')).rejected,
        isNotEmpty,
      );
    }
    for (final input in [
      ('config.txt', bytes('-----BEGIN OPENSSH PRIVATE KEY-----\nfixture')),
      ('config.json', bytes('invalid')),
      ('config.txt', Uint8List.fromList([0, 1, 2])),
      ('config.txt', Uint8List(1024 * 1024 + 1)),
    ]) {
      final preview = SnapshotPrivacy.config(input.$1, input.$2);
      expect(preview.rejected, isNotEmpty);
      expect(preview.content, isEmpty);
    }
  });
  test('PowerShell version scripts use literal argument quoting and UTF16 encoded transport', () {
    final literal = EnvironmentSnapshotService.psLiteral(
      "C:\\test' & folder\\flutter.bat",
    );
    expect(literal, "'C:\\test'' & folder\\flutter.bat'");
    final args = EnvironmentSnapshotService.encodedPowerShell(
      "& $literal '--version'",
    );
    expect(args, contains('-EncodedCommand'));
    final raw = base64.decode(args.last), data = ByteData.sublistView(raw);
    final decoded = String.fromCharCodes([
      for (var i = 0; i < raw.length; i += 2) data.getUint16(i, Endian.little),
    ]);
    expect(decoded, "& $literal '--version'");
  });
}
