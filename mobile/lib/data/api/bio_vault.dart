import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../models/auth.dart';

/// Учётная запись для входа по биометрии: токен обновления и сведения для экрана входа.
class BioAccount {
  /// Создаёт запись.
  const BioAccount({required this.account, required this.refreshToken});

  /// Сохранённая учётная запись.
  final SavedAccount account;

  /// Токен обновления сеанса.
  final String refreshToken;
}

/// Хранилище входа по биометрии: токен обновления лежит в Keychain (iOS) или в зашифрованном хранилище Android
/// и выдаётся только после системной проверки лица или отпечатка.
abstract interface class BioVault {
  /// Телефон умеет проверять биометрию и она настроена.
  Future<bool> available();

  /// Что проверяет телефон: «Face ID», «Touch ID» или «отпечаток».
  Future<String> kind();

  /// Системная проверка с причиной [reason]; true - личность подтверждена.
  Future<bool> authenticate(String reason);

  /// Сохранённая учётная запись без токена (для экрана входа); null - вход по биометрии не включён.
  Future<SavedAccount?> account();

  /// Включить вход по биометрии для [account] с токеном [refreshToken].
  Future<void> store(SavedAccount account, String refreshToken);

  /// Обновить токен после его смены на сервере, если вход по биометрии включён.
  Future<void> rotate(String refreshToken);

  /// Учётная запись с токеном; null - нет.
  Future<BioAccount?> read();

  /// Забыть вход по биометрии.
  Future<void> clear();
}

/// Хранилище в памяти: тесты и демонстрационный режим.
class MemoryBioVault implements BioVault {
  /// Создаёт хранилище; [supported] - есть ли биометрия, [pass] - результат проверки.
  MemoryBioVault({this.supported = true, this.pass = true});

  /// Есть ли биометрия.
  bool supported;

  /// Результат следующей проверки.
  bool pass;

  BioAccount? _value;

  @override
  Future<bool> available() async => supported;

  @override
  Future<String> kind() async => 'отпечаток';

  @override
  Future<bool> authenticate(String reason) async => pass;

  @override
  Future<SavedAccount?> account() async => _value?.account;

  @override
  Future<void> store(SavedAccount account, String refreshToken) async => _value = BioAccount(account: account, refreshToken: refreshToken);

  @override
  Future<void> rotate(String refreshToken) async {
    final BioAccount? v = _value;
    if (v != null) {
      _value = BioAccount(account: v.account, refreshToken: refreshToken);
    }
  }

  @override
  Future<BioAccount?> read() async => _value;

  @override
  Future<void> clear() async => _value = null;
}

/// Хранилище телефона: local_auth для проверки, flutter_secure_storage для токена.
class DeviceBioVault implements BioVault {
  /// Создаёт хранилище.
  DeviceBioVault();

  static const String _key = 'kst_bio_account';

  final LocalAuthentication _auth = LocalAuthentication();

  final FlutterSecureStorage _store = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  @override
  Future<bool> available() async {
    try {
      return await _auth.canCheckBiometrics && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  @override
  Future<String> kind() async {
    try {
      final List<BiometricType> types = await _auth.getAvailableBiometrics();
      if (types.contains(BiometricType.face)) {
        return 'Face ID';
      }
      if (types.contains(BiometricType.fingerprint)) {
        return 'отпечаток';
      }
    } on PlatformException {
      return 'биометрию';
    } on LocalAuthException {
      return 'биометрию';
    }
    return 'биометрию';
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true);
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }

  @override
  Future<SavedAccount?> account() async => (await read())?.account;

  @override
  Future<void> store(SavedAccount account, String refreshToken) => _store.write(
        key: _key,
        value: jsonEncode({
          'email': account.email,
          'name': account.name,
          'title': account.title,
          'role': account.roleCode,
          'token': refreshToken,
        }),
      );

  @override
  Future<void> rotate(String refreshToken) async {
    final BioAccount? v = await read();
    if (v != null) {
      await store(v.account, refreshToken);
    }
  }

  @override
  Future<BioAccount?> read() async {
    try {
      final String? raw = await _store.read(key: _key);
      if (raw == null) {
        return null;
      }
      final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
      return BioAccount(
        account: SavedAccount(
          email: j['email'] as String? ?? '',
          name: j['name'] as String? ?? '',
          title: j['title'] as String? ?? '',
          roleCode: j['role'] as String? ?? '',
        ),
        refreshToken: j['token'] as String? ?? '',
      );
    } on PlatformException {
      await clear();
      return null;
    } on FormatException {
      await clear();
      return null;
    }
  }

  @override
  Future<void> clear() => _store.delete(key: _key);
}

/// Хранилище входа по биометрии; в main.dart на настоящем сервере подменяется [DeviceBioVault].
final Provider<BioVault> bioVaultProvider = Provider<BioVault>((Ref ref) => MemoryBioVault());
