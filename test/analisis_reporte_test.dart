import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_tr/core/constants/api_constants.dart';
import 'package:mobile_tr/core/network/api_client.dart';
import 'package:mobile_tr/core/session/contexto_sesion.dart';
import 'package:mobile_tr/models/empresa_models.dart';
import 'package:mobile_tr/models/reporte_models.dart';
import 'package:mobile_tr/screens/reportes/analisis_reporte_panel.dart';
import 'package:mobile_tr/screens/reportes/grafico_reporte_ia.dart';

const filtros = ReporteFiltros(
  tipo: TipoReporte.ingresosPorCategoria,
  fechaDesde: '2026-11-01',
  fechaHasta: '2026-11-10',
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ApiConstants.customHost = 'http://127.0.0.1:58127';
    await ContextoSesion.instance.seleccionar(
      const EmpresaPublica(
        id: 1,
        codigo: 'demo',
        nombre: 'Demo',
        estado: 'ACTIVA',
      ),
    );
  });
  tearDown(() => ApiClient.client.close());

  testWidgets(
    'muestra narrativa y control de audio después de solicitar el análisis',
    (tester) async {
      var solicitudes = 0;
      String? grafico;
      ApiClient.client = MockClient((req) async {
        solicitudes++;
        expect(req.url.path.endsWith('/reportes/analizar'), isTrue);
        expect(jsonDecode(req.body)['tipo'], 'INGRESOS_POR_CATEGORIA');
        return http.Response(
          jsonEncode({
            'id': 'b76ef1c1-a87a-4ad2-887a-c12a75687c91',
            'narrativa': 'Poleras registra el mayor importe del período.',
            'conclusiones': ['Revisa los importes en la tabla.'],
            'grafico': 'DONA',
            'motivo_grafico': 'Representa la participación por categoría.',
            'motor': 'GEMINI',
            'advertencias': [],
            'audio_disponible': true,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnalisisReportePanel(
                filtros: filtros,
                habilitado: true,
                vozHabilitada: true,
                onResultado: (a) => grafico = a?.grafico,
              ),
            ),
          ),
        ),
      );
      expect(solicitudes, 0);
      await tester.tap(find.text('Analizar con IA'));
      await tester.pumpAndSettle();
      expect(solicitudes, 1);
      expect(grafico, 'DONA');
      expect(
        find.text(
          'Poleras registra el mayor importe del período.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Escuchar análisis'), findsOneWidget);
      expect(grafico, 'DONA');
      expect(solicitudes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no muestra una respuesta que llega después de cambiar de empresa',
    (tester) async {
      ApiClient.client = MockClient((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response(
          jsonEncode({
            'id': 'anterior',
            'narrativa': 'Datos de otra sesión',
            'grafico': 'BARRAS',
            'motivo_grafico': 'Comparación',
            'motor': 'GEMINI',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnalisisReportePanel(
              filtros: filtros,
              habilitado: true,
              vozHabilitada: true,
              onResultado: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Analizar con IA'));
      await tester.pump();
      await tester.runAsync(
        () => ContextoSesion.instance.seleccionar(
          const EmpresaPublica(
            id: 2,
            codigo: 'otra',
            nombre: 'Otra',
            estado: 'ACTIVA',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Datos de otra sesión'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final tipo in [
    'BARRAS',
    'LINEAS',
    'PASTEL',
    'DONA',
    'BARRAS_AGRUPADAS',
  ]) {
    testWidgets('gráfico $tipo cabe en celular y presenta sus valores', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GraficoReporteIA(
                tipo: tipo,
                titulo: 'Reporte',
                serie: const [
                  ReporteSerieItem(label: 'Poleras', valor: 100),
                  ReporteSerieItem(label: 'Camisas', valor: 50),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('1. Poleras: 100.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
