import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_tr/core/constants/api_constants.dart';
import 'package:mobile_tr/core/network/api_client.dart';
import 'package:mobile_tr/providers/auth_provider.dart';
import 'package:mobile_tr/screens/vestidor/probador_ia_screen.dart';
import 'package:mobile_tr/screens/vestidor/vestidor_en_vivo_screen.dart';
import 'package:mobile_tr/screens/vestidor/services/guardar_foto_vestidor.dart';
import 'package:mobile_tr/screens/vestidor/services/vestidor_api_service.dart';

import 'cuenta_test.dart' show sesion, empresaA, usuario, jwt, jsonRespuesta;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ApiConstants.customHost = 'http://127.0.0.1:58127';
    await sesion.seleccionar(empresaA);
  });
  tearDown(() async {
    await sesion.seleccionar(null);
    ApiClient.client.close();
  });
  test('foto lleva autenticación y recibe resultado en memoria', () async {
    await sesion.guardar(jwt(), usuario());
    final foto = File(
      '${Directory.systemTemp.path}/stylear-vestidor-test-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await foto.writeAsBytes([1, 2, 3]);
    try {
      ApiClient.client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer ${sesion.token}');
        expect(request.headers['X-Empresa-Codigo'], 'tienda-a');
        expect(request.url.path, endsWith('/vestidor/probar-ia'));
        return jsonRespuesta({
          'imagen_resultado_base64': base64Encode([1, 2, 3]),
          'imagen_mime_type': 'image/jpeg',
        });
      });
      final respuesta = await VestidorApiService.probarPrendaConIA(
        imagen: foto,
        productoId: 1,
      );
      expect(base64Decode(respuesta['imagen_resultado_base64'] as String), [
        1,
        2,
        3,
      ]);
      expect(respuesta.containsKey('imagen_resultado_url'), false);
    } finally {
      await foto.delete();
    }
  });
  test(
    'guardar usa selector nativo únicamente al invocarlo y respeta cancelar',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var llamadas = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(GuardarFotoVestidor.canal, (call) async {
            llamadas++;
            expect(call.method, 'guardar');
            expect(
              (call.arguments as Map)['bytes'],
              Uint8List.fromList([1, 2]),
            );
            return false;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(GuardarFotoVestidor.canal, null),
      );
      expect(llamadas, 0);
      expect(
        await GuardarFotoVestidor.guardar(Uint8List.fromList([1, 2])),
        false,
      );
      expect(llamadas, 1);
    },
  );
  for (final foto in [true, false]) {
    testWidgets('visitante no inicia IA ${foto ? 'foto' : 'en vivo'}', (
      t,
    ) async {
      ApiClient.client = MockClient((request) async {
        expect(request.url.path, endsWith('/prendas-disponibles'));
        return jsonRespuesta([]);
      });
      final auth = AuthProvider();
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: auth,
          child: MaterialApp(
            home: foto
                ? const ProbadorIaScreen()
                : const VestidorEnVivoScreen(),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.text(
          'El vestidor con IA está disponible solo para clientes con sesión iniciada.',
        ),
        findsOneWidget,
      );
      expect(find.text('Iniciar sesión'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
}
