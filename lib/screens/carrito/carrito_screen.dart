import '../../core/network/api_client.dart';
import '../../core/constants/api_constants.dart';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_colors.dart';
import '../../core/network/api_exceptions.dart';
import '../../providers/auth_provider.dart';
import '../../providers/carrito_provider.dart';
import '../../providers/reserva_provider.dart';
import '../../models/catalogo_models.dart';
import '../../models/pago_models.dart';
import '../../core/session/contexto_sesion.dart';
import '../../models/delivery_models.dart';
import '../../services/delivery_service.dart';
import '../../services/pago_service.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/empty_state.dart';
import '../auth/login_screen.dart';
import 'pago_stripe_screen.dart';
import 'pago_qr_screen.dart';

class CarritoScreen extends StatefulWidget {
  final VoidCallback? onIrAlCatalogo;
  final VoidCallback? onIrAMisReservas;

  const CarritoScreen({super.key, this.onIrAlCatalogo, this.onIrAMisReservas});

  @override
  State<CarritoScreen> createState() => _CarritoScreenState();
}

class _CarritoScreenState extends State<CarritoScreen> {
  int? _sucursalSeleccionadaId;
  final _observacionCtrl = TextEditingController();
  final _direccionDeliveryCtrl = TextEditingController();
  final _referenciaDeliveryCtrl = TextEditingController();
  LatLng _ubicacionDelivery = const LatLng(-17.783327, -63.182140);
  late DateTime _fechaCitaReserva;
  bool _procesandoPago = false;
  bool _checkoutAbierto = false;
  bool _usaDelivery = false;
  bool _cotizandoDelivery = false;
  bool _buscandoUbicacion = false;
  DeliveryCotizacion? _cotizacionDelivery;
  bool _cotizacionAceptada = false;
  int _solicitudCotizacion = 0;
  List<Map<String, dynamic>> _direccionesEntrega = [];
  int? _direccionEntregaId;
  void _invalidarCotizacion() {
    _solicitudCotizacion++;
    _cotizacionDelivery = null;
    _cotizacionAceptada = false;
    _cotizandoDelivery = false;
  }

