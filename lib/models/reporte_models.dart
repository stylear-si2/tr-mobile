/// Tipos de reporte disponibles (espejo exacto del backend)
enum TipoReporte {
  ventas('VENTAS', 'Ventas'),
  ventasPorSucursal('VENTAS_POR_SUCURSAL', 'Ventas por sucursal'),
  ingresosPorCategoria('INGRESOS_POR_CATEGORIA', 'Ingresos por categoría'),
  productosMasVendidos('PRODUCTOS_MAS_VENDIDOS', 'Productos más vendidos'),
  inventario('INVENTARIO', 'Inventario'),
  reservas('RESERVAS', 'Reservas'),
  movimientos('MOVIMIENTOS', 'Movimientos'),
  transferencias('TRANSFERENCIAS', 'Transferencias'),
  pagos('PAGOS', 'Pagos'),
  deliveries('DELIVERIES', 'Deliveries'),
  usuarios('USUARIOS', 'Usuarios');

  const TipoReporte(this.valor, this.etiqueta);
  final String valor;
  final String etiqueta;

  static TipoReporte? desdeValor(String v) {
    for (final t in values) {
      if (t.valor == v.toUpperCase()) return t;
    }
    return null;
  }
}

class ReporteFiltros {
  final TipoReporte tipo;
  final String fechaDesde; // yyyy-MM-dd
  final String fechaHasta; // yyyy-MM-dd
  final int? sucursalId;
  final String agrupacion; // DIA, SEMANA o MES
  final int? categoriaId;
  final int? productoId;
  final int limite;
  final bool soloBajoStock;
  final String? tipoVenta;
  final String? estado;
  final String? metodoPago;
  final String? proveedorPago;
  final String? tipoEntrega;
  final String? rol;
  final bool? activo;

  const ReporteFiltros({
    required this.tipo,
    required this.fechaDesde,
    required this.fechaHasta,
    this.sucursalId,
    this.agrupacion = 'DIA',
    this.categoriaId,
    this.productoId,
    this.limite = 10,
    this.soloBajoStock = false,
    this.tipoVenta,
    this.estado,
    this.metodoPago,
    this.proveedorPago,
    this.tipoEntrega,
    this.rol,
    this.activo,
  });

  Map<String, dynamic> toJson() => {
    'tipo': tipo.valor,
    'fecha_desde': fechaDesde,
    'fecha_hasta': fechaHasta,
    'sucursal_id': sucursalId,
    'agrupacion': agrupacion,
    'categoria_id': categoriaId,
    'producto_id': productoId,
    'limite': limite,
    'solo_bajo_stock': soloBajoStock,
    'tipo_venta': tipoVenta,
    'estado': estado,
    'metodo_pago': metodoPago,
    'proveedor_pago': proveedorPago,
    'tipo_entrega': tipoEntrega,
    'rol': rol,
    'activo': activo,
  };
}

class ReporteCatalogoItem {
  final String id;
  final String nombre;
  final int? categoriaId;

  const ReporteCatalogoItem({
    required this.id,
    required this.nombre,
    this.categoriaId,
  });

  factory ReporteCatalogoItem.fromJson(Map<String, dynamic> json) =>
      ReporteCatalogoItem(
        id: json['id']?.toString() ?? '',
        categoriaId: (json['categoria_id'] as num?)?.toInt(),
        nombre: json['nombre']?.toString() ?? '',
      );
}

class ReporteSucursalItem {
  final int id;
  final String nombre;
  final String ciudad;

  const ReporteSucursalItem({
    required this.id,
    required this.nombre,
    required this.ciudad,
  });

  factory ReporteSucursalItem.fromJson(Map<String, dynamic> json) =>
      ReporteSucursalItem(
        id: json['id'] is int ? json['id'] : int.parse(json['id'].toString()),
        nombre: json['nombre']?.toString() ?? '',
        ciudad: json['ciudad']?.toString() ?? '',
      );
}

class ReporteCatalogo {
  final List<ReporteCatalogoItem> tipos;
  final List<ReporteSucursalItem> sucursales;
  final List<ReporteCatalogoItem> categorias;
  final List<ReporteCatalogoItem> productos;

  const ReporteCatalogo({
    required this.tipos,
    required this.sucursales,
    this.categorias = const [],
    this.productos = const [],
  });

