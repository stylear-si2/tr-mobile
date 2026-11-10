import 'dart:convert';

import 'package:sqflite/sqflite.dart';

class BaseOffline {
  static final instancia = BaseOffline();
  BaseOffline([this._ruta]);

  final String? _ruta;
  late final Future<Database> _base = _abrir();

  Future<Map<String, dynamic>?> contexto(String ambito) async {
    final filas = await (await _base).query(
      'contexto',
      where: 'ambito=?',
      whereArgs: [ambito],
    );
    return filas.isEmpty
        ? null
        : jsonDecode(filas.first['datos'] as String) as Map<String, dynamic>;
  }

  Future<void> guardarContexto(
    String ambito,
    Map<String, dynamic> datos,
  ) async {
    await (await _base).insert('contexto', {
      'ambito': ambito,
      'datos': jsonEncode(datos),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> cerrar() async => (await _base).close();

  Future<Database> _abrir() async => openDatabase(
    _ruta ?? '${await getDatabasesPath()}/stylear_cu21.db',
    version: 2,
    onUpgrade: (db, old, version) async {
      if (old < 2) {
        await db.execute('ALTER TABLE operacion ADD COLUMN resultado TEXT');
        await db.execute(
          'CREATE TABLE contexto (ambito TEXT PRIMARY KEY, datos TEXT NOT NULL)',
        );
      }
    },
    onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    onCreate: (db, _) async {
      await db.execute('''CREATE TABLE sucursal (
        ambito TEXT NOT NULL, id INTEGER NOT NULL, nombre TEXT NOT NULL,
        actualizado TEXT, PRIMARY KEY (ambito,id))''');
      await db.execute(
        '''CREATE TABLE variante (
        ambito TEXT NOT NULL, sucursal INTEGER NOT NULL, id INTEGER NOT NULL,
        producto INTEGER NOT NULL, nombre TEXT NOT NULL, talla TEXT, color TEXT,
        stock INTEGER NOT NULL, precio INTEGER,
        PRIMARY KEY (ambito,sucursal,id),
        FOREIGN KEY (ambito,sucursal) REFERENCES sucursal(ambito,id) ON DELETE CASCADE)''',
      );
      await db.execute('''CREATE TABLE historial (
        ambito TEXT NOT NULL, tipo TEXT NOT NULL, id INTEGER NOT NULL, datos TEXT NOT NULL,
        PRIMARY KEY (ambito,tipo,id))''');
      await db.execute('''CREATE TABLE operacion (
        ambito TEXT NOT NULL, uuid TEXT NOT NULL, tipo TEXT NOT NULL,
        sucursal INTEGER NOT NULL, creado TEXT NOT NULL, datos TEXT NOT NULL,
        estado TEXT NOT NULL, intentos INTEGER NOT NULL DEFAULT 0, proximo TEXT,
        motivo TEXT, remoto INTEGER, efectivo_devuelto INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (ambito,uuid))''');
      await db.execute('ALTER TABLE operacion ADD COLUMN resultado TEXT');
      await db.execute(
        'CREATE TABLE contexto (ambito TEXT PRIMARY KEY, datos TEXT NOT NULL)',
      );
      await db.execute('CREATE INDEX cola ON operacion(ambito,estado,creado)');
    },
  );

  Future<List<Map<String, Object?>>> sucursales(String ambito) async =>
      (await _base).query(
        'sucursal',
        where: 'ambito=?',
        whereArgs: [ambito],
        orderBy: 'nombre',
      );

  Future<void> restringirSucursales(String ambito, Set<int> autorizadas) async {
    await (await _base).transaction((txn) async {
      final filas = await txn.query(
        'sucursal',
        columns: ['id'],
        where: 'ambito=?',
        whereArgs: [ambito],
      );
      final retiradas = filas.where(
        (fila) => !autorizadas.contains(fila['id']),
      );
      if (retiradas.isEmpty) return;
      for (final fila in retiradas) {
        await txn.delete(
          'sucursal',
          where: 'ambito=? AND id=?',
          whereArgs: [ambito, fila['id']],
        );
      }
      await txn.delete('historial', where: 'ambito=?', whereArgs: [ambito]);
    });
  }

  Future<List<Map<String, Object?>>> variantes(
    String ambito,
    int sucursal,
  ) async => (await _base).query(
    'variante',
    where: 'ambito=? AND sucursal=?',
    whereArgs: [ambito, sucursal],
    orderBy: 'nombre,id',
  );

  Future<void> guardarDescarga(
    String ambito,
    List<Map<String, dynamic>> sucursales,
    Map<int, List<Map<String, dynamic>>> catalogos,
    Map<String, List<Map<String, dynamic>>> historiales,
  ) async {
    await (await _base).transaction((txn) async {
      final actuales = await txn.query(
        'sucursal',
        columns: ['id'],
        where: 'ambito=?',
        whereArgs: [ambito],
      );
      final autorizadas = sucursales.map((fila) => fila['id'] as int).toSet();
      final lote = txn.batch();
      for (final fila in actuales) {
        if (!autorizadas.contains(fila['id'])) {
          lote.delete(
            'sucursal',
            where: 'ambito=? AND id=?',
            whereArgs: [ambito, fila['id']],
          );
        }
      }
      for (final sucursal in sucursales) {
        final id = sucursal['id'] as int;
        lote.insert('sucursal', {
          'ambito': ambito,
          'id': id,
          'nombre': sucursal['nombre'],
          'actualizado': DateTime.now().toUtc().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        for (final v in catalogos[id]!) {
          lote.insert('variante', {
            'ambito': ambito,
            'sucursal': id,
            'id': v['variante_id'],
            'producto': v['producto_id'],
            'nombre': v['nombre'],
            'talla': v['talla'],
            'color': v['color'],
            'stock': v['stock'],
            'precio': v['precio_centavos'],
          });
        }
      }
      lote.delete('historial', where: 'ambito=?', whereArgs: [ambito]);
      for (final grupo in historiales.entries) {
        for (final fila in grupo.value) {
          lote.insert('historial', {
            'ambito': ambito,
            'tipo': grupo.key,
            'id': fila['id'],
            'datos': jsonEncode(fila),
          });
        }
      }
      await lote.commit(noResult: true);
    });
  }

  Future<List<Map<String, Object?>>> historial(String ambito) async =>
      (await _base).query(
        'historial',
        where: 'ambito=?',
        whereArgs: [ambito],
        orderBy: 'id DESC',
      );

  Future<List<Map<String, Object?>>> operaciones(String ambito) async =>
      (await _base).query(
        'operacion',
        where: 'ambito=?',
        whereArgs: [ambito],
        orderBy: 'creado DESC',
      );

  Future<void> registrar(
    String ambito,
    String uuid,
    String tipo,
    int sucursal,
    Map<String, dynamic> datos,
  ) async {
    final contenido = jsonEncode(datos);
    await (await _base).transaction((txn) async {
      final anterior = await txn.query(
        'operacion',
        columns: ['tipo', 'sucursal', 'datos'],
        where: 'ambito=? AND uuid=?',
        whereArgs: [ambito, uuid],
      );
      if (anterior.isNotEmpty) {
        final fila = anterior.single;
        if (fila['datos'] != contenido ||
            fila['tipo'] != tipo ||
            fila['sucursal'] != sucursal) {
          throw StateError(
            'El identificador corresponde a una operación distinta.',
          );
        }
        return;
      }
      await txn.insert('operacion', {
        'ambito': ambito,
        'uuid': uuid,
        'tipo': tipo,
        'sucursal': sucursal,
        'creado': DateTime.now().toUtc().toIso8601String(),
        'datos': contenido,
        'estado': 'PENDIENTE',
      });
    });
  }

  Future<void> actualizar(
    String ambito,
    String uuid,
    Map<String, Object?> cambios,
  ) async => (await _base).update(
    'operacion',
    cambios,
    where: 'ambito=? AND uuid=?',
    whereArgs: [ambito, uuid],
  );

  Future<void> confirmar(
    String ambito,
    String uuid,
    String tipo,
    Map<String, dynamic> resultado, {
    String? ambitoHistorial,
  }) async {
    await (await _base).transaction((txn) async {
      final id = resultado['id'] as int;
      await txn.update(
        'operacion',
        {
          'estado': 'CONFIRMADA',
          'remoto': id,
          'motivo': null,
          'resultado': jsonEncode(resultado),
        },
        where: 'ambito=? AND uuid=?',
        whereArgs: [ambito, uuid],
      );
      if (tipo == 'COMPRA') return;
      await txn.insert('historial', {
        'ambito': ambitoHistorial ?? ambito,
        'tipo': tipo,
        'id': id,
        'datos': jsonEncode(resultado),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }
}
