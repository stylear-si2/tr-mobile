import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../core/storage/base_offline.dart';
import '../../core/storage/sesion_offline.dart';
import '../../services/sincronizacion_offline.dart';

class AccesoOfflineScreen extends StatefulWidget {
  final Widget? contenido;
  final Future<void> Function()? alDesbloquear;
  const AccesoOfflineScreen({
    this.contenido,
    this.alDesbloquear,
    super.key,
    required this.sesion,
    required this.reconectar,
    required this.salir,
  });

  final SesionOffline sesion;
  final Future<void> Function() reconectar;
  final Future<void> Function() salir;

  @override
  State<AccesoOfflineScreen> createState() => _AccesoOfflineScreenState();
}

class _AccesoOfflineScreenState extends State<AccesoOfflineScreen> {
  bool _desbloqueado = false;
  bool _ocupado = false;
  String? _error;
  late final Timer _vencimiento;
  late final StreamSubscription<List<ConnectivityResult>> _conexion;

  @override
  void initState() {
    super.initState();
    _vencimiento = Timer(widget.sesion.vence.difference(DateTime.now()), () {
      if (mounted) {
        setState(() => _desbloqueado = false);
        unawaited(widget.salir());
      }
    });
    _conexion = Connectivity().onConnectivityChanged.listen((estado) {
      if (_desbloqueado && !estado.contains(ConnectivityResult.none)) {
        unawaited(_reconectar());
      }
    });
  }

  Future<void> _reconectar() async {
    if (_ocupado) return;
    setState(() => _ocupado = true);
    try {
      await widget.reconectar();
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _desbloquear() async {
    if (_ocupado || !widget.sesion.vigente) return;
    setState(() {
      _ocupado = true;
      _error = null;
    });
    try {
      final ok = await SesionOffline.desbloquear();
      if (ok && widget.sesion.vigente) await widget.alDesbloquear?.call();
      if (mounted && widget.sesion.vigente) setState(() => _desbloqueado = ok);
    } on Exception {
      if (mounted) {
        setState(() => _error = 'No se pudo desbloquear el dispositivo.');
      }
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  @override
  void dispose() {
    _vencimiento.cancel();
    unawaited(_conexion.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_desbloqueado && widget.sesion.vigente) {
      if (widget.contenido != null) return widget.contenido!;
      return OperacionesOfflineScreen(
        sesion: widget.sesion,
        soloLocal: true,
        reconectar: _reconectar,
        salir: widget.salir,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Acceso sin conexión')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            widget.sesion.empresa.nombre,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            widget.sesion.vigente
                ? 'Desbloquea el dispositivo para ver tu catálogo e historial guardados.'
                : 'El acceso local venció. Conéctate para iniciar sesión.',
          ),
          if (_error != null) Text(_error!),
          FilledButton(
            onPressed: _ocupado || !widget.sesion.vigente ? null : _desbloquear,
            child: const Text('Desbloquear'),
          ),
          TextButton(
            onPressed: _ocupado ? null : _reconectar,
            child: const Text('Conectar con StyleAR'),
          ),
          TextButton(
            onPressed: _ocupado ? null : widget.salir,
            child: const Text('Cerrar sesión local'),
          ),
        ],
      ),
    );
  }
}

class OperacionesOfflineScreen extends StatefulWidget {
  const OperacionesOfflineScreen({
    super.key,
    required this.sesion,
    this.soloLocal = false,
    this.reconectar,
    this.salir,
  });

  final SesionOffline sesion;
  final bool soloLocal;
  final Future<void> Function()? reconectar;
  final Future<void> Function()? salir;

  @override
  State<OperacionesOfflineScreen> createState() =>
      _OperacionesOfflineScreenState();
}

class _OperacionesOfflineScreenState extends State<OperacionesOfflineScreen> {
  final _base = BaseOffline.instancia;
  final _sync = SincronizacionOffline.instancia;
  final _seleccion = <int, int>{};
  List<Map<String, Object?>> _sucursales = [];
  List<Map<String, Object?>> _variantes = [];
  List<Map<String, Object?>> _historial = [];
  List<Map<String, Object?>> _operaciones = [];
  int? _sucursal;
  DateTime? _cita;
  bool _efectivo = false;
  bool _guardando = false;
  bool _sincronizando = false;
  String _busqueda = '';
  String? _aviso;
  String _uuid = const Uuid().v4();
  int _lectura = 0;
  late final StreamSubscription<void> _cambios;

  String get _ambito => widget.sesion.ambito;
  String get _tipo => widget.sesion.puedeVender ? 'VENTA' : 'RESERVA';
  int get _total => _variantes.fold(
    0,
    (total, v) =>
        total + ((v['precio'] as int?) ?? 0) * (_seleccion[v['id']] ?? 0),
  );

  @override
  void initState() {
    super.initState();
    _cambios = _sync.cambios.stream.listen((_) => unawaited(_cargar()));
    unawaited(_cargar());
    if (!widget.soloLocal) unawaited(_sincronizar());
  }

  @override
  void dispose() {
    unawaited(_cambios.cancel());
    super.dispose();
  }

  Future<void> _cargar() async {
    final lectura = ++_lectura;
    try {
      final ambitoDatos = widget.sesion.ambitoDatos;
      final sucursales = await _base.sucursales(ambitoDatos);
      final ids = sucursales.map((s) => s['id']);
      final sucursal = ids.contains(_sucursal)
          ? _sucursal
          : ids.firstOrNull as int?;
      final variantes = sucursal == null
          ? <Map<String, Object?>>[]
          : await _base.variantes(ambitoDatos, sucursal);
      final historial = await _base.historial(ambitoDatos);
      final operaciones = await _base.operaciones(_ambito);
      if (!mounted || lectura != _lectura) return;
      setState(() {
        if (sucursal != _sucursal) _reiniciar();
        _sucursales = sucursales;
        _sucursal = sucursal;
        if (_seleccion.isEmpty) _variantes = variantes;
        _historial = historial;
        _operaciones = operaciones;
      });
    } on Exception {
      if (mounted) {
        setState(
          () => _aviso = 'No se pudieron leer los datos de este dispositivo.',
        );
      }
    }
  }

  Future<void> _sincronizar({bool manual = false}) async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    try {
      if (widget.soloLocal) {
        await widget.reconectar?.call();
      } else {
        await _sync.ejecutar(widget.sesion, manual: manual);
        if (mounted) {
          setState(() => _aviso = null);
        }
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _aviso =
              'Datos guardados. Revisa tu conexión y vuelve a sincronizar.',
        );
      }
    } finally {
      if (mounted) setState(() => _sincronizando = false);
    }
  }

