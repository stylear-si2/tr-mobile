import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_tr/core/storage/base_offline.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'CU21 conserva la cola, deduplica y separa los datos al reabrir SQLite',
    () async {
      final directorio = await Directory.systemTemp.createTemp('stylear-cu21-');
      final ruta = '${directorio.path}/cu21.db';
      final primera = BaseOffline(ruta);
      const ambito = '11:9';
      const uuid = '2579d13e-5e45-4ca0-8a20-237224b0adf2';
      await primera.guardarDescarga(
        ambito,
        [
          {'id': 2, 'nombre': 'Centro'},
        ],
        {
          2: [
            {
              'variante_id': 4,
              'producto_id': 7,
              'nombre': 'Prenda',
              'stock': 2,
              'precio_centavos': 5000,
            },
          ],
        },
        {
          'RESERVA': [
            {'id': 12, 'estado': 'PENDIENTE'},
          ],
        },
      );
      await Future.wait(
        List.generate(
          20,
          (_) => primera.registrar(ambito, uuid, 'VENTA', 2, {
            'efectivo_centavos': 5000,
          }),
        ),
      );
      await primera.actualizar(ambito, uuid, {'estado': 'ENVIANDO'});
      await expectLater(
        primera.registrar(ambito, uuid, 'VENTA', 2, {
          'efectivo_centavos': 6000,
        }),
        throwsStateError,
      );
      await primera.cerrar();

      final reabierta = BaseOffline(ruta);
      addTearDown(() async {
        await reabierta.cerrar();
        await deleteDatabase(ruta);
        await directorio.delete();
      });
      expect((await reabierta.variantes(ambito, 2)).single['precio'], 5000);
      expect((await reabierta.historial(ambito)).single['id'], 12);
      final operacion = (await reabierta.operaciones(ambito)).single;
      expect(operacion['uuid'], uuid);
      expect(operacion['estado'], 'ENVIANDO');
      expect(await reabierta.operaciones('11:10'), isEmpty);
      expect(await reabierta.variantes('12:9', 2), isEmpty);

      await reabierta.guardarDescarga(ambito, [], {}, {});
      expect(await reabierta.variantes(ambito, 2), isEmpty);
      expect((await reabierta.operaciones(ambito)).single['uuid'], uuid);
      await reabierta.confirmar(ambito, uuid, 'VENTA', {
        'id': 5,
        'total': '50.00',
      });
      expect((await reabierta.operaciones(ambito)).single['remoto'], 5);
      expect((await reabierta.historial(ambito)).single['id'], 5);
    },
  );
  test('compras y cambios persisten separados y conservan cotización después de reiniciar', () async {
    final dir = await Directory.systemTemp.createTemp('stylear-offline-extra-');
    final ruta = '${dir.path}/offline.db';
    final db = BaseOffline(ruta);
    await db.guardarContexto('1:2:CLIENTE', {
      'ventas': [
        {'venta_id': 7},
      ],
      'politica': {'plazo_cambios': 30},
    });
    await db.registrar('1:2', 'compra-a', 'COMPRA', 3, {
      'items': [
        {'producto_variante_id': 8, 'cantidad': 3, 'precio_centavos': 5000},
      ],
    });
    await db.registrar('1:2', 'compra-b', 'COMPRA', 3, {
      'items': [
        {'producto_variante_id': 9, 'cantidad': 1, 'precio_centavos': 2500},
      ],
    });
    await db.registrar('1:2', 'cambio-a', 'CAMBIO', 3, {
      'venta_id': 7,
      'cantidad': 1,
      'motivo': 'Cambio de talla',
    });
    await db.confirmar('1:2', 'compra-a', 'COMPRA', {
      'id': 0,
      'estado': 'PENDIENTE_PAGO',
      'total': '150.00',
      'items': [
        {'producto_variante_id': 8, 'cantidad': 3, 'precio_centavos': 5000},
      ],
    });
    await db.cerrar();
    final segunda = BaseOffline(ruta);
    expect((await segunda.operaciones('1:2')).length, 3);
    expect(
      (await segunda.operaciones('1:2'))
          .firstWhere((r) => r['uuid'] == 'compra-a')['resultado'],
      contains('150.00'),
    );
    expect(
      (await segunda.operaciones('1:2'))
          .firstWhere((r) => r['uuid'] == 'compra-b')['estado'],
      'PENDIENTE',
    );
    expect(await segunda.historial('1:2'), isEmpty);
    expect((await segunda.contexto('1:2:CLIENTE'))!['ventas'], isNotEmpty);
    expect(await segunda.contexto('2:2:CLIENTE'), isNull);
    await segunda.cerrar();
    await deleteDatabase(ruta);
    await dir.delete();
  });

  test('actualiza SQLite v1 sin perder operaciones pendientes', () async {
    final dir = await Directory.systemTemp.createTemp(
      'stylear-offline-migracion-',
    );
    final ruta = '${dir.path}/offline.db';
    final anterior = await openDatabase(
      ruta,
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE operacion (ambito TEXT, uuid TEXT, tipo TEXT, sucursal INTEGER, creado TEXT, datos TEXT, estado TEXT, intentos INTEGER DEFAULT 0, proximo TEXT, motivo TEXT, remoto INTEGER, efectivo_devuelto INTEGER DEFAULT 0, PRIMARY KEY(ambito,uuid))',
        );
        await db.insert('operacion', {
          'ambito': '1:2',
          'uuid': 'previa',
          'tipo': 'RESERVA',
          'creado': '2026-11-10',
          'datos': '{}',
          'estado': 'PENDIENTE',
        });
      },
    );
    await anterior.close();
    final actual = BaseOffline(ruta);
    expect((await actual.operaciones('1:2')).single['uuid'], 'previa');
    await actual.guardarContexto('1:2', {'ventas': []});
    expect(await actual.contexto('1:2'), isNotNull);
    await actual.cerrar();
    await deleteDatabase(ruta);
    await dir.delete();
  });
}