  Future<void> _cargarDireccionesEntrega() async {
    final gen = ContextoSesion.instance.generacion;
    try {
      final datos = await ApiClient.get(ApiConstants.perfilDirecciones);
      if (mounted && gen == ContextoSesion.instance.generacion) {
        setState(
          () => _direccionesEntrega =
              ((datos as Map<String, dynamic>)['direcciones'] as List)
                  .cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      if (mounted && gen == ContextoSesion.instance.generacion) {
        setState(() => _direccionesEntrega = []);
      }
    }
  }

  String _metodoPago = 'QR';
  OrdenPagoResponse? _pagoPendiente;
  int _generacionPago = 0;
  void _cambioSesionPago() {
    final sesion = ContextoSesion.instance;
    if (!mounted || sesion.generacion == _generacionPago) return;
    _generacionPago = sesion.generacion;
    setState(() {
      _pagoPendiente = null;
      _invalidarCotizacion();
      _direccionesEntrega = [];
      _direccionEntregaId = null;
    });
    if (sesion.usuario?.roles.contains('CLIENTE') ?? false) {
      _recuperarPago();
      _cargarDireccionesEntrega();
    }
  }

  Future<void> _recuperarPago() async {
    final gen = ContextoSesion.instance.generacion;
    try {
      final orden = await PagoService.pendiente();
      if (mounted && gen == ContextoSesion.instance.generacion) {
        setState(() => _pagoPendiente = orden);
      }
    } catch (_) {
      /* El historial permite reintentar la consulta. */
    }
  }

  Future<void> _abrirPendiente() async {
    final orden = _pagoPendiente;
    if (orden == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PagoStripeScreen(
          checkoutUrl: orden.checkoutUrl ?? '',
          ordenId: orden.ordenId,
        ),
      ),
    );
    if (!mounted) return;
    await _recuperarPago();
    if (mounted) context.read<CarritoProvider>().cargarCarrito();
  }

  @override
  void initState() {
    super.initState();
    _generacionPago = ContextoSesion.instance.generacion;
    ContextoSesion.instance.addListener(_cambioSesionPago);
    _fechaCitaReserva = _soloFecha(DateTime.now());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.estaAutenticado) {
        context.read<CarritoProvider>().cargarCarrito();
        _recuperarPago();
        _cargarDireccionesEntrega();
      }
    });
  }

  @override
  void dispose() {
    ContextoSesion.instance.removeListener(_cambioSesionPago);
    _observacionCtrl.dispose();
    _direccionDeliveryCtrl.dispose();
    _referenciaDeliveryCtrl.dispose();
    super.dispose();
  }

  int? _resolverSucursalActual(List<CatalogoSucursal> sucursales) {
    if (sucursales.isEmpty) return null;
    if (_sucursalSeleccionadaId != null &&
        sucursales.any((s) => s.id == _sucursalSeleccionadaId)) {
      return _sucursalSeleccionadaId;
    }
    return sucursales.first.id;
  }

  CatalogoSucursal? _sucursalPorId(List<CatalogoSucursal> sucursales, int? id) {
    if (id == null) return null;
    for (final sucursal in sucursales) {
      if (sucursal.id == id) return sucursal;
    }
    return null;
  }

  DeliveryCheckoutRequest? _deliveryRequest({bool exigirCotizacion = false}) {
    final sucursales = context.read<CarritoProvider>().sucursalesDisponibles;
    final sucursalId = _resolverSucursalActual(sucursales);
    final direccion = _direccionDeliveryCtrl.text.trim();
    if (!_usaDelivery) return null;
    if (sucursalId == null || direccion.length < 5) {
      return null;
    }
    if (exigirCotizacion &&
        (_cotizacionDelivery == null ||
            !_cotizacionDelivery!.disponible ||
            _cotizacionDelivery!.cotizacionId == null ||
            !_cotizacionAceptada)) {
      return null;
    }
    return DeliveryCheckoutRequest(
      direccionId: _direccionEntregaId,
      cotizacionId: exigirCotizacion ? _cotizacionDelivery?.cotizacionId : null,
      sucursalId: sucursalId,
      direccionEntrega: direccion,
      referencia: _referenciaDeliveryCtrl.text.trim(),
      latitudEntrega: _ubicacionDelivery.latitude,
      longitudEntrega: _ubicacionDelivery.longitude,
      distanciaKm: _cotizacionDelivery?.distanciaKm,
      tiempoEstimadoMin: _cotizacionDelivery?.tiempoEstimadoMin,
      costoDelivery: _cotizacionDelivery?.costoDelivery,
    );
  }

  bool _excedeMaximoReserva() {
    return context.read<CarritoProvider>().items.any(
      (item) => item.paqueteId != null || item.cantidad > 2,
    );
  }

  double _montoReserva() => 0;

  DateTime _soloFecha(DateTime fecha) =>
      DateTime(fecha.year, fecha.month, fecha.day);

  String _fechaApi(DateTime fecha) {
    final month = fecha.month.toString().padLeft(2, '0');
    final day = fecha.day.toString().padLeft(2, '0');
    return '${fecha.year}-$month-$day';
  }

  String _fechaVista(DateTime fecha) =>
      DateFormat('dd/MM/yyyy', 'es_BO').format(fecha);

  Future<void> _seleccionarFechaCita() async {
    final hoy = _soloFecha(DateTime.now());
    final seleccion = await showDatePicker(
      context: context,
      initialDate: _fechaCitaReserva.isBefore(hoy) ? hoy : _fechaCitaReserva,
      firstDate: hoy,
      lastDate: hoy.add(const Duration(days: 7)),
      locale: const Locale('es', 'BO'),
    );
    if (seleccion != null && mounted) {
      setState(() => _fechaCitaReserva = _soloFecha(seleccion));
    }
  }

  Future<void> _cotizarDelivery() async {
    final request = _deliveryRequest();
    if (request == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Completa la dirección y selecciona una sucursal con stock para cotizar delivery.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _invalidarCotizacion();
      _cotizandoDelivery = true;
    });
    final solicitud = _solicitudCotizacion;
    try {
      final cotizacion = await DeliveryService.cotizar(request);
      if (!mounted || solicitud != _solicitudCotizacion) return;
      setState(() => _cotizacionDelivery = cotizacion);
      if (!cotizacion.disponible) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cotizacion.mensaje ?? 'Dirección fuera del rango de delivery.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted || solicitud != _solicitudCotizacion) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: AppColors.danger,
        ),
      );
    } finally {
      if (mounted && solicitud == _solicitudCotizacion) {
        setState(() => _cotizandoDelivery = false);
      }
    }
  }

  Future<void> _buscarUbicacionDelivery() async {
    final direccion = _direccionDeliveryCtrl.text.trim();
    if (direccion.length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Escribe una dirección más completa para buscarla en el mapa.',
          ),
        ),
      );
      return;
    }

    setState(() => _buscandoUbicacion = true);
    try {
      final resultado = await DeliveryService.geocodificar(direccion);
      if (!mounted || _direccionDeliveryCtrl.text.trim() != direccion) return;
      setState(() {
        _ubicacionDelivery = LatLng(resultado.latitud, resultado.longitud);
        if (resultado.direccion.isNotEmpty) {
          _direccionDeliveryCtrl.text = resultado.direccion;
        }
        _invalidarCotizacion();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: AppColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _buscandoUbicacion = false);
    }
  }

  Future<void> _confirmarReserva() async {
    final sucursales = context.read<CarritoProvider>().sucursalesDisponibles;
    final sucursalId = _resolverSucursalActual(sucursales);

    if (sucursalId == null) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Por favor selecciona una sucursal para el retiro de tu reserva.',
          ),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (_excedeMaximoReserva()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Para reservar solo puedes apartar hasta 2 unidades de la misma prenda.',
          ),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }

    final reservaProv = context.read<ReservaProvider>();
    if (context.read<CarritoProvider>().items.any(
      (i) => !i.disponibleParaCompra,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Retira las prendas que ya no están disponibles antes de reservar.',
          ),
        ),
      );
      return;
    }
    final nuevaReserva = await reservaProv.crearReservaDesdeCarrito(
      sucursalId: sucursalId,
      fechaCita: _fechaApi(_fechaCitaReserva),
      observacion: _observacionCtrl.text,
    );

    if (nuevaReserva != null && mounted) {
      // Recargar carrito (debería quedar vacío)
      context.read<CarritoProvider>().cargarCarrito();

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                color: AppColors.success,
                size: 28,
              ),
              SizedBox(width: 10),
              Text('¡Reserva Confirmada!'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tu reserva ha sido registrada exitosamente con código:',
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  nuevaReserva.codigo,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    color: AppColors.accent,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Sucursal de retiro: ${nuevaReserva.sucursal} (${nuevaReserva.ciudad})',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Cita: ${_fechaVista(_fechaCitaReserva)} · Sin anticipo: ${NumberFormat.currency(locale: 'es_BO', symbol: 'Bs. ').format(nuevaReserva.montoReserva)}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Reserva gratuita durante 7 días. Consulta el vencimiento en Mis reservas.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                if (widget.onIrAMisReservas != null) {
                  widget.onIrAMisReservas!();
                }
              },
              child: const Text('Ver Mis Reservas'),
            ),
          ],
        ),
      );
    } else if (mounted && reservaProv.error != null) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(reservaProv.error!),
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _pagarConQr() async {
    final sucursales = context.read<CarritoProvider>().sucursalesDisponibles;
    final sucursalId = _resolverSucursalActual(sucursales);

    if (sucursalId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No hay una sucursal con stock suficiente para pagar este carrito.',
          ),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }

    setState(() => _procesandoPago = true);

    try {
      final delivery = _deliveryRequest(exigirCotizacion: true);
      if (_usaDelivery && delivery == null) {
        throw ApiException('Completa y cotiza el delivery antes de pagar.');
      }

      final checkout = await PagoService.crearCheckoutQr(
        sucursalId: sucursalId,
        tipoEntrega: _usaDelivery ? 'DELIVERY' : 'RECOJO_SUCURSAL',
        delivery: delivery,
        totalEsperado:
            context.read<CarritoProvider>().totalMonto +
            (_usaDelivery ? (_cotizacionDelivery?.costoDelivery ?? 0) : 0),
      );

      if (!mounted) return;

      final orden = await Navigator.of(context).push<dynamic>(
        MaterialPageRoute(builder: (_) => PagoQrScreen(checkout: checkout)),
      );

      if (mounted && orden != null) {
        context.read<CarritoProvider>().cargarCarrito();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al generar el QR de pago: $e'),
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _procesandoPago = false;
          _invalidarCotizacion();
        });
      }
    }
  }

  Future<void> _pagarConStripe() async {
    final sucursales = context.read<CarritoProvider>().sucursalesDisponibles;
    final sucursalId = _resolverSucursalActual(sucursales);

    if (sucursalId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No hay una sucursal con stock suficiente para pagar este carrito.',
          ),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }

    setState(() => _procesandoPago = true);

    try {
      final delivery = _deliveryRequest(exigirCotizacion: true);
      if (_usaDelivery && delivery == null) {
        throw ApiException('Completa y cotiza el delivery antes de pagar.');
      }

      final checkout = await PagoService.crearCheckoutStripe(
        sucursalId: sucursalId,
        tipoEntrega: _usaDelivery ? 'DELIVERY' : 'RECOJO_SUCURSAL',
        delivery: delivery,
        totalEsperado:
            context.read<CarritoProvider>().totalMonto +
            (_usaDelivery ? (_cotizacionDelivery?.costoDelivery ?? 0) : 0),
      );

      if (!mounted) return;

      // Abre el WebView de Stripe y espera el resultado
      final orden = await Navigator.of(context).push<dynamic>(
        MaterialPageRoute(
          builder: (_) => PagoStripeScreen(
            checkoutUrl: checkout.checkoutUrl,
            ordenId: checkout.ordenId,
          ),
        ),
      );

      // Si el pago fue exitoso, vaciamos el carrito y notificamos
      if (mounted && orden != null) {
        context.read<CarritoProvider>().cargarCarrito();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al iniciar el pago. Intenta nuevamente.'),
          backgroundColor: AppColors.danger,
          duration: Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _procesandoPago = false;
          _invalidarCotizacion();
        });
      }
    }
  }

  Widget _buildDeliveryMap(CatalogoSucursal? sucursal) {
    final sucursalTieneCoordenadas =
        sucursal?.latitud != null && sucursal?.longitud != null;
    final sucursalPoint = sucursalTieneCoordenadas
        ? LatLng(sucursal!.latitud!, sucursal.longitud!)
        : null;
    final markers = <Marker>[
      if (sucursalPoint != null)
        Marker(
          point: sucursalPoint,
          width: 42,
          height: 42,
          child: const Icon(
            Icons.storefront,
            color: AppColors.primary,
            size: 32,
          ),
        ),
      Marker(
        point: _ubicacionDelivery,
        width: 42,
        height: 42,
        child: const Icon(Icons.location_on, color: AppColors.danger, size: 36),
      ),
    ];

    final center = sucursalPoint == null
        ? _ubicacionDelivery
        : LatLng(
            (sucursalPoint.latitude + _ubicacionDelivery.latitude) / 2,
            (sucursalPoint.longitude + _ubicacionDelivery.longitude) / 2,
          );

    return Container(
      height: 220,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: FlutterMap(
        key: ValueKey(
          '${sucursal?.id ?? 0}-${_ubicacionDelivery.latitude}-${_ubicacionDelivery.longitude}',
        ),
        options: MapOptions(
          initialCenter: center,
          initialZoom: 13,
          onTap: (_, point) {
            setState(() {
              _ubicacionDelivery = point;
              _invalidarCotizacion();
              if (_direccionDeliveryCtrl.text.trim().isEmpty) {
                _direccionDeliveryCtrl.text =
                    'Ubicación seleccionada en el mapa';
              }
            });
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.stylear.mobile',
          ),
          if (_cotizacionDelivery?.ruta.isNotEmpty ?? false)
            PolylineLayer(
              polylines: [
                Polyline(
                  points: _cotizacionDelivery!.ruta
                      .map((p) => LatLng(p[1], p[0]))
                      .toList(),
                  color: AppColors.primary,
                  strokeWidth: 4,
                ),
              ],
            ),
          MarkerLayer(markers: markers),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final carrito = context.watch<CarritoProvider>();
    final currencyFormat = NumberFormat.currency(
      locale: 'es_BO',
      symbol: 'Bs. ',
    );

    if (!auth.estaAutenticado) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mi Carrito')),
        body: EmptyState(
          icon: Icons.shopping_bag_outlined,
          title: 'Inicia sesión para ver tu carrito',
          subtitle: 'Guarda tus prendas preferidas y realiza tus reservas desde cualquier dispositivo.',
          actionText: 'Iniciar Sesión',
          onAction: () {
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const LoginScreen()));
          },
        ),
      );
    }

    if (carrito.cargando && carrito.items.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (carrito.items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mi Carrito')),
        body: EmptyState(
          icon: Icons.remove_shopping_cart_outlined,
          title: 'Tu carrito está vacío',
          subtitle: 'Explora nuestro catálogo y agrega tus prendas favoritas para reservarlas.',
          actionText: 'Explorar Catálogo',
          onAction: widget.onIrAlCatalogo,
        ),
      );
    }

    final sucursales = carrito.sucursalesDisponibles;
    final sucursalActual = _resolverSucursalActual(sucursales);
    final sucursalSeleccionada = _sucursalPorId(sucursales, sucursalActual);
    final costoDelivery = _usaDelivery
        ? (_cotizacionDelivery?.costoDelivery ?? 0.0)
        : 0.0;
    final totalConDelivery = carrito.totalMonto + costoDelivery;
    final excedeMaximoReserva =
        !_usaDelivery &&
        carrito.items.any(
          (item) => item.paqueteId != null || item.cantidad > 2,
        );
    final puedeConfirmar = sucursalActual != null && !excedeMaximoReserva;

    return Scaffold(
      appBar: AppBar(
        title: Text('Mi Carrito (${carrito.cantidadTotal})'),
        actions: [
          TextButton.icon(
            icon: const Icon(
              Icons.delete_sweep_outlined,
              size: 18,
              color: AppColors.danger,
            ),
            label: const Text(
              'Vaciar',
              style: TextStyle(color: AppColors.danger, fontSize: 13),
            ),
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('¿Vaciar Carrito?'),
                  content: const Text(
                    'Se eliminarán todas las prendas añadidas.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Cancelar'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.danger,
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        carrito.vaciarCarrito();
                      },
                      child: const Text('Vaciar'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_pagoPendiente != null)
              ListTile(
                leading: const Icon(Icons.pending_actions),
                title: Text('Pago pendiente #${_pagoPendiente!.ordenId}'),
                subtitle: const Text(
                  'Consulta o cancela el intento antes de iniciar otro.',
                ),
                trailing: TextButton(
                  onPressed: _abrirPendiente,
                  child: const Text('Consultar'),
                ),
              ),
            // Lista de items del carrito
            if (!_checkoutAbierto)
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: carrito.items.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final item = carrito.items[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Icono de prenda
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                color: AppColors.background,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.checkroom,
                                color: AppColors.primary,
                              ),
                            ),
                            const SizedBox(width: 14),

                            // Información
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${item.producto} · ${item.paqueteId == null ? 'Unidad' : '${item.tipoCompra} #${item.paqueteId}'}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Talla: ${item.talla} • Color: ${item.color}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.disponibleParaCompra
                                        ? currencyFormat.format(
                                            item.precioUnitario,
                                          )
                                        : item.motivoNoDisponible ?? 'No disponible: retira esta prenda',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Controles de Cantidad y Eliminar
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    size: 18,
                                    color: AppColors.textSecondary,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  tooltip: item.paqueteId == null
                                      ? 'Quitar producto'
                                      : 'Quitar paquete completo',
                                  onPressed: () =>
                                      carrito.eliminarItem(item.id),
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  decoration: BoxDecoration(
                                    color: AppColors.background,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      InkWell(
                                        onTap: item.paqueteId != null
                                            ? null
                                            : () => carrito.actualizarCantidad(
                                                item.id,
                                                item.cantidad - 1,
                                              ),
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 4,
                                          ),
                                          child: Icon(Icons.remove, size: 14),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        child: Text(
                                          '${item.cantidad}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      InkWell(
                                        onTap: item.paqueteId != null
                                            ? null
                                            : () => carrito.actualizarCantidad(
                                                item.id,
                                                item.cantidad + 1,
                                              ),
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 4,
                                          ),
                                          child: Icon(Icons.add, size: 14),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                icon: Icon(
                  _checkoutAbierto
                      ? Icons.expand_less
                      : Icons.shopping_bag_outlined,
                ),
                label: Text(
                  _checkoutAbierto
                      ? 'Volver a las prendas'
                      : 'Continuar: reserva o pago',
                ),
                onPressed: () =>
                    setState(() => _checkoutAbierto = !_checkoutAbierto),
              ),
            ),
            if (_checkoutAbierto)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        offset: const Offset(0, -3),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Selector de Sucursal de Retiro
                        if (sucursales.isNotEmpty) ...[
                          Text(
                            _usaDelivery
                                ? 'Sucursal origen:'
                                : 'Sucursal de retiro:',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: sucursalActual,
                                isExpanded: true,
                                items: sucursales.map((s) {
                                  return DropdownMenuItem<int>(
                                    value: s.id,
                                    child: Text(
                                      '${s.nombre} (${s.ciudad})',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  setState(() {
                                    _sucursalSeleccionadaId = val;
                                    _invalidarCotizacion();
                                  });
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                        ] else ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.danger.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: AppColors.danger.withValues(alpha: 0.25),
                              ),
                            ),
                            child: const Text(
                              'No hay una sucursal con stock suficiente para todos los productos del carrito.',
                              style: TextStyle(
                                color: AppColors.danger,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],

                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment<bool>(
                              value: false,
                              label: Text('Recojo'),
                              icon: Icon(Icons.storefront_outlined),
                            ),
                            ButtonSegment<bool>(
                              value: true,
                              label: Text('Delivery'),
                              icon: Icon(Icons.local_shipping_outlined),
                            ),
                          ],
                          selected: {_usaDelivery},
                          onSelectionChanged: (value) {
                            setState(() {
                              _usaDelivery = value.first;
                              _invalidarCotizacion();
                            });
                          },
                        ),
                        if (_usaDelivery) ...[
                          const Text(
                            'Compra y envío se pagan con Stripe o QR. No hay efectivo al entregar.',
                          ),
                          DropdownButtonFormField<int>(
                            initialValue: _direccionEntregaId,
                            decoration: const InputDecoration(
                              labelText: 'Dirección guardada (opcional)',
                            ),
                            items: _direccionesEntrega
                                .map(
                                  (d) => DropdownMenuItem(
                                    value: d['id'] as int,
                                    child: Text(
                                      d['direccion'].toString(),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (id) {
                              final d = _direccionesEntrega
                                  .where((x) => x['id'] == id)
                                  .firstOrNull;
                              if (d != null) {
                                setState(() {
                                  _direccionEntregaId = id;
                                  _direccionDeliveryCtrl.text = d['direccion']
                                      .toString();
                                  _referenciaDeliveryCtrl.text =
                                      d['referencia']?.toString() ?? '';
                                  _invalidarCotizacion();
                                });
                                _buscarUbicacionDelivery();
                              }
                            },
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _direccionDeliveryCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Dirección de entrega',
                              hintText: 'Ej. Av. Banzer 4to anillo, Santa Cruz',
                            ),
                            onChanged: (_) => setState(_invalidarCotizacion),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _referenciaDeliveryCtrl,
                            onChanged: (_) => setState(_invalidarCotizacion),
                            decoration: const InputDecoration(
                              labelText: 'Referencia',
                              hintText: 'Ej. Casa roja frente a farmacia',
                            ),
                          ),
                          const SizedBox(height: 10),
                          _buildDeliveryMap(sucursalSeleccionada),
                          const SizedBox(height: 8),
                          const Text(
                            'Busca tu dirección o toca el mapa para ajustar el punto exacto de entrega.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _buscandoUbicacion
                                ? null
                                : _buscarUbicacionDelivery,
                            icon: const Icon(Icons.search_outlined),
                            label: Text(
                              _buscandoUbicacion
                                  ? 'Buscando...'
                                  : 'Buscar ubicación',
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _cotizandoDelivery
                                ? null
                                : _cotizarDelivery,
                            icon: const Icon(Icons.map_outlined),
                            label: Text(
                              _cotizandoDelivery
                                  ? 'Cotizando...'
                                  : 'Cotizar delivery',
                            ),
                          ),
                          if (_cotizacionDelivery?.cotizacionId != null) ...[
                            CheckboxListTile(
                              value: _cotizacionAceptada,
                              onChanged: (v) => setState(
                                () => _cotizacionAceptada = v ?? false,
                              ),
                              title: const Text(
                                'Acepto la cotización del envío mostrada',
                              ),
                            ),
                            Text(
                              'Válida hasta ${_cotizacionDelivery!.venceEn}. Cambiar el destino requiere cotizar de nuevo.',
                            ),
                          ],
                          if (_cotizacionDelivery != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              _cotizacionDelivery!.disponible
                                  ? 'Delivery: ${_cotizacionDelivery!.distanciaKm.toStringAsFixed(2)} km · ${_cotizacionDelivery!.tiempoEstimadoMin} min · ${currencyFormat.format(_cotizacionDelivery!.costoDelivery)}'
                                  : (_cotizacionDelivery!.mensaje ??
                                        'Delivery no disponible'),
                              style: TextStyle(
                                color: _cotizacionDelivery!.disponible
                                    ? AppColors.success
                                    : AppColors.danger,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],

                        if (!_usaDelivery) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _seleccionarFechaCita,
                            icon: const Icon(Icons.event_available_outlined),
                            label: Text(
                              'Cita para probar/recoger: ${_fechaVista(_fechaCitaReserva)}',
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.accentSoft,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Reserva gratuita',
                                  style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  currencyFormat.format(_montoReserva()),
                                  style: const TextStyle(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'Sin anticipo. Tus prendas quedan apartadas por 7 días desde la creación de la reserva.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (excedeMaximoReserva) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppColors.danger.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: AppColors.danger.withValues(
                                    alpha: 0.25,
                                  ),
                                ),
                              ),
                              child: const Text(
                                'Para reservar solo puedes apartar hasta 2 unidades de la misma prenda.',
                                style: TextStyle(
                                  color: AppColors.danger,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],

                        // Resumen de Montos
                        const SizedBox(height: 14),
                        if (_usaDelivery)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Delivery:',
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              Text(currencyFormat.format(costoDelivery)),
                            ],
                          ),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 6,
                          children: [
                            Text(
                              _usaDelivery
                                  ? 'Total de compra:'
                                  : 'Valor de prendas:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            Text(
                              currencyFormat.format(
                                _usaDelivery
                                    ? totalConDelivery
                                    : carrito.totalMonto,
                              ),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Selector de Método de Pago
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'MÉTODO DE PAGO:',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildMetodoPagoChip(
                                    label: 'QR Simple',
                                    icon: Icons.qr_code_2,
                                    selected: _metodoPago == 'QR',
                                    onTap: () =>
                                        setState(() => _metodoPago = 'QR'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _buildMetodoPagoChip(
                                    label: 'Tarjeta Stripe',
                                    icon: Icons.credit_card,
                                    selected: _metodoPago == 'STRIPE',
                                    onTap: () =>
                                        setState(() => _metodoPago = 'STRIPE'),
                                  ),
                                ),
                                if (!_usaDelivery) ...[
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _buildMetodoPagoChip(
                                      label: 'En tienda',
                                      icon: Icons.storefront_outlined,
                                      selected: _metodoPago == 'RESERVA',
                                      onTap: () => setState(
                                        () => _metodoPago = 'RESERVA',
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Botones de Acción según método
                        if (_procesandoPago)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: CircularProgressIndicator(
                                color: AppColors.accent,
                              ),
                            ),
                          )
                        else if (_metodoPago == 'RESERVA' && !_usaDelivery)
                          CustomButton(
                            text: 'Confirmar reserva (pagar en tienda)',
                            icon: Icons.calendar_today_outlined,
                            onPressed: puedeConfirmar
                                ? _confirmarReserva
                                : null,
                          )
                        else if (_metodoPago == 'QR')
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(50),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 1,
                            ),
                            icon: const Icon(
                              Icons.qr_code_2,
                              color: Colors.white,
                              size: 22,
                            ),
                            label: Text(
                              'Probar pago QR (${currencyFormat.format(_usaDelivery ? totalConDelivery : carrito.totalMonto)})',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            onPressed: sucursalActual != null
                                ? _pagarConQr
                                : null,
                          )
                        else
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(50),
                              side: const BorderSide(
                                color: Color(0xFF635BFF),
                                width: 1.5,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(
                              Icons.credit_card,
                              color: Color(0xFF635BFF),
                            ),
                            label: Text(
                              'Pagar con Stripe (${currencyFormat.format(_usaDelivery ? totalConDelivery : carrito.totalMonto)})',
                              style: const TextStyle(
                                color: Color(0xFF635BFF),
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            onPressed: sucursalActual != null
                                ? _pagarConStripe
                                : null,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetodoPagoChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.08)
              : Colors.white,
          border: Border.all(
            color: selected ? AppColors.primary : const Color(0xFFE2E8F0),
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? AppColors.primary : AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