  void _reiniciar() {
    _seleccion.clear();
    _efectivo = false;
    _cita = null;
    _uuid = const Uuid().v4();
  }

  Future<void> _guardar() async {
    if (_guardando ||
        _seleccion.isEmpty ||
        _sucursal == null ||
        (widget.soloLocal && !widget.sesion.vigente)) {
      return;
    }
    if (widget.sesion.puedeVender ? !_efectivo : _cita == null) return;
    setState(() => _guardando = true);
    final datos = <String, dynamic>{
      'clave_operacion': _uuid,
      'sucursal_id': _sucursal,
      'items': [
        for (final v in _variantes)
          if (_seleccion.containsKey(v['id']))
            {
              'producto_variante_id': v['id'],
              'cantidad': _seleccion[v['id']],
              if (widget.sesion.puedeVender) 'precio_centavos': v['precio'],
            },
      ],
      if (widget.sesion.puedeVender) ...{
        'metodo_pago': 'EFECTIVO',
        'efectivo_centavos': _total,
      } else
        'fecha_cita': DateFormat('yyyy-MM-dd').format(_cita!),
    };
    try {
      await _base.registrar(_ambito, _uuid, _tipo, _sucursal!, datos);
      if (!mounted) return;
      setState(() {
        _reiniciar();
        _aviso = 'Operación guardada. Pendiente de confirmación del servidor.';
      });
      await _cargar();
      if (mounted && !widget.soloLocal) {
        unawaited(_sincronizar());
      }
    } on Exception {
      if (mounted) {
        setState(
          () => _aviso = 'No se pudo guardar. Reintenta la misma operación.',
        );
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _elegirFecha() async {
    final hoy = DateUtils.dateOnly(DateTime.now());
    final cita = await showDatePicker(
      context: context,
      firstDate: hoy,
      lastDate: DateTime(hoy.year, hoy.month, hoy.day + 7),
      initialDate: _cita ?? hoy,
    );
    if (mounted && cita != null) setState(() => _cita = cita);
  }

  void _cantidad(Map<String, Object?> v, int cambio) {
    final id = v['id'] as int;
    final cantidad = (_seleccion[id] ?? 0) + cambio;
    setState(() {
      if (cantidad == 0) {
        _seleccion.remove(id);
      } else {
        _seleccion[id] = cantidad;
      }
      _efectivo = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final actualizada =
        _sucursales
                .where((s) => s['id'] == _sucursal)
                .firstOrNull?['actualizado']
            as String?;
    final fecha = actualizada == null
        ? null
        : DateTime.tryParse(actualizada)?.toLocal();
    final visibles = _variantes
        .where(
          (v) => '${v['nombre']} ${v['talla']} ${v['color']}'
              .toLowerCase()
              .contains(_busqueda),
        )
        .toList();
    final confirmadas = _historial
        .map((fila) => '${fila['tipo']}:${fila['id']}')
        .toSet();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Operaciones offline'),
        actions: [
          IconButton(
            tooltip: 'Sincronizar',
            onPressed: _sincronizando ? null : () => _sincronizar(manual: true),
            icon: const Icon(Icons.sync),
          ),
          if (widget.salir != null)
            IconButton(
              tooltip: 'Cerrar sesión local',
              onPressed: widget.salir,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            if (_sincronizando) const LinearProgressIndicator(),
            if (_aviso != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(_aviso!)),
            const TabBar(
              tabs: [
                Tab(text: 'Catálogo y registro'),
                Tab(text: 'Historial'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              fecha == null
                                  ? 'Descarga el catálogo con conexión para comenzar.'
                                  : 'Última descarga: ${DateFormat('dd/MM/yyyy HH:mm').format(fecha)}. El stock y el precio pueden haber cambiado.',
                            ),
                            DropdownButton<int>(
                              value: _sucursal,
                              isExpanded: true,
                              hint: const Text('Sucursal'),
                              items: [
                                for (final s in _sucursales)
                                  DropdownMenuItem(
                                    value: s['id'] as int,
                                    child: Text(s['nombre'] as String),
                                  ),
                              ],
                              onChanged: _guardando
                                  ? null
                                  : (id) {
                                      setState(() {
                                        _sucursal = id;
                                        _variantes = [];
                                        _reiniciar();
                                      });
                                      unawaited(_cargar());
                                    },
                            ),
                            TextField(
                              decoration: const InputDecoration(
                                labelText: 'Buscar en el catálogo descargado',
                              ),
                              onChanged: (valor) => setState(
                                () => _busqueda = valor.trim().toLowerCase(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: visibles.length,
                          itemBuilder: (_, index) => _variante(visibles[index]),
                        ),
                      ),
                      if (_seleccion.isNotEmpty) ...[
                        Text(
                          'Total estimado: Bs ${(_total / 100).toStringAsFixed(2)}',
                        ),
                        if (widget.sesion.puedeVender)
                          CheckboxListTile(
                            title: const Text(
                              'Recibí este importe en efectivo',
                            ),
                            value: _efectivo,
                            onChanged: _guardando
                                ? null
                                : (v) => setState(() => _efectivo = v ?? false),
                          )
                        else
                          OutlinedButton(
                            onPressed: _guardando ? null : _elegirFecha,
                            child: Text(
                              _cita == null
                                  ? 'Elegir fecha de la reserva'
                                  : DateFormat('dd/MM/yyyy').format(_cita!),
                            ),
                          ),
                        FilledButton(
                          onPressed:
                              _guardando ||
                                  (widget.sesion.puedeVender
                                      ? !_efectivo
                                      : _cita == null)
                              ? null
                              : _guardar,
                          child: Text(
                            widget.sesion.puedeVender
                                ? 'Guardar venta de contado'
                                : 'Guardar reserva',
                          ),
                        ),
                      ],
                    ],
                  ),
                  ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final fila in _operaciones)
                        if (!confirmadas.contains(
                          '${fila['tipo']}:${fila['remoto']}',
                        ))
                          _operacion(fila),
                      for (final fila in _historial) _confirmada(fila),
                      if (_operaciones.isEmpty && _historial.isEmpty)
                        const Text('Aún no hay operaciones guardadas.'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _variante(Map<String, Object?> v) {
    final unidades = _seleccion[v['id']] ?? 0;
    final disponible = v['stock'] as int;
    final precio = v['precio'] as int?;
    final limite = widget.sesion.puedeVender
        ? disponible
        : disponible.clamp(0, 2);
    return ListTile(
      title: Text(v['nombre'] as String),
      subtitle: Text(
        '${v['talla'] ?? ''} ${v['color'] ?? ''} · Stock conocido: $disponible · ${precio == null ? 'Sin precio' : 'Bs ${(precio / 100).toStringAsFixed(2)}'}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Quitar una unidad',
            onPressed: _guardando || unidades == 0
                ? null
                : () => _cantidad(v, -1),
            icon: const Icon(Icons.remove),
          ),
          Text('$unidades'),
          IconButton(
            tooltip: 'Agregar una unidad',
            onPressed:
                _guardando ||
                    precio == null ||
                    unidades >= limite ||
                    (unidades == 0 && _seleccion.length >= 100)
                ? null
                : () => _cantidad(v, 1),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Widget _operacion(Map<String, Object?> fila) {
    final venta = fila['tipo'] == 'VENTA';
    final rechazada = ['RECHAZADA', 'EN CONFLICTO'].contains(fila['estado']);
    final devuelto = fila['efectivo_devuelto'] == 1;
    final datos = jsonDecode(fila['datos'] as String) as Map<String, dynamic>;
    final importe = datos['efectivo_centavos'] as int?;
    final estado = fila['estado'] == 'ENVIANDO' && !_sincronizando
        ? 'PENDIENTE'
        : fila['estado'];
    return ListTile(
      title: Text('${venta ? 'Venta de contado' : 'Reserva'} · $estado'),
      subtitle: Text(
        [
          'Referencia: ${fila['uuid']}',
          if (importe != null)
            'Efectivo recibido: Bs ${(importe / 100).toStringAsFixed(2)}',
          if (fila['motivo'] != null) fila['motivo'] as String,
          if (devuelto) 'Efectivo devuelto',
        ].join('\n'),
      ),
      trailing: venta && rechazada && !devuelto
          ? TextButton(
              onPressed: () async {
                final confirmar = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Registrar devolución de efectivo'),
                    content: const Text(
                      'Confirma únicamente después de devolver el efectivo al cliente.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancelar'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Ya devolví el efectivo'),
                      ),
                    ],
                  ),
                );
                if (confirmar != true || !mounted) return;
                await _base.actualizar(_ambito, fila['uuid'] as String, {
                  'efectivo_devuelto': 1,
                });
                await _cargar();
              },
              child: const Text('Marcar devuelto'),
            )
          : null,
    );
  }

  Widget _confirmada(Map<String, Object?> fila) {
    final datos = jsonDecode(fila['datos'] as String) as Map<String, dynamic>;
    final detalles = datos['detalles'] as List? ?? const [];
    final titulo = switch (fila['tipo']) {
      'VENTA' => 'Venta',
      'RESERVA' => 'Reserva',
      _ => 'Pago',
    };
    return ExpansionTile(
      title: Text('$titulo · ${datos['codigo'] ?? fila['id']}'),
      subtitle: Text(
        '${datos['estado'] ?? 'Registrada'} · ${datos['fecha_venta'] ?? datos['fecha_reserva'] ?? ''}',
      ),
      children: [
        if (datos['total'] != null)
          ListTile(title: Text('Total: Bs ${datos['total']}')),
        for (final d in detalles)
          ListTile(
            title: Text(
              '${d['producto'] ?? d['producto_nombre'] ?? d['producto_variante_id'] ?? 'Variante'}',
            ),
            subtitle: Text('Cantidad: ${d['cantidad']}'),
          ),
      ],
    );
  }
}
