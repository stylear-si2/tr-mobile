import 'dart:typed_data';

import '../core/constants/api_constants.dart';
import '../core/network/api_client.dart';
import '../models/reporte_models.dart';
import '../models/analisis_reporte.dart';

class ReporteService {
  ReporteService._();

  /// Devuelve el catálogo de tipos de reporte y sucursales disponibles.
  static Future<ReporteCatalogo> obtenerCatalogo() async {
    final res = await ApiClient.get(ApiConstants.reportesCatalogo);
    return ReporteCatalogo.fromJson(res as Map<String, dynamic>);
  }

  static Future<AnalisisReporte> analizar(
    ReporteFiltros filtros, {
    String? firmaResultado,
  }) async {
    final res = await ApiClient.post(
      '${ApiConstants.baseUrl}/reportes/analizar',
      body: {...filtros.toJson(), 'firma_resultado': ?firmaResultado},
    );
    return AnalisisReporte.fromJson(Map<String, dynamic>.from(res as Map));
  }

  static Future<Uint8List> audioAnalisis(String id) => ApiClient.postBytes(
    '${ApiConstants.baseUrl}/reportes/audio',
    body: {'analisis_id': id},
  );

  /// Genera un reporte según los filtros indicados.
  static Future<ReporteResultado> generar(ReporteFiltros filtros) async {
    final res = await ApiClient.post(
      ApiConstants.reportesGenerar,
      body: filtros.toJson(),
    );
    return ReporteResultado.fromJson(res as Map<String, dynamic>);
  }

  /// Exporta el reporte como PDF (bytes).
  static Future<Uint8List> exportarPdf(
    ReporteFiltros filtros, {
    String? analisisId,
  }) async {
    return ApiClient.postBytes(
      ApiConstants.reportesExportarPdf,
      body: {...filtros.toJson(), 'analisis_id': ?analisisId},
    );
  }

  /// Exporta el reporte como Excel (bytes).
  static Future<Uint8List> exportarExcel(
    ReporteFiltros filtros, {
    String? analisisId,
  }) async {
    return ApiClient.postBytes(
      ApiConstants.reportesExportarExcel,
      body: {...filtros.toJson(), 'analisis_id': ?analisisId},
    );
  }

  /// Interpreta un texto o dictado por voz para extraer filtros de reporte automáticamente.
  static Future<ReporteInterpretacionResultado> interpretar(
    String texto, {
    String origen = 'TEXTO',
  }) async {
    final res = await ApiClient.post(
      ApiConstants.reportesInterpretar,
      body: {'texto': texto, 'origen': origen},
    );
    return ReporteInterpretacionResultado.fromJson(res as Map<String, dynamic>);
  }

  /// Lista las programaciones automáticas de reportes existentes.
  static Future<List<ReporteProgramadoItem>> listarProgramados() async {
    final res = await ApiClient.get(ApiConstants.reportesProgramados);
    if (res is List) {
      return res
          .map((e) => ReporteProgramadoItem.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  /// Crea una nueva programación automática de reporte.
  static Future<Map<String, dynamic>> crearProgramado(
    Map<String, dynamic> datos,
  ) async {
    final res = await ApiClient.post(
      ApiConstants.reportesProgramados,
      body: datos,
    );
    return res is Map<String, dynamic> ? res : {};
  }

  /// Activa o pausa una programación automática.
  static Future<Map<String, dynamic>> actualizarEstadoProgramado(
    int id,
    bool activo,
  ) async {
    final res = await ApiClient.patch(
      ApiConstants.reporteProgramadoEstado(id),
      body: {'activo': activo},
    );
    return res is Map<String, dynamic> ? res : {};
  }

  /// Elimina una programación de reporte.
  static Future<Map<String, dynamic>> eliminarProgramado(int id) async {
    final res = await ApiClient.delete(
      ApiConstants.reporteProgramadoDetalle(id),
    );
    return res is Map<String, dynamic> ? res : {};
  }

  /// Ejecuta un envío mediante el transporte configurado; consultar historial ante resultado incierto.
  static Future<Map<String, dynamic>> ejecutarProgramado(int id) async {
    final res = await ApiClient.post(
      ApiConstants.reporteProgramadoEjecutar(id),
    );
    return res is Map<String, dynamic> ? res : {};
  }

  static Future<ReporteResultado> detalle(
    ReporteFiltros filtros, {
    int pagina = 1,
    int tamano = 20,
  }) async => ReporteResultado.fromJson(
    await ApiClient.post(
      '${ApiConstants.baseUrl}/reportes/detalle',
      body: {...filtros.toJson(), 'pagina': pagina, 'tamano': tamano},
    ) as Map<String, dynamic>,
  );
  static Future<Map<String, dynamic>> dashboard(
    Map<String, dynamic> filtros,
  ) async => await ApiClient.post(
    '${ApiConstants.baseUrl}/reportes/dashboard',
    body: filtros,
  ) as Map<String, dynamic>;
  static Future<void> editarProgramado(
    int id,
    int revision,
    Map<String, dynamic> cambios,
  ) async {
    await ApiClient.patch(
      '${ApiConstants.reportesProgramados}/$id',
      body: {'revision': revision, 'cambios': cambios},
    );
  }

  static Future<List<Map<String, dynamic>>> ejecuciones(int id) async =>
      (await ApiClient.get(
        '${ApiConstants.reportesProgramados}/$id/ejecuciones',
      ) as List).cast<Map<String, dynamic>>();
}