  factory ReporteCatalogo.fromJson(Map<String, dynamic> json) {
    return ReporteCatalogo(
      categorias: (json['categorias'] as List? ?? [])
          .map(
            (e) => ReporteCatalogoItem.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      productos: (json['productos'] as List? ?? [])
          .map(
            (e) => ReporteCatalogoItem.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      tipos: (json['tipos'] as List<dynamic>? ?? [])
          .map((e) => ReporteCatalogoItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      sucursales: (json['sucursales'] as List<dynamic>? ?? [])
          .map((e) => ReporteSucursalItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ReporteIndicador {
  final String label;
  final num valor;

  const ReporteIndicador({required this.label, required this.valor});

  factory ReporteIndicador.fromJson(Map<String, dynamic> json) =>
      ReporteIndicador(
        label: json['label']?.toString() ?? '',
        valor: num.tryParse(json['valor'].toString()) ?? 0,
      );
}

class ReporteSerieItem {
  final String label;
  final num valor;

  const ReporteSerieItem({required this.label, required this.valor});

  factory ReporteSerieItem.fromJson(Map<String, dynamic> json) =>
      ReporteSerieItem(
        label: json['label']?.toString() ?? '',
        valor: num.tryParse(json['valor'].toString()) ?? 0,
      );
}

class ReporteColumna {
  final String key;
  final String label;

  const ReporteColumna({required this.key, required this.label});

  factory ReporteColumna.fromJson(Map<String, dynamic> json) => ReporteColumna(
    key: json['key']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
  );
}

class ReporteResultado {
  final String tipo;
  final String titulo;
  final String? nota;
  final String generadoEn;
  final List<ReporteIndicador> indicadores;
  final List<ReporteSerieItem> serieGrafico;
  final List<ReporteColumna> columnas;
  final List<Map<String, dynamic>> filas;
  final int totalFilas;
  final bool sinDatos;
  final int pagina, tamano;
  final Map<String, dynamic> resumen, filtrosEfectivos;

  const ReporteResultado({
    required this.tipo,
    required this.titulo,
    this.nota,
    required this.generadoEn,
    required this.indicadores,
    required this.serieGrafico,
    required this.columnas,
    required this.filas,
    required this.totalFilas,
    required this.sinDatos,
    this.pagina = 1,
    this.tamano = 20,
    this.resumen = const {},
    this.filtrosEfectivos = const {},
  });

  factory ReporteResultado.fromJson(Map<String, dynamic> json) {
    return ReporteResultado(
      tipo: json['tipo']?.toString() ?? '',
      titulo: json['titulo']?.toString() ?? '',
      nota: json['nota']?.toString(),
      generadoEn: json['generado_en']?.toString() ?? '',
      indicadores: (json['indicadores'] as List<dynamic>? ?? [])
          .map((e) => ReporteIndicador.fromJson(e as Map<String, dynamic>))
          .toList(),
      serieGrafico: (json['serie_grafico'] as List<dynamic>? ?? [])
          .map((e) => ReporteSerieItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      columnas: (json['columnas'] as List<dynamic>? ?? [])
          .map((e) => ReporteColumna.fromJson(e as Map<String, dynamic>))
          .toList(),
      filas: (json['filas'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      totalFilas: json['total_filas'] is int
          ? json['total_filas']
          : int.tryParse(json['total_filas']?.toString() ?? '0') ?? 0,
      sinDatos: json['sin_datos'] == true,
      pagina: (json['pagina'] as num?)?.toInt() ?? 1,
      tamano: (json['tamano'] as num?)?.toInt() ?? 20,
      resumen: Map<String, dynamic>.from(json['resumen'] as Map? ?? {}),
      filtrosEfectivos: Map<String, dynamic>.from(
        json['filtros_efectivos'] as Map? ?? {},
      ),
    );
  }
}

class ReporteProgramadoItem {
  final int id;
  final String titulo;
  final String tipo;
  final String frecuencia;
  final String hora;
  final String? dia;
  final String formato;
  final String destinatarioEmail;
  final int? sucursalId;
  final String? sucursalNombre;
  final bool soloBajoStock;
  final bool activo;
  final int revision;
  final String zonaHoraria, periodo;
  final String? motivoPausa;
  final Map<String, dynamic> filtros;
  final String? ultimaEjecucion;
  final String? proximaEjecucion;

  const ReporteProgramadoItem({
    required this.id,
    required this.titulo,
    required this.tipo,
    required this.frecuencia,
    required this.hora,
    this.dia,
    required this.formato,
    required this.destinatarioEmail,
    this.sucursalId,
    this.sucursalNombre,
    required this.soloBajoStock,
    required this.activo,
    this.revision = 1,
    this.zonaHoraria = 'America/La_Paz',
    this.periodo = 'SEGUN_FRECUENCIA',
    this.motivoPausa,
    this.filtros = const {},
    this.ultimaEjecucion,
    this.proximaEjecucion,
  });

  factory ReporteProgramadoItem.fromJson(Map<String, dynamic> json) {
    return ReporteProgramadoItem(
      id: json['id'] is int
          ? json['id']
          : int.tryParse(json['id'].toString()) ?? 0,
      titulo: json['titulo']?.toString() ?? '',
      tipo: json['tipo']?.toString() ?? 'VENTAS',
      frecuencia: json['frecuencia']?.toString() ?? 'DIARIA',
      hora: json['hora']?.toString() ?? '08:00',
      dia: json['dia']?.toString(),
      formato: json['formato']?.toString() ?? 'PDF',
      destinatarioEmail: json['destinatario_email']?.toString() ?? '',
      sucursalId: json['sucursal_id'] != null
          ? (json['sucursal_id'] is int
                ? json['sucursal_id']
                : int.tryParse(json['sucursal_id'].toString()))
          : null,
      sucursalNombre: json['sucursal_nombre']?.toString(),
      soloBajoStock: json['solo_bajo_stock'] == true,
      activo: json['activo'] == true,
      revision: (json['revision'] as num?)?.toInt() ?? 1,
      zonaHoraria: json['zona_horaria'] as String? ?? 'America/La_Paz',
      periodo: json['periodo'] as String? ?? 'SEGUN_FRECUENCIA',
      motivoPausa: json['motivo_pausa'] as String?,
      filtros: Map<String, dynamic>.from(json['filtros'] as Map? ?? {}),
      ultimaEjecucion: json['ultima_ejecucion']?.toString(),
      proximaEjecucion: json['proxima_ejecucion']?.toString(),
    );
  }
}

class ReporteInterpretacionResultado {
  final bool interpretado;
  final Map<String, dynamic> filtros;
  final List<String> advertencias;

  const ReporteInterpretacionResultado({
    required this.interpretado,
    required this.filtros,
    required this.advertencias,
  });

  factory ReporteInterpretacionResultado.fromJson(Map<String, dynamic> json) {
    return ReporteInterpretacionResultado(
      interpretado: json['interpretado'] == true,
      filtros: json['filtros'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['filtros'])
          : {},
      advertencias: (json['advertencias'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}
