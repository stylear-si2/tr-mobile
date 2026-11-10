import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_tr/models/reporte_models.dart';

void main() {
  test('mantiene tipos nuevos y filtros comerciales en la consulta', () {
    const filtros = ReporteFiltros(
      tipo: TipoReporte.ventasPorSucursal,
      fechaDesde: '2026-09-01',
      fechaHasta: '2026-11-10',
      agrupacion: 'SEMANA',
      categoriaId: 8,
      productoId: 12,
      limite: 5,
    );
    final json = filtros.toJson();
    expect(json['tipo'], 'VENTAS_POR_SUCURSAL');
    expect(json['agrupacion'], 'SEMANA');
    expect(json['categoria_id'], 8);
    expect(json['producto_id'], 12);
    expect(json['limite'], 5);
    expect(
      TipoReporte.desdeValor('INGRESOS_POR_CATEGORIA'),
      TipoReporte.ingresosPorCategoria,
    );
  });

  test(
    'lee el catálogo de filtros de la empresa y vincula productos a categorías',
    () {
      final catalogo = ReporteCatalogo.fromJson({
        'tipos': [],
        'sucursales': [],
        'categorias': [
          {'id': 8, 'nombre': 'Poleras'},
        ],
        'productos': [
          {'id': 12, 'nombre': 'Polera', 'categoria_id': 8},
        ],
      });
      expect(catalogo.categorias.single.id, '8');
      expect(catalogo.productos.single.categoriaId, 8);
    },
  );
}
