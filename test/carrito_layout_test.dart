import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_tr/core/constants/api_constants.dart';
import 'package:mobile_tr/core/network/api_client.dart';
import 'package:mobile_tr/providers/auth_provider.dart';
import 'package:mobile_tr/providers/carrito_provider.dart';
import 'package:mobile_tr/providers/reserva_provider.dart';
import 'package:mobile_tr/screens/carrito/carrito_screen.dart';

import 'cuenta_test.dart' show sesion, empresaA, usuario, jwt, jsonRespuesta;

void main() {
  testWidgets('formulario cabe con barra superior, navegacion y texto grande', (
    tester,
  ) async {
    await initializeDateFormatting('es_BO');
    SharedPreferences.setMockInitialValues({});
    ApiConstants.customHost = 'http://127.0.0.1:58127';
    await sesion.seleccionar(empresaA);
    await sesion.guardar(jwt(), usuario());
    ApiClient.client = MockClient((r) async {
      if (r.url.path.endsWith('/carrito')) {
        return jsonRespuesta({
          'id': 1,
          'total': 190,
          'items': [
            {
              'id': 1,
              'producto_variante_id': 1,
              'producto_id': 1,
              'producto': 'Prenda de prueba',
              'talla': 'M',
              'color': 'Negro',
              'cantidad': 1,
              'precio_unitario': 190,
              'subtotal': 190,
              'stock_disponible': 10,
            },
          ],
          'sucursales_disponibles': [],
        });
      }
      if (r.url.path.endsWith('/pendiente')) return jsonRespuesta({});
      return jsonRespuesta({'direcciones': []});
    });
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthProvider();
    final carrito = CarritoProvider();
    final reservas = ReservaProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider.value(value: carrito),
          ChangeNotifierProvider.value(value: reservas),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(1.2),
            ),
            child: const Column(
              children: [
                SizedBox(height: 90),
                Expanded(child: CarritoScreen()),
                SizedBox(height: 80),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Prenda de prueba'), findsOneWidget);
    await tester.tap(find.text('Continuar: reserva o pago'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Volver a las prendas'), findsOneWidget);
    await tester.tap(find.text('Volver a las prendas'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Prenda de prueba'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
    carrito.dispose();
    reservas.dispose();
    ApiClient.client.close();
    await sesion.seleccionar(null);
  });
}
