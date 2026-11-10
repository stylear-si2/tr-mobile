import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/constants/api_constants.dart';
import '../core/network/api_client.dart';
import '../core/network/api_exceptions.dart';
import '../core/session/contexto_sesion.dart';
import '../core/storage/base_offline.dart';
import '../core/storage/sesion_offline.dart';

class SincronizacionOffline {
  static final instancia = SincronizacionOffline();
  final cambios = StreamController<void>.broadcast();
  final _base = BaseOffline.instancia;
  final _contexto = ContextoSesion.instance;
  final _enCurso = <String, Future<void>>{};

  Future<void> ejecutar(
    SesionOffline sesion, {
    bool manual = false,
    bool descargar = true,
  }) => _enCurso.putIfAbsent(sesion.ambito, () async {
    try {
      await _ejecutar(sesion, manual, descargar);
    } finally {
      _enCurso.remove(sesion.ambito);
      cambios.add(null);
    }
  });

  Future<void> _ejecutar(
    SesionOffline sesion,
    bool manual,
    bool descargar,
  ) async {
    final generacion = _contexto.generacion;
    if (_contexto.token == null ||
        _contexto.usuario?.id != sesion.usuario.id ||
        _contexto.empresa?.id != sesion.empresa.id) {
      return;
    }
    final pendientes = (await _base.operaciones(sesion.ambito)).reversed
        .where((fila) {
          if (!['PENDIENTE', 'ENVIANDO'].contains(fila['estado'])) return false;
          final proximo = DateTime.tryParse(fila['proximo'] as String? ?? '');
          return manual || proximo == null || !proximo.isAfter(DateTime.now());
        })
        .toList();
    if (pendientes.isEmpty && !descargar) return;
    ApiClient.validarGeneracion(generacion);
    final url = ApiConstants.baseUrl;
    try {
      final perfil =
          await ApiClient.get(ApiConstants.perfil) as Map<String, dynamic>;
      final roles = (perfil['roles'] as List).cast<String>().toSet();
      final anteriores = sesion.usuario.roles.toSet();
      if (roles.length != anteriores.length || !roles.containsAll(anteriores)) {
        throw ApiException(
          'Tus permisos cambiaron. Inicia sesión nuevamente.',
          statusCode: 403,
        );
      }
    } on ApiException catch (error) {
      if (error.statusCode == 403 && _contexto.generacion == generacion) {
        await _base.guardarDescarga(sesion.ambitoDatos, [], {}, {});
        await _contexto.cerrar(mensaje: error.message, pedirLogin: true);
      }
      rethrow;
    }
    final sucursales = await _lista('$url/operacion-movil/sucursales');
    ApiClient.validarGeneracion(generacion);
    await _base.restringirSucursales(
      sesion.ambitoDatos,
      sucursales.map((fila) => fila['id'] as int).toSet(),
    );
    for (final fila in pendientes) {
      ApiClient.validarGeneracion(generacion);
      final uuid = fila['uuid'] as String;
      final tipo = fila['tipo'] as String;
      final intentos = (fila['intentos'] as int) + 1;
      await _base.actualizar(sesion.ambito, uuid, {
        'estado': 'ENVIANDO',
        'intentos': intentos,
      });
      try {
        ApiClient.validarGeneracion(generacion);
        final ruta = switch (tipo) {
          'COMPRA' => 'pagos/offline/cotizar',
          'CAMBIO' => 'posventa/cambios',
          'ENTREGA_CAMBIO' =>
            'posventa/cambios/${(jsonDecode(fila['datos'] as String) as Map)['id']}/completar',
          'REVISION_CAMBIO' =>
            'posventa/cambios/${(jsonDecode(fila['datos'] as String) as Map)['id']}/revision',
          _ =>
            '${tipo == 'VENTA' ? 'ventas-presenciales' : 'reservas'}/offline',
        };
        final datos =
            jsonDecode(fila['datos'] as String) as Map<String, dynamic>;
        if (tipo == 'REVISION_CAMBIO' || tipo == 'ENTREGA_CAMBIO') {
          datos.remove('id');
        }
        final resultado = tipo == 'REVISION_CAMBIO'
            ? await ApiClient.patch('$url/$ruta', body: datos)
            : await ApiClient.post('$url/$ruta', body: datos);
        if (resultado is! Map<String, dynamic> || resultado['id'] is! int) {
          throw ApiException(
            'El servidor aún no devolvió un resultado verificable.',
          );
        }
        ApiClient.validarGeneracion(generacion);
        await _base.confirmar(
          sesion.ambito,
          uuid,
          tipo,
          resultado,
          ambitoHistorial: sesion.ambitoDatos,
        );
      } on ApiException catch (error) {
        if (_contexto.generacion != generacion) rethrow;
        final codigo = error.statusCode;
        if (codigo == 401 ||
            codigo == null ||
            codigo >= 500 ||
            codigo == 429 ||
            codigo == 408) {
          final espera = min(300, 5 * (1 << min(intentos, 6)));
          await _base.actualizar(sesion.ambito, uuid, {
            'estado': 'PENDIENTE',
            'motivo': error.message,
            'proximo': DateTime.now()
                .toUtc()
                .add(Duration(seconds: espera))
                .toIso8601String(),
          });
          rethrow;
        }
        await _base.actualizar(sesion.ambito, uuid, {
          'estado': codigo == 400 || codigo == 409
              ? 'EN CONFLICTO'
              : 'RECHAZADA',
          'motivo': error.message,
        });
      }
    }

    final catalogos = <int, List<Map<String, dynamic>>>{};
    for (final sucursal in sucursales) {
      final id = sucursal['id'] as int;
      final items = <Map<String, dynamic>>[];
      int? siguiente = 0;
      while (siguiente != null && items.length < 1000) {
        final pagina = await ApiClient.get(
          '$url/operacion-movil/catalogo?sucursal_id=$id&desde=$siguiente',
        ) as Map<String, dynamic>;
        items.addAll((pagina['items'] as List).cast<Map<String, dynamic>>());
        siguiente = pagina['siguiente'] as int?;
      }
      catalogos[id] = items;
    }
    final historial = <String, List<Map<String, dynamic>>>{};
    if (sesion.puedeVender) {
      historial['VENTA'] = await _lista('$url/ventas-presenciales?limite=30');
      historial['RESERVA'] = await _lista(
        '$url/reservas?limite=30&incluir_finalizadas=true',
      );
    } else if (sesion.puedeReservar) {
      historial['RESERVA'] = await _lista(
        '$url/reservas/mis-reservas?limite=30',
      );
      historial['PAGO'] = [
        for (final pago in await _lista('$url/pagos/mis-pagos?limite=30'))
          {
            'id': pago['orden_id'],
            'codigo': pago['venta_codigo'],
            'total': pago['monto_total'],
            'estado': pago['estado'],
            'fecha_venta': pago['fecha_pago'] ?? pago['fecha_creacion'],
          },
      ];
    }
    final posventa = await ApiClient.get(
      '$url/posventa/cambios/offline/descarga',
    ) as Map<String, dynamic>;
    ApiClient.validarGeneracion(generacion);
    await _base.guardarContexto(sesion.ambitoDatos, posventa);
    await _base.guardarDescarga(
      sesion.ambitoDatos,
      sucursales,
      catalogos,
      historial,
    );
  }

  Future<List<Map<String, dynamic>>> _lista(String ruta) async =>
      (await ApiClient.get(ruta) as List).cast<Map<String, dynamic>>();
}
