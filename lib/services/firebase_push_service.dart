import 'dart:async';

import 'package:flutter/services.dart';

import 'notificaciones_service.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/api_constants.dart';
import '../core/network/api_client.dart';
import '../core/network/api_exceptions.dart';
import '../core/session/contexto_sesion.dart';
import '../core/session/clave_pago.dart';

const firebaseHabilitado = bool.fromEnvironment(
  'FIREBASE_ENABLED',
  defaultValue: false,
);
FirebaseOptions opcionesFirebase() => const FirebaseOptions(
  apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
  appId: String.fromEnvironment('FIREBASE_APP_ID'),
  messagingSenderId: String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID'),
  projectId: String.fromEnvironment('FIREBASE_PROJECT_ID'),
  iosBundleId: String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID'),
);
@pragma('vm:entry-point')
Future<void> recibirPushFondo(RemoteMessage message) async {
  if (firebaseHabilitado && Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: opcionesFirebase());
  }
  // Android presenta el título y mensaje del evento; el detalle requiere sesión.
}

class ReferenciaPush {
  final int notificacionId, empresaId;
  const ReferenciaPush(this.notificacionId, this.empresaId);
  static ReferenciaPush? desde(Map<Object?, Object?>? datos) {
    if (datos == null) return null;
    final n = int.tryParse('${datos['notificacion_id']}'),
        e = int.tryParse('${datos['empresa_id']}');
    return n != null && e != null && n > 0 && e > 0
        ? ReferenciaPush(n, e)
        : null;
  }

  Map<String, int> toJson() => {
    'notificacion_id': notificacionId,
    'empresa_id': empresaId,
  };
  String get clave => '$empresaId:$notificacionId';
}

class FirebasePush {
  static final novedades = ValueNotifier<int>(0);
  static final noLeidas = ValueNotifier<int>(0);
  static final pendiente = ValueNotifier<ReferenciaPush?>(null);
  static const puente = MethodChannel('stylear/notificaciones');
  static bool _escuchando = false, _sdkListo = false, _vinculando = false;
  static Future<void>? _preparando;
  static StreamSubscription<String>? _tokens;
  static StreamSubscription<RemoteMessage>? _mensajes, _aperturas;
  static int _generacion = -1;
  static int? _usuarioAnterior;
  static final _mostradas = <String>{};
  static String? _ultimaApertura;
  static DateTime? _abiertaEn;
  static bool get android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static void iniciar() {
    if (_escuchando) return;
    _escuchando = true;
    _generacion = ContextoSesion.instance.generacion;
    _usuarioAnterior = ContextoSesion.instance.usuario?.id;
    ContextoSesion.instance.addListener(_cambioSesion);
  }

  static Future<void> preparar() {
    if (_sdkListo) return Future.value();
    return _preparando ??= _preparar().whenComplete(() => _preparando = null);
  }

