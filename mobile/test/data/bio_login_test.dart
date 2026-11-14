import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kst_vizor/data/api/api_client.dart';
import 'package:kst_vizor/data/api/api_feed.dart';
import 'package:kst_vizor/data/api/api_repositories.dart';
import 'package:kst_vizor/data/api/bio_vault.dart';
import 'package:kst_vizor/data/api_exception.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_auth_repository.dart';
import 'package:kst_vizor/data/models/auth.dart';
import 'package:kst_vizor/data/models/people.dart';

/// Ответ сервера на обновление сеанса с токенами [access] и [refresh].
http.Response _tokens(String access, String refresh) => http.Response.bytes(
      utf8.encode(jsonEncode({
        'access_token': access,
        'refresh_token': refresh,
        'biometrics_allowed': true,
        'user': {'id': 1, 'email': 'engineer@kst.demo', 'name': 'Алексей Смирнов', 'role': 'engineer', 'role_title': 'инженер'},
      })),
      200,
    );

const SavedAccount _me = SavedAccount(email: 'engineer@kst.demo', name: 'Алексей Смирнов', title: 'Инженер-диагност', roleCode: 'engineer');

void main() {
  test('вход по биометрии: токен из хранилища уходит с biometric=true, новый токен запоминается', () async {
    Map<String, dynamic>? sent;
    final ApiClient api = ApiClient(
      'http://srv',
      client: MockClient((http.Request req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return _tokens('a2', 'r2');
      }),
    );
    final MemoryBioVault vault = MemoryBioVault();
    await vault.store(_me, 'r1');
    final ApiAuthRepository auth = ApiAuthRepository(api, MockAuthRepository(MockBackend(latency: MockLatency.none)), ApiFeed(), vault);
    final AuthSession s = await auth.loginWithBiometrics('');
    expect(sent, {'refresh_token': 'r1', 'biometric': true});
    expect(s.user.role, KvRole.engineer);
    expect((await vault.read())!.refreshToken, 'r2');
    expect(api.accessToken, 'a2');
    expect((await auth.savedAccount())!.email, 'engineer@kst.demo');
  });

  test('отозванный токен или запрет политики: хранилище очищается, вход - по паролю', () async {
    final ApiClient api = ApiClient(
      'http://srv',
      client: MockClient((http.Request req) async => http.Response.bytes(utf8.encode('{"detail":"Токен обновления уже использован"}'), 401)),
    );
    final MemoryBioVault vault = MemoryBioVault();
    await vault.store(_me, 'old');
    final ApiAuthRepository auth = ApiAuthRepository(api, MockAuthRepository(MockBackend(latency: MockLatency.none)), ApiFeed(), vault);
    await expectLater(
      auth.loginWithBiometrics(''),
      throwsA(isA<KvApiException>().having((KvApiException e) => e.message, 'message', contains('Войдите с паролем'))),
    );
    expect(await vault.read(), isNull);
    expect(await auth.savedAccount(), isNull);
  });

  test('без включённой биометрии вход отклоняется без запроса к серверу; выход забывает ключ', () async {
    int calls = 0;
    final ApiClient api = ApiClient(
      'http://srv',
      client: MockClient((http.Request req) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    final MemoryBioVault vault = MemoryBioVault();
    final ApiAuthRepository auth = ApiAuthRepository(api, MockAuthRepository(MockBackend(latency: MockLatency.none)), ApiFeed(), vault);
    await expectLater(auth.loginWithBiometrics(''), throwsA(isA<KvApiException>()));
    expect(calls, 0);
    await vault.store(_me, 'r1');
    await auth.logout();
    expect(await vault.read(), isNull);
  });

  test('обновление сеанса клиентом передаёт новый токен хранилищу', () async {
    final MemoryBioVault vault = MemoryBioVault();
    await vault.store(_me, 'r1');
    int n = 0;
    final ApiClient api = ApiClient(
      'http://srv',
      client: MockClient((http.Request req) async {
        if (req.url.path == '/auth/refresh') {
          return _tokens('a2', 'r2');
        }
        n++;
        return n == 1 ? http.Response.bytes(utf8.encode('{"detail":"истёк"}'), 401) : http.Response('[]', 200);
      }),
    )
      ..accessToken = 'a1'
      ..refreshToken = 'r1'
      ..onRefreshToken = vault.rotate;
    await api.getJson('/equipment');
    expect((await vault.read())!.refreshToken, 'r2');
  });
}
