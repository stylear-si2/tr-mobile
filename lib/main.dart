import 'core/network/api_client.dart';

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'screens/notificaciones/puente_push.dart';
import 'services/firebase_push_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'core/storage/sesion_offline.dart';
import 'providers/auth_provider.dart';
import 'providers/plan_provider.dart';
import 'screens/saas/plataforma_screen.dart';
import 'providers/carrito_provider.dart';
import 'providers/catalogo_provider.dart';
import 'providers/favoritos_provider.dart';
import 'providers/reserva_provider.dart';
import 'screens/home/main_navigation_screen.dart';
import 'screens/home/operaciones_offline_screen.dart';
import 'services/sincronizacion_offline.dart';
import 'screens/auth/empresa_screen.dart';
import 'screens/auth/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es', null);
  FirebasePush.iniciar();
  await FirebasePush.preparar().timeout(
    const Duration(seconds: 8),
    onTimeout: () {},
  );
  runApp(const StyleARApp());
}

class StyleARApp extends StatelessWidget {
  const StyleARApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AuthProvider()..inicializar(),
      child: Consumer<AuthProvider>(
        builder: (context, auth, _) {
          return MultiProvider(
            key: ValueKey(auth.generacion),
            providers: [
              ChangeNotifierProvider(
                create: (_) => PlanProvider(),
                lazy: false,
              ),
              ChangeNotifierProvider(create: (_) => CatalogoProvider()),
              ChangeNotifierProvider(create: (_) => CarritoProvider()),
              ChangeNotifierProvider(create: (_) => ReservaProvider()),
              ChangeNotifierProvider(create: (_) => FavoritosProvider()),
            ],
            child: PuentePush(
              builder: (navigatorKey) => MaterialApp(
                navigatorKey: navigatorKey,
                key: ValueKey(auth.generacion),
                title: 'StyleAR',
                debugShowCheckedModeBanner: false,
                theme: AppTheme.lightTheme,
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: const [
                  Locale('es', 'BO'),
                  Locale('es', ''),
                  Locale('en', ''),
                ],
                locale: const Locale('es'),
                home: !auth.inicializado
                    ? const Scaffold(
                        body: Center(child: CircularProgressIndicator()),
                      )
                    : auth.accesoOffline != null
                    ? AccesoOfflineScreen(
                        sesion: auth.accesoOffline!,
                        contenido: const _TiendaSesion(),
                        alDesbloquear: auth.abrirVistaOffline,
                        reconectar: auth.inicializar,
                        salir: auth.cerrarAccesoOffline,
                      )
                    : auth.esAdminSaas
                    ? const PlataformaScreen()
                    : auth.modoPlataforma
                    ? const LoginScreen()
                    : auth.empresa == null
                    ? const EmpresaScreen()
                    : auth.requiereLogin
                    ? const LoginScreen()
                    : const _TiendaSesion(),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TiendaSesion extends StatefulWidget {
  const _TiendaSesion();
  @override
  State<_TiendaSesion> createState() => _TiendaSesionState();
}

class _TiendaSesionState extends State<_TiendaSesion>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _conexion;
  Timer? _reintentos;

  SesionOffline? _sesion(AuthProvider auth) {
    final usuario = auth.usuario;
    final empresa = auth.empresa;
    if (!SesionOffline.disponible ||
        !auth.estaAutenticado ||
        usuario == null ||
        empresa == null) {
      return null;
    }
    final sesion = SesionOffline(
      empresa,
      usuario,
      DateTime.now().add(SesionOffline.vigencia),
    );
    return sesion.puedeVender || sesion.puedeReservar ? sesion : null;
  }

  Future<void> _sincronizar({bool descargar = true}) async {
    if (!mounted) return;
    final sesion = _sesion(context.read<AuthProvider>());
    if (sesion == null) return;
    try {
      if (!(await Connectivity().checkConnectivity()).contains(
        ConnectivityResult.none,
      )) {
        await SincronizacionOffline.instancia.ejecutar(
          sesion,
          descargar: descargar,
        );
      }
    } on Exception {
      // La cola queda guardada para el siguiente intento.
    }
  }

  @override
  void initState() {
    super.initState();
    if (SesionOffline.disponible) {
      WidgetsBinding.instance.addObserver(this);
      _conexion = Connectivity().onConnectivityChanged.listen((estado) {
        if (!estado.contains(ConnectivityResult.none)) {
          unawaited(_sincronizar());
        }
      });
      _reintentos = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(_sincronizar(descargar: false));
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_sincronizar());
      if (context.read<AuthProvider>().esCliente) {
        context.read<CarritoProvider>().cargarCarrito();
        context.read<FavoritosProvider>().cargarFavoritos();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    if (estado == AppLifecycleState.resumed) {
      unawaited(_sincronizar(descargar: false));
    }
  }

  @override
  void dispose() {
    if (SesionOffline.disponible) WidgetsBinding.instance.removeObserver(this);
    unawaited(_conexion?.cancel());
    _reintentos?.cancel();
    super.dispose();
  }

  Future<void> _cambiar() async {
    final auth = context.read<AuthProvider>();
    if (auth.estaAutenticado) {
      final confirma = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cambiar de empresa'),
          content: const Text(
            'Se cerrará esta sesión. Sus operaciones pendientes quedarán guardadas para esta cuenta.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Conservar mi sesión'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cerrar sesión y cambiar'),
            ),
          ],
        ),
      );
      if (confirma != true) return;
    }
    await auth.cambiarEmpresa();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final sesion = _sesion(auth);
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      auth.empresa?.nombre ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (sesion != null)
                    IconButton(
                      tooltip: 'Solicitudes pendientes y sincronización',
                      icon: const Icon(Icons.cloud_off_outlined),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              OperacionesOfflineScreen(sesion: sesion),
                        ),
                      ),
                    ),
                  TextButton(
                    onPressed: auth.cargando ? null : _cambiar,
                    child: const Text('Cambiar empresa'),
                  ),
                ],
              ),
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: ApiClient.usandoCache,
          builder: (context, local, _) => local
              ? MaterialBanner(
                  content: const Text(
                    'Sin conexión: mostrando datos guardados. Stock y precios sujetos a verificación.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: auth.inicializar,
                      child: const Text('Reconectar'),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
        const Expanded(child: MainNavigationScreen()),
      ],
    );
  }
}