  static Future<void> _preparar() async {
    iniciar();
    if (!firebaseHabilitado || kIsWeb) return;
    try {
      final o = opcionesFirebase();
      if (o.apiKey.isEmpty ||
          o.appId.isEmpty ||
          o.projectId.isEmpty ||
          o.messagingSenderId.isEmpty) {
        return;
      }
      if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: o);
      FirebaseMessaging.onBackgroundMessage(recibirPushFondo);
      if (android) {
        puente.setMethodCallHandler((call) async {
          if (call.method == 'abrir') {
            abrirReferencia(
              ReferenciaPush.desde(
                Map<Object?, Object?>.from(call.arguments as Map),
              ),
            );
          }
        });
        await puente.invokeMethod<void>('inicializar');
        final inicio = await puente.invokeMapMethod<Object?, Object?>('inicio');
        abrirReferencia(ReferenciaPush.desde(inicio));
      }
      _tokens ??= FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        unawaited(_registrarRenovado(token));
      });
      _mensajes ??= FirebaseMessaging.onMessage.listen((m) {
        unawaited(_recibir(m));
      });
      _aperturas ??= FirebaseMessaging.onMessageOpenedApp.listen(
        (m) => abrirReferencia(ReferenciaPush.desde(m.data)),
      );
      final inicial = await FirebaseMessaging.instance.getInitialMessage();
      if (inicial != null) abrirReferencia(ReferenciaPush.desde(inicial.data));
      _sdkListo = true;
    } catch (_) {
      /* La bandeja funciona aunque el SDK o el canal no estén disponibles. */
    }
  }

  static void abrirReferencia(ReferenciaPush? referencia) {
    if (referencia == null) return;
    final ahora = DateTime.now();
    if (_ultimaApertura == referencia.clave &&
        _abiertaEn != null &&
        ahora.difference(_abiertaEn!) < const Duration(seconds: 3)) {
      return;
    }
    _ultimaApertura = referencia.clave;
    _abiertaEn = ahora;
    pendiente.value = referencia;
    novedades.value++;
  }

  static void _cambioSesion() {
    final c = ContextoSesion.instance;
    if (c.generacion == _generacion) return;
    final anterior = _usuarioAnterior;
    _usuarioAnterior = c.usuario?.id;
    _generacion = c.generacion;
    final r = pendiente.value;
    final esperandoIngreso =
        anterior == null &&
        r != null &&
        !c.modoPlataforma &&
        (c.empresa == null || c.empresa!.id == r.empresaId);
    if (!esperandoIngreso) pendiente.value = null;
    _mostradas.clear();
    noLeidas.value = 0;
    novedades.value++;
    if (!firebaseHabilitado || !android) return;
    unawaited(puente.invokeMethod<void>('cancelar').catchError((Object _) {}));
    if (c.usuario == null || c.usuario!.esAdminSaas) {
      if (anterior != null && _sdkListo) {
        unawaited(
          FirebaseMessaging.instance.deleteToken().catchError((Object _) {}),
        );
      }
      return;
    }
    unawaited(_volverAVincular());
  }

  static Future<void> _registrarRenovado(String token) async {
    final c = ContextoSesion.instance, gen = c.generacion;
    if (c.usuario == null || c.usuario!.esAdminSaas) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool('stylear_push_activado') != true) return;
      await _registrar(token, gen);
    } catch (_) {}
  }

  static Future<void> _volverAVincular() async {
    if (_vinculando || !_sdkListo) return;
    _vinculando = true;
    final gen = ContextoSesion.instance.generacion;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool('stylear_push_activado') != true) return;
      final permiso = await FirebaseMessaging.instance
          .getNotificationSettings();
      if (permiso.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _registrar(token, gen);
    } catch (_) {
    } finally {
      _vinculando = false;
      if (gen != ContextoSesion.instance.generacion &&
          ContextoSesion.instance.usuario != null) {
        unawaited(_volverAVincular());
      }
    }
  }

  static Future<void> _recibir(RemoteMessage m) async {
    final c = ContextoSesion.instance, r = ReferenciaPush.desde(m.data);
    if (r == null ||
        c.usuario == null ||
        c.usuario!.esAdminSaas ||
        c.empresa?.id != r.empresaId) {
      return;
    }
    final gen = c.generacion, clave = '$gen:${r.clave}';
    if (!_mostradas.add(clave)) return;
    if (_mostradas.length > 128) _mostradas.remove(_mostradas.first);
    try {
      await NotificacionesService.trazabilidad(r.notificacionId);
      ApiClient.validarGeneracion(gen);
      novedades.value++;
      final resumen = await NotificacionesService.resumen();
      ApiClient.validarGeneracion(gen);
      noLeidas.value = (resumen['no_leidas'] as num).toInt();
      if (android) {
        await puente.invokeMethod<void>('mostrar', {
          ...r.toJson(),
          'titulo': m.notification?.title ?? 'StyleAR',
          'mensaje': m.notification?.body ?? 'Abre tu bandeja para consultar el aviso.',
        });
      }
    } catch (_) {
      /* Una referencia ajena o revocada nunca produce contenido local. */
    }
  }

  static Future<Map<String, dynamic>?> estadoSistema() async =>
      android ? await puente.invokeMapMethod<String, dynamic>('estado') : null;
  static Future<void> ajustes() async {
    if (android) await puente.invokeMethod<void>('ajustes');
  }

  static String explicarError(Object e) {
    if (e is ApiException) return e.message;
    if (e is FirebaseException) {
      return 'Google no pudo registrar los avisos de este teléfono. Comprueba la conexión a Internet y vuelve a activar los avisos. La bandeja sigue disponible.';
    }
    if (e is PlatformException && e.code == 'PERMISO') {
      return 'Android no permite presentar avisos. Revisa los ajustes de notificaciones; la bandeja sigue disponible.';
    }
    return 'No se pudo completar la operación. Inténtalo nuevamente.';
  }

  static Future<String> activar() async {
    iniciar();
    if (!firebaseHabilitado) {
      return 'Firebase no está configurado en esta compilación. La bandeja está disponible.';
    }
    if (!android) {
      return 'La bandeja está disponible. La presentación de avisos de esta versión se prepara para Android.';
    }
    final c = ContextoSesion.instance, gen = c.generacion;
    if (c.usuario == null || c.usuario!.esAdminSaas) {
      return 'Inicia sesión en una tienda para activar avisos.';
    }
    final estado = await ApiClient.get(
      '${ApiConstants.baseUrl}/notificaciones/estado',
    );
    if ((estado as Map)['push_configurado'] != true) {
      return 'Falta configurar Firebase en el servidor. La bandeja conserva las actualizaciones.';
    }
    await preparar();
    ApiClient.validarGeneracion(gen);
    if (!_sdkListo) {
      return 'No se pudo preparar Firebase. Reintenta; la bandeja sigue disponible.';
    }
    final permiso = await FirebaseMessaging.instance.requestPermission();
    ApiClient.validarGeneracion(gen);
    if (permiso.authorizationStatus == AuthorizationStatus.denied) {
      return 'No se autorizó el permiso de avisos. Puedes usar la bandeja y revisar los ajustes de Android.';
    }
    final sistema = await estadoSistema();
    if (sistema?['permitidas'] == false || sistema?['importancia'] == 0) {
      return 'Los avisos o su canal están deshabilitados en Android. La bandeja permanece disponible.';
    }
    await FirebaseMessaging.instance.setAutoInitEnabled(true);
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null) {
      return 'Aún no se obtuvo el registro del dispositivo. Reintenta.';
    }
    await _registrar(token, gen);
    ApiClient.validarGeneracion(gen);
    final p = await SharedPreferences.getInstance();
    await p.setBool('stylear_push_activado', true);
    return 'Dispositivo registrado. Android controla cómo aparecen los avisos según sus permisos y el canal.';
  }

  static Future<void> _registrar(String token, int gen) async {
    final p = await SharedPreferences.getInstance();
    var instalacion = p.getString('stylear_push_instalacion');
    instalacion ??= nuevoIdentificador();
    await p.setString('stylear_push_instalacion', instalacion);
    ApiClient.validarGeneracion(gen);
    await ApiClient.post(
      '${ApiConstants.baseUrl}/notificaciones/dispositivos',
      body: {
        'instalacion_id': instalacion,
        'token': token,
        'plataforma': android ? 'android' : 'ios',
      },
    );
  }

  static Future<void> desvincular() async {
    try {
      final p = await SharedPreferences.getInstance();
      final id = p.getString('stylear_push_instalacion');
      if (id != null &&
          ContextoSesion.instance.usuario != null &&
          !ContextoSesion.instance.usuario!.esAdminSaas) {
        await ApiClient.delete(
          '${ApiConstants.baseUrl}/notificaciones/dispositivos/$id',
        );
      }
    } catch (_) {}
    pendiente.value = null;
    noLeidas.value = 0;
    if (firebaseHabilitado && android) {
      try {
        await puente.invokeMethod<void>('cancelar');
        if (_sdkListo) await FirebaseMessaging.instance.deleteToken();
      } catch (_) {}
    }
  }
}
