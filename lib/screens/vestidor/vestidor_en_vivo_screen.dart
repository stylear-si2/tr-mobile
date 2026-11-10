import '../../core/session/contexto_sesion.dart';
import 'acceso_vestidor_cliente.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/api_client.dart';
import '../../providers/auth_provider.dart';
import '../catalogo/producto_detalle_screen.dart';
import 'services/vestidor_api_service.dart';

class VestidorEnVivoScreen extends StatefulWidget {
  final int? productoInicialId;

  const VestidorEnVivoScreen({super.key, this.productoInicialId});

  @override
  State<VestidorEnVivoScreen> createState() => _VestidorEnVivoScreenState();
}

class _VestidorEnVivoScreenState extends State<VestidorEnVivoScreen>
    with WidgetsBindingObserver {
  late final int _generacionSesion;
  WebViewController? _webViewController;
  bool _cargandoStream = true;
  bool _permisoDenegado = false;
  String? _errorMensaje;
  bool _esCamaraTrasera = false;

  // Catálogo y prenda activa
  List<Map<String, dynamic>> _prendas = [];
  Map<String, dynamic>? _prendaSeleccionada;
  bool _cargandoCatalogo = true;

  // Control de sesión y protección de créditos Decart ($0.02 / seg)
  Timer? _countdownTimer;
  int _segundosRestantes = 120; // 2 minutos por sesión para proteger créditos
  bool _sesionPausada = false;

  final NumberFormat _currencyFormat = NumberFormat.currency(
    locale: 'es_BO',
    symbol: 'Bs. ',
    decimalDigits: 2,
  );

  @override
  void initState() {
    super.initState();
    _generacionSesion = ContextoSesion.instance.generacion;
    ContextoSesion.instance.addListener(_cambioSesion);
    WidgetsBinding.instance.addObserver(this);
    if (context.read<AuthProvider>().esCliente &&
        context.read<AuthProvider>().estaAutenticado) {
      _iniciarTodo();
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ContextoSesion.instance.removeListener(_cambioSesion);
    _webViewController
        ?.runJavaScript("window.suspendVestidor?.();")
        .catchError((_) {});
    super.dispose();
  }

  void _cambioSesion() {
    if (!mounted || ContextoSesion.instance.generacion == _generacionSesion) {
      return;
    }
    _webViewController
        ?.runJavaScript("window.suspendVestidor?.();")
        .catchError((_) {});
    _countdownTimer?.cancel();
    setState(() {
      _webViewController = null;
      _cargandoStream = false;
      _errorMensaje = 'La sesión cambió. Vuelve a abrir el vestidor.';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_webViewController != null &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached)) {
      _webViewController
          ?.runJavaScript("window.suspendVestidor?.();")
          .catchError((_) {});
      if (mounted) setState(() => _sesionPausada = true);
    }
  }

  Future<void> _iniciarTodo() async {
    // 1. Pedir permiso nativo del sistema Android primero para que el WebView nunca sea bloqueado
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        setState(() {
          _permisoDenegado = true;
          _cargandoStream = false;
        });
      }
      return;
    }

    // 2. Cargar catálogo de prendas disponibles
    await _cargarCatalogo();

    // 3. Iniciar WebView con WebRTC
    if (!mounted) return;
    try {
      await _iniciarWebView();
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorMensaje = 'No se pudo abrir el probador. Revisa tu sesión e inténtalo nuevamente.';
          _cargandoStream = false;
        });
      }
    }
  }

  Future<void> _cargarCatalogo() async {
    try {
      final prendas = await VestidorApiService.listarPrendasDisponibles(
        limite: 30,
      );
      if (!mounted) return;

      setState(() {
        _prendas = prendas;
        if (prendas.isNotEmpty) {
          if (widget.productoInicialId != null) {
            _prendaSeleccionada = prendas.firstWhere(
              (p) => p['producto_id'] == widget.productoInicialId,
              orElse: () => prendas.first,
            );
          } else {
            _prendaSeleccionada = prendas.first;
          }
        }
        _cargandoCatalogo = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargandoCatalogo = false);
    }
  }

  Future<void> _iniciarWebView() async {
    final productoId =
        _prendaSeleccionada?['producto_id'] ?? widget.productoInicialId ?? 1;

    // Registrar telemetría
    VestidorApiService.registrarSesion(
      productoId: productoId,
      origen: 'MOVIL_DECART_WEBRTC_VIVO',
    );

    final targetUrl = Uri.parse(
      '${ApiConstants.baseUrl}/catalogo/vestidor/en-vivo-view?producto_id=$productoId',
    );

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final destino = Uri.tryParse(request.url);
            return destino?.origin == targetUrl.origin &&
                    destino?.path == targetUrl.path
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (_) {
            if (mounted) {
              setState(() => _cargandoStream = false);
              _iniciarTemporizador();
            }
          },
          onWebResourceError: (error) {
            if (mounted) {
              setState(() {
                _errorMensaje = 'Error de conexión: ${error.description}';
                _cargandoStream = false;
              });
            }
          },
        ),
      );

    controller.setOnConsoleMessage((message) {
      // No registrar respuestas, URL ni credenciales del proveedor desde el visor.
    });

    controller.addJavaScriptChannel(
      'FlutterChannel',
      onMessageReceived: (message) {
        try {
          final data = jsonDecode(message.message);
          if (data['event'] == 'cameraChanged') {
            final facing = data['facingMode'] as String?;
            if (mounted) {
              setState(() {
                _esCamaraTrasera = (facing == 'environment');
              });
            }
          }
        } catch (_) {}
      },
    );

    if (controller.platform is AndroidWebViewController) {
      final android = controller.platform as AndroidWebViewController;
      android.setOnPlatformPermissionRequest((request) {
        if (request.types.length == 1 &&
            request.types.contains(WebViewPermissionResourceType.camera)) {
          request.grant();
        } else {
          request.deny();
        }
      });
      android.setMediaPlaybackRequiresUserGesture(false);
    }

    final headers = await ApiClient.headersPara(targetUrl.toString());
    if (!mounted) return;
    await controller.loadRequest(targetUrl, headers: headers);
    if (!mounted) return;

    setState(() {
      _webViewController = controller;
    });
  }

  void _iniciarTemporizador() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_sesionPausada) return;

      setState(() {
        if (_segundosRestantes > 0) {
          _segundosRestantes--;
        } else {
          timer.cancel();
          _pausarSesion();
          _mostrarModalTiempoExpirado();
        }
      });
    });
  }

  void _pausarSesion() {
    setState(() {
      _sesionPausada = true;
    });
    _webViewController?.runJavaScript('window.pauseLiveStream()');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Streaming pausado. Créditos de Decart protegidos.'),
        backgroundColor: Color(0xFFF59E0B),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _cambiarCamara() {
    setState(() {
      _esCamaraTrasera = !_esCamaraTrasera;
    });
    _webViewController?.runJavaScript('window.switchCamera()');
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              _esCamaraTrasera
                  ? Icons.camera_rear_rounded
                  : Icons.camera_front_rounded,
              color: const Color(0xFF0F172A),
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              _esCamaraTrasera
                  ? 'Cambiando a cámara trasera...'
                  : 'Cambiando a cámara frontal...',
              style: const TextStyle(
                color: Color(0xFF0F172A),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF00E5FF),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _reanudarSesion() {
    setState(() {
      _sesionPausada = false;
    });
    _webViewController?.runJavaScript('window.resumeLiveStream()');
  }

  void _seleccionarPrenda(Map<String, dynamic> prenda) {
    if (_prendaSeleccionada?['producto_id'] == prenda['producto_id']) return;
    setState(() {
      _prendaSeleccionada = prenda;
    });

    final pid = prenda['producto_id'];
    _webViewController?.runJavaScript('window.switchGarment($pid)');

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Amoldando en vivo: ${prenda['nombre'] ?? 'Prenda'}'),
        backgroundColor: const Color(0xFF00E5FF),
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  void _mostrarInfoCreditos() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.token_rounded, color: Color(0xFF00E5FF)),
            SizedBox(width: 10),
            Text(
              'Control de Créditos IA',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transmisión en Vivo: Decart Lucy VTON 3.5',
              style: TextStyle(
                color: Color(0xFF00E5FF),
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            SizedBox(height: 12),
            Text(
              '• La transmisión en vivo amolda la ropa continuamente a 30 FPS.\n'
              '• Cada segundo en vivo consume créditos de tu cuenta Decart (\$0.02 / segundo).\n'
              '• Usa el botón "Pausar" en cualquier momento para detener el consumo.\n'
              '• Puedes verificar tu saldo y consumo en tiempo real en:\n'
              '  platform.decart.ai/dashboard',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Entendido',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _mostrarModalTiempoExpirado() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.hourglass_bottom_rounded, color: Color(0xFFF59E0B)),
            SizedBox(width: 10),
            Text(
              'Tiempo Finalizado',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ],
        ),
        content: const Text(
          'La sesión de vestidor en vivo se ha pausado automáticamente para proteger tus créditos de Decart AI.\n\n¿Deseas extender 2 minutos adicionales?',
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('Salir', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _segundosRestantes = 120;
                _sesionPausada = false;
              });
              _reanudarSesion();
              _iniciarTemporizador();
            },
            child: const Text(
              'Extender 2 min',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _reservarPrenda() {
    if (_prendaSeleccionada == null) return;
    final pid = _prendaSeleccionada!['producto_id'] as int;

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProductoDetalleScreen(productoId: pid)),
    );
  }

  String _formatearTiempo(int totalSegundos) {
    final min = (totalSegundos ~/ 60).toString().padLeft(2, '0');
    final sec = (totalSegundos % 60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (!auth.estaAutenticado || !auth.esCliente) {
      return const AccesoVestidorCliente();
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0B132B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.videocam_rounded,
                color: Color(0xFF00E5FF),
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Vestidor en Vivo IA',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Decart Lucy VTON 3.5 Realtime',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // Botón alternar cámara (Frontal / Trasera)
          IconButton(
            icon: Icon(
              _esCamaraTrasera
                  ? Icons.camera_rear_rounded
                  : Icons.camera_front_rounded,
              color: const Color(0xFF00E5FF),
              size: 20,
            ),
            tooltip: _esCamaraTrasera
                ? 'Cambiar a cámara frontal'
                : 'Cambiar a cámara trasera',
            onPressed: _cambiarCamara,
          ),
          // Contador de protección de créditos y estado
          GestureDetector(
            onTap: _mostrarInfoCreditos,
            child: Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _sesionPausada
                    ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                    : const Color(0xFF10B981).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _sesionPausada
                      ? const Color(0xFFF59E0B)
                      : const Color(0xFF10B981),
                  width: 1.2,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _sesionPausada
                        ? Icons.pause_circle_rounded
                        : Icons.timer_outlined,
                    color: _sesionPausada
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF10B981),
                    size: 14,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _formatearTiempo(_segundosRestantes),
                    style: TextStyle(
                      color: _sesionPausada
                          ? const Color(0xFFF59E0B)
                          : const Color(0xFF10B981),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Visor Principal WebRTC en Vivo (30 FPS continuo sin pausar)
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _sesionPausada
                        ? Colors.white12
                        : const Color(0xFF00E5FF).withValues(alpha: 0.6),
                    width: 1.5,
                  ),
                  boxShadow: [
                    if (!_sesionPausada)
                      BoxShadow(
                        color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 1. WebView con WebRTC LiveKit 30 FPS continuo
                    if (_webViewController != null && !_permisoDenegado)
                      WebViewWidget(controller: _webViewController!),

                    // 2. Loading inicial
                    if (_cargandoStream)
                      Container(
                        color: const Color(0xFF0F172A),
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                color: Color(0xFF00E5FF),
                              ),
                              SizedBox(height: 16),
                              Text(
                                'Iniciando cámara y Decart Lucy 3.5...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 6),
                              Text(
                                'Conectando streaming en tiempo real a 30 FPS',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // 3. Vista de Permiso Denegado
                    if (_permisoDenegado) _buildPermisoDenegadoView(),

                    // 4. Mensaje de Error
                    if (_errorMensaje != null)
                      Container(
                        color: const Color(0xFF0F172A),
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: Colors.redAccent,
                                size: 48,
                              ),
                              const SizedBox(height: 14),
                              Text(
                                _errorMensaje!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 18),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00E5FF),
                                  foregroundColor: const Color(0xFF0F172A),
                                ),
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Reintentar'),
                                onPressed: _iniciarTodo,
                              ),
                            ],
                          ),
                        ),
                      ),

                    // 5. Botones de Control: Cámara y Pausar / Reanudar (esquina superior derecha)
                    Positioned(
                      top: 14,
                      right: 14,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Botón Cambiar Cámara (Frontal / Trasera)
                          GestureDetector(
                            onTap: _cambiarCamara,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F172A)
                                    .withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: const Color(0xFF00E5FF)
                                      .withValues(alpha: 0.6),
                                  width: 1.2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _esCamaraTrasera
                                        ? Icons.camera_rear_rounded
                                        : Icons.camera_front_rounded,
                                    color: const Color(0xFF00E5FF),
                                    size: 16,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    _esCamaraTrasera ? 'Trasera' : 'Frontal',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Botón Pausar / Reanudar
                          GestureDetector(
                            onTap: _sesionPausada
                                ? _reanudarSesion
                                : _pausarSesion,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: _sesionPausada
                                    ? const Color(0xFF00E5FF)
                                          .withValues(alpha: 0.25)
                                    : const Color(0xFFF59E0B)
                                          .withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: _sesionPausada
                                      ? const Color(0xFF00E5FF)
                                      : const Color(0xFFF59E0B),
                                  width: 1.2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _sesionPausada
                                        ? Icons.play_arrow_rounded
                                        : Icons.pause_rounded,
                                    color: _sesionPausada
                                        ? const Color(0xFF00E5FF)
                                        : const Color(0xFFF59E0B),
                                    size: 16,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    _sesionPausada ? 'Reanudar' : 'Pausar',
                                    style: TextStyle(
                                      color: _sesionPausada
                                          ? const Color(0xFF00E5FF)
                                          : const Color(0xFFF59E0B),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Carrusel Inferior de Prendas Disponibles
            _buildSelectorPrendasInferior(),

            // Barra Inferior de Acción y Reserva
            _buildBarraInferiorReserva(),
          ],
        ),
      ),
    );
  }

  Widget _buildPermisoDenegadoView() {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_rounded,
              color: Color(0xFFF59E0B),
              size: 52,
            ),
            const SizedBox(height: 14),
            const Text(
              'Permiso de Cámara Requerido',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Para verte en el vestidor en vivo y que Decart amolde las prendas sobre tu cuerpo en tiempo real, StyleAR necesita acceso a la cámara.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: const Color(0xFF0F172A),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.lock_open_rounded),
              label: const Text(
                'Conceder Permiso Ahora',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onPressed: _iniciarTodo,
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => openAppSettings(),
              child: const Text(
                'Abrir Ajustes de la App',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectorPrendasInferior() {
    if (_cargandoCatalogo) {
      return const SizedBox(
        height: 80,
        child: Center(
          child: CircularProgressIndicator(
            color: Color(0xFF00E5FF),
            strokeWidth: 2,
          ),
        ),
      );
    }

    if (_prendas.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Elige la prenda a probar en vivo:',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${_prendas.length} disponibles',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _prendas.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final prenda = _prendas[index];
                final isSelected =
                    _prendaSeleccionada?['producto_id'] ==
                    prenda['producto_id'];
                final imgUrl = prenda['imagen_url'] as String?;

                return GestureDetector(
                  onTap: () => _seleccionarPrenda(prenda),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 72,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF00E5FF)
                            : Colors.white12,
                        width: isSelected ? 2.5 : 1,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: const Color(0xFF00E5FF)
                                    .withValues(alpha: 0.35),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (imgUrl != null && imgUrl.isNotEmpty)
                          Image.network(
                            imgUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Center(
                              child: Icon(
                                Icons.checkroom,
                                color: Colors.white24,
                                size: 28,
                              ),
                            ),
                          )
                        else
                          const Center(
                            child: Icon(
                              Icons.checkroom,
                              color: Colors.white24,
                              size: 28,
                            ),
                          ),
                        if (isSelected)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: Color(0xFF00E5FF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check,
                                size: 10,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBarraInferiorReserva() {
    final nombre = _prendaSeleccionada?['nombre'] ?? 'Selecciona una prenda';
    final precio = _prendaSeleccionada?['precio'];

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  nombre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  precio != null ? _currencyFormat.format(precio) : '--',
                  style: const TextStyle(
                    color: Color(0xFF00E5FF),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 2,
            ),
            icon: const Icon(Icons.shopping_bag_outlined, size: 18),
            label: const Text(
              'Reservar',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            onPressed: _reservarPrenda,
          ),
        ],
      ),
    );
  }
}
