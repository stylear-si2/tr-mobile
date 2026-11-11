import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/base_offline.dart';
import '../../core/storage/sesion_offline.dart';

class CambiosOfflinePanel extends StatefulWidget {
  const CambiosOfflinePanel({
    super.key,
    required this.sesion,
    required this.alGuardar,
  });
  final SesionOffline sesion;
  final Future<void> Function() alGuardar;
  @override
  State<CambiosOfflinePanel> createState() => _CambiosOfflinePanelState();
}

class _CambiosOfflinePanelState extends State<CambiosOfflinePanel> {
  Map<String, dynamic>? _datos;
  String? _mensaje;
  bool _ocupada = false;
  final _base = BaseOffline.instancia;
  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final datos = await _base.contexto(widget.sesion.ambitoDatos);
    if (mounted) setState(() => _datos = datos);
  }

  Future<void> _solicitar(
    Map<String, dynamic> venta,
    Map<String, dynamic> linea,
  ) async {
    final vence = DateTime.tryParse(venta['vence_cambio'] as String? ?? '');
    if (vence == null || vence.isBefore(DateTime.now())) {
      setState(
        () => _mensaje =
            'El plazo conocido venció. Sincroniza para actualizar la política.',
      );
      return;
    }
    final variantes = await _base.variantes(
      widget.sesion.ambitoDatos,
      venta['sucursal_id'] as int,
    );
    if (!mounted) return;
    final motivo = TextEditingController();
    final cantidad = TextEditingController(text: '1');
    int? reemplazo;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('Cambiar ${linea['producto']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Disponibles para cambio: ${linea['cantidad_disponible']}. Plazo hasta ${venta['vence_cambio']}',
                ),
                TextField(
                  controller: cantidad,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Cantidad'),
                ),
                TextField(
                  controller: motivo,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Motivo del cambio',
                  ),
                ),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Reemplazo solicitado (opcional)',
                  ),
                  items: [
                    for (final v in variantes)
                      DropdownMenuItem(
                        value: v['id'] as int,
                        child: Text(
                          '${v['nombre']} · ${v['talla']} / ${v['color']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setDialog(() => reemplazo = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final n = int.tryParse(cantidad.text);
                if (n != null &&
                    n > 0 &&
                    n <= (linea['cantidad_disponible'] as int) &&
                    motivo.text.trim().length >= 5) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Guardar solicitud'),
            ),
          ],
        ),
      ),
    );
    final datos = <String, dynamic>{
      'clave_operacion': const Uuid().v4(),
      'venta_id': venta['venta_id'],
      'venta_detalle_id': linea['venta_detalle_id'],
      'cantidad': int.tryParse(cantidad.text),
      'motivo': motivo.text.trim(),
      'reemplazo_id': ?reemplazo,
    };
    motivo.dispose();
    cantidad.dispose();
    if (ok == true) {
      await _guardar('CAMBIO', venta['sucursal_id'] as int, datos);
    }
  }

  Future<void> _revisar(Map<String, dynamic> cambio) async {
    final condicion = TextEditingController();
    final noVendibles = TextEditingController(text: '0');
    bool recibida = false;
    final aceptar = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('Inspeccionar cambio ${cambio['id']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: condicion,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Condición de la prenda / rechazo',
                  ),
                ),
                TextField(
                  controller: noVendibles,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Unidades no vendibles',
                  ),
                ),
                CheckboxListTile(
                  value: recibida,
                  onChanged: (v) => setDialog(() => recibida = v ?? false),
                  title: const Text(
                    'Confirmo la recepción física e inspección',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () {
                if (condicion.text.trim().length >= 5) {
                  Navigator.pop(ctx, false);
                }
              },
              child: const Text('Guardar rechazo'),
            ),
            FilledButton(
              onPressed: recibida
                  ? () {
                      if (condicion.text.trim().length >= 5 &&
                          (int.tryParse(noVendibles.text) ?? -1) >= 0) {
                        Navigator.pop(ctx, true);
                      }
                    }
                  : null,
              child: const Text('Guardar aceptación'),
            ),
          ],
        ),
      ),
    );
    final datos = <String, dynamic>{
      'id': cambio['id'],
      'version': cambio['version'],
      'aceptar': aceptar,
      'condicion': condicion.text.trim(),
      'no_vendibles': int.tryParse(noVendibles.text) ?? 0,
      'recepcion_confirmada': recibida,
    };
    condicion.dispose();
    noVendibles.dispose();
    if (aceptar != null) {
      await _guardar(
        'REVISION_CAMBIO',
        (cambio['original'] as Map)['sucursal_id'] as int,
        datos,
      );
    }
  }

  Future<void> _guardar(
    String tipo,
    int sucursal,
    Map<String, dynamic> datos,
  ) async {
    if (!mounted || _ocupada || !widget.sesion.vigente) return;
    setState(() => _ocupada = true);
    try {
      final uuid = datos['clave_operacion'] as String? ?? const Uuid().v4();
      await _base.registrar(widget.sesion.ambito, uuid, tipo, sucursal, datos);
      if (mounted) {
        setState(
          () => _mensaje = 'Guardado. Pendiente de validación del servidor; los cobros requieren Internet.',
        );
      }
      await widget.alGuardar();
      if (mounted) await _cargar();
    } catch (_) {
      if (mounted) setState(() => _mensaje = 'No se pudo guardar el cambio.');
    } finally {
      if (mounted) setState(() => _ocupada = false);
    }
  }

  Future<void> _entregar(Map<String, dynamic> cambio) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Registrar entrega física'),
        content: const Text(
          'Confirma únicamente después de entregar el reemplazo. Quedará pendiente de validación del servidor.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ya entregué el reemplazo'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _guardar(
        'ENTREGA_CAMBIO',
        (cambio['original'] as Map)['sucursal_id'] as int,
        {
          'id': cambio['id'],
          'version': cambio['version'],
          'entrega_confirmada': true,
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ventas = (_datos?['ventas'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final cambios = (_datos?['cambios'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final habilitados =
        (_datos?['politica'] as Map?)?['cambios_habilitados'] == true;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Cambios de prendas',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'El plazo, stock y diferencia de precio se validan al reconectar. Una inspección guardada todavía no es una aprobación definitiva.',
        ),
        if (_mensaje != null) Text(_mensaje!),
        if (_datos == null)
          const Text(
            'Sincroniza con Internet para descargar compras y cambios.',
          ),
        if (!widget.sesion.puedeVender && !habilitados)
          const Text('La política descargada no permite nuevos cambios.'),
        if (!widget.sesion.puedeVender && habilitados)
          for (final venta in ventas)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${venta['venta_codigo']}'),
                    for (final linea
                        in (venta['detalles'] as List)
                            .cast<Map<String, dynamic>>())
                      if ((linea['cantidad_disponible'] as int) > 0)
                        ListTile(
                          title: Text(
                            '${linea['producto']} · ${linea['talla']} / ${linea['color']}',
                          ),
                          subtitle: Text(
                            'Cantidad elegible: ${linea['cantidad_disponible']}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Solicitar cambio',
                            onPressed: _ocupada
                                ? null
                                : () => _solicitar(venta, linea),
                            icon: const Icon(Icons.swap_horiz),
                          ),
                        ),
                  ],
                ),
              ),
            ),
        if (widget.sesion.puedeVender)
          for (final cambio in cambios)
            if (cambio['estado'] == 'SOLICITADO' || cambio['estado'] == 'LISTO')
              Card(
                child: ListTile(
                  title: Text('Cambio ${cambio['id']}'),
                  subtitle: Text('${(cambio['original'] as Map)['motivo']}'),
                  trailing: IconButton(
                    tooltip: cambio['estado'] == 'LISTO'
                        ? 'Registrar entrega'
                        : 'Registrar inspección',
                    onPressed: _ocupada
                        ? null
                        : () => cambio['estado'] == 'LISTO'
                              ? _entregar(cambio)
                              : _revisar(cambio),
                    icon: const Icon(Icons.fact_check_outlined),
                  ),
                ),
              ),
        if (ventas.isEmpty && !widget.sesion.puedeVender)
          const Text('No hay compras elegibles descargadas.'),
        if (cambios.isEmpty && widget.sesion.puedeVender)
          const Text('No hay solicitudes descargadas para inspeccionar.'),
      ],
    );
  }
}
