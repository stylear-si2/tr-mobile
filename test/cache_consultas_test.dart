import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_tr/core/constants/api_constants.dart';
import 'package:mobile_tr/core/network/api_client.dart';
import 'package:mobile_tr/core/network/api_exceptions.dart';
import 'package:mobile_tr/core/storage/cache_consultas.dart';

import 'cuenta_test.dart' show sesion, empresaA, usuario, jwt, jsonRespuesta;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ApiClient.soloLocal = false;
    ApiConstants.customHost = 'http://127.0.0.1:58127';
    await sesion.seleccionar(empresaA);
    await sesion.guardar(jwt(), usuario());
  });
  tearDown(() async {
    ApiClient.soloLocal = false;
    ApiClient.usandoCache.value = false;
    await sesion.seleccionar(null);
    ApiClient.client.close();
  });
  test('conserva consulta y la recupera sin red', () async {
    ApiClient.client = MockClient(
      (_) async => jsonRespuesta({
        'items': [1],
      }),
    );
    final url = '${ApiConstants.baseUrl}/carrito';
    expect(await ApiClient.get(url), {
      'items': [1],
    });
    ApiClient.client = MockClient((_) async => throw Exception('sin red'));
    expect(await ApiClient.get(url), {
      'items': [1],
    });
    expect(ApiClient.usandoCache.value, isTrue);
    ApiClient.soloLocal = true;
    expect(await ApiClient.get(url), {
      'items': [1],
    });
    await expectLater(
      ApiClient.post(url, body: {}),
      throwsA(isA<ApiException>()),
    );
  });
  test('un rechazo de permisos no se reemplaza por datos guardados', () async {
    final url = '${ApiConstants.baseUrl}/carrito';
    ApiClient.client = MockClient(
      (_) async => jsonRespuesta({
        'items': [1],
      }),
    );
    await ApiClient.get(url);
    ApiClient.client = MockClient(
      (_) async => jsonRespuesta({'detail': 'Denegado'}, 403),
    );
    await expectLater(
      ApiClient.get(url),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
    );
  });
  test('las claves separan servidor, usuario y empresa', () {
    expect(
      CacheConsultas.clave('1:1:CLIENTE', 'https://a/carrito'),
      isNot(CacheConsultas.clave('1:2:CLIENTE', 'https://a/carrito')),
    );
    expect(
      CacheConsultas.admite(Uri.parse('https://a/api/v1/autenticacion/login')),
      isFalse,
    );
    expect(
      CacheConsultas.admite(
        Uri.parse('https://a/api/v1/catalogo/vestidor/probar-ia'),
      ),
      isFalse,
    );
  });
}
