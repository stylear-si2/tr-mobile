import '../services/firebase_push_service.dart';

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../core/constants/api_constants.dart';
import '../core/network/api_client.dart';
import '../core/network/api_exceptions.dart';
import '../core/session/contexto_sesion.dart';
import '../core/storage/session_storage.dart';
import '../core/storage/sesion_offline.dart';
import '../models/auth_models.dart';
import '../models/empresa_models.dart';
import '../models/perfil_models.dart';

class AuthProvider extends ChangeNotifier {
  final contexto = ContextoSesion.instance;
  bool _cargando = false;
  bool _inicializado = false;
  bool _verificando = false;
  String? _error;
  SesionOffline? accesoOffline;
  late final Timer _caducidad;

  AuthProvider() {
    contexto.addListener(_cambio);
    _caducidad = Timer.periodic(const Duration(seconds: 15), (_) {
      if (contexto.token != null &&
          contexto.usuario != null &&
          !ContextoSesion.sesionValida(contexto.token!, contexto.usuario!)) {
        if (SesionOffline.disponible) {
          unawaited(inicializar());
        } else {
          unawaited(
            contexto.cerrar(
              mensaje: 'Tu sesión venció. Inicia sesión nuevamente.',
              pedirLogin: true,
            ),
          );
        }
      }
    });
  }
  void _cambio() => notifyListeners();
  @override
  void dispose() {
    _caducidad.cancel();
    contexto.removeListener(_cambio);
    super.dispose();
  }

  UsuarioAutenticado? get usuario => contexto.usuario;
  String? get token => contexto.token;
  EmpresaPublica? get empresa => contexto.empresa;
  int get generacion => contexto.generacion;
  bool get cargando => _cargando;
  bool get inicializado => _inicializado;
  String? get error => _error;
  String? get aviso => contexto.aviso;
  bool get requiereLogin => contexto.requiereLogin;
  bool get estaAutenticado =>
      usuario != null && (token != null || ApiClient.soloLocal);
  bool get esCliente => usuario?.esCliente ?? false;
  bool get esAdmin => usuario?.esAdmin ?? false;
  bool get esAdminSaas => usuario?.esAdminSaas ?? false;
  bool get modoPlataforma => contexto.modoPlataforma;
  Future<void> abrirPlataforma() => contexto.abrirPlataforma();
  bool get esEncargado => usuario?.esEncargado ?? false;
  bool get esCajero => usuario?.esCajero ?? false;
  bool get esProveedor => usuario?.esProveedor ?? false;
  bool get esAdminOEncargado => esAdmin || esEncargado;
  bool get esPersonalDevoluciones => esAdmin || esEncargado || esCajero;
  void limpiarError() {
    _error = null;
    notifyListeners();
  }

  void continuarVisitante() => contexto.continuarVisitante();

  Future<void> abrirVistaOffline() async {
    final local = accesoOffline;
    if (local == null || !local.vigente) return;
    ApiClient.soloLocal = true;
    ApiClient.usandoCache.value = true;
    contexto.restaurarVistaLocal(local.empresa, local.usuario);
  }

  Future<void> inicializar() async {
    if (_verificando) return;
    _verificando = true;
    ApiClient.soloLocal = false;
    var habiaSesion = false;
    SesionOffline? local;
    try {
      accesoOffline = null;
      local = await SesionOffline.leer();
      final guardadoToken = await SessionStorage.getToken();
      habiaSesion = guardadoToken != null;
      final guardadoUsuario = await SessionStorage.getUser();
      final codigo =
          await SessionStorage.getEmpresaCodigo() ??
          guardadoUsuario?.empresaCodigo;
      if (local != null &&
          (codigo != local.empresa.codigo ||
              guardadoUsuario?.id != local.usuario.id)) {
        local = null;
      }
      if (local != null &&
          (await Connectivity().checkConnectivity()).contains(
            ConnectivityResult.none,
          )) {
        accesoOffline = local;
        contexto.suspenderParaOffline();
        return;
      }
      if (guardadoToken != null &&
          guardadoUsuario?.esAdminSaas == true &&
          ContextoSesion.sesionValida(guardadoToken, guardadoUsuario!)) {
        await contexto.abrirPlataforma();
        await contexto.guardar(guardadoToken, guardadoUsuario);
        await ApiClient.get(ApiConstants.perfil);
      } else if (codigo != null) {
        final res = await ApiClient.get(
          '${ApiConstants.baseUrl}/empresas/publica/${Uri.encodeComponent(codigo)}',
          withAuth: false,
        );
        await contexto.seleccionar(
          EmpresaPublica.fromJson(res as Map<String, dynamic>),
          recuperar: true,
        );
        if (guardadoToken != null &&
            guardadoUsuario != null &&
            ContextoSesion.sesionValida(guardadoToken, guardadoUsuario) &&
            guardadoUsuario.empresaId == empresa?.id &&
            guardadoUsuario.empresaCodigo == empresa?.codigo) {
          await contexto.guardar(guardadoToken, guardadoUsuario);
          final respuesta =
              await ApiClient.get(ApiConstants.perfil) as Map<String, dynamic>;
          if (SesionOffline.disponible) {
            final perfil = PerfilResponse.fromJson(respuesta);
            if (perfil.id != guardadoUsuario.id ||
                respuesta['empresa_id'] != guardadoUsuario.empresaId) {
              throw StateError('El perfil no corresponde a la sesión.');
            }
            final verificado = UsuarioAutenticado(
              id: perfil.id,
              nombre: perfil.nombre,
              apellido: perfil.apellido,
              username: perfil.username,
              correo: perfil.correo,
              roles: perfil.roles,
              empresaId: guardadoUsuario.empresaId,
              empresaCodigo: guardadoUsuario.empresaCodigo,
            );
            await contexto.actualizar(verificado);
            await _habilitarOffline(verificado);
          }
        } else if (guardadoToken != null) {
          await contexto.cerrar(
            mensaje: 'Inicia sesión nuevamente para continuar.',
            pedirLogin: true,
          );
        }
      } else {
        await contexto.seleccionar(null);
      }
    } catch (error) {
      if (error is ApiException &&
          error.statusCode == null &&
          local != null &&
          local.vigente) {
        accesoOffline = local;
        contexto.suspenderParaOffline();
        return;
      }
      await contexto.cerrar(
        mensaje:
            contexto.aviso ??
            (habiaSesion
                ? 'No se pudo verificar tu sesión. Inicia sesión nuevamente.'
                : null),
        pedirLogin: habiaSesion && (contexto.empresa != null || modoPlataforma),
      );
      if (contexto.empresa == null) _error = 'No se pudo verificar la empresa guardada. Elige una tienda disponible.';
    } finally {
      _verificando = false;
      _inicializado = true;
      notifyListeners();
    }
  }

  Future<void> cerrarAccesoOffline() async {
    ApiClient.soloLocal = false;
    ApiClient.usandoCache.value = false;
    accesoOffline = null;
    await contexto.cerrar(pedirLogin: true);
    await contexto.seleccionar(null);
  }

  Future<void> _habilitarOffline(UsuarioAutenticado usuario) async {
    try {
      await SesionOffline.habilitar(empresa, usuario);
    } on Exception {
      // Un dispositivo sin bloqueo disponible conserva el acceso en línea.
    }
  }

  Future<bool> _accion(Future<void> Function() operacion) async {
    if (_cargando) return false;
    _cargando = true;
    _error = null;
    notifyListeners();
    try {
      await operacion();
      return true;
    } catch (e) {
      _error = e is ApiException
          ? e.message
          : e is StateError
          ? e.message
          : 'No se pudo completar la operación.';
      return false;
    } finally {
      _cargando = false;
      notifyListeners();
    }
  }

  Future<bool> seleccionarEmpresa(EmpresaPublica elegida) => _accion(() async {
    if (estaAutenticado) {
      throw StateError('Cierra tu sesión para cambiar de empresa.');
    }
    final res = await ApiClient.get(
      '${ApiConstants.baseUrl}/empresas/publica/${Uri.encodeComponent(elegida.codigo)}',
      withAuth: false,
    );
    await contexto.seleccionar(
      EmpresaPublica.fromJson(res as Map<String, dynamic>),
    );
  });

  Future<void> cambiarEmpresa() async {
    if (estaAutenticado) await logout();
    await contexto.seleccionar(null);
  }

  Future<bool> login(String identificador, String password) =>
      _accion(() async {
        if (empresa == null && !modoPlataforma) {
          throw StateError('Selecciona una empresa.');
        }
        final res = await ApiClient.post(
          ApiConstants.login,
          body: {
            'identificador': identificador.trim(),
            'password': password,
            'empresa_codigo': modoPlataforma ? null : empresa!.codigo,
          },
          withAuth: false,
        );
        final login = LoginResponse.fromJson(res as Map<String, dynamic>);
        await contexto.guardar(login.accessToken, login.toUsuario());
        await _habilitarOffline(login.toUsuario());
      });

  Future<bool> registrar({
    required String nombre,
    required String apellido,
    required String username,
    required String correo,
    required String password,
    String? telefono,
  }) => _accion(() async {
    if (empresa == null) throw StateError('Selecciona una empresa.');
    await ApiClient.post(
      ApiConstants.registro,
      body: {
        'nombre': nombre.trim(),
        'apellido': apellido.trim(),
        'username': username.trim().toLowerCase(),
        'correo': correo.trim().toLowerCase(),
        'password': password,
        'telefono': telefono?.trim(),
        'empresa_codigo': empresa!.codigo,
      },
      withAuth: false,
    );
    final res = await ApiClient.post(
      ApiConstants.login,
      body: {
        'identificador': username.trim(),
        'password': password,
        'empresa_codigo': empresa!.codigo,
      },
      withAuth: false,
    );
    final login = LoginResponse.fromJson(res as Map<String, dynamic>);
    await contexto.guardar(login.accessToken, login.toUsuario());
    await _habilitarOffline(login.toUsuario());
  });

  Future<void> logout() async {
    accesoOffline = null;
    ApiClient.soloLocal = false;
    ApiClient.usandoCache.value = false;
    await FirebasePush.desvincular();
    if (token != null) {
      try {
        await ApiClient.post(ApiConstants.logout, body: {});
      } catch (_) {}
    }
    await contexto.cerrar();
    _error = null;
  }

  Future<PerfilResponse?> obtenerPerfil() async {
    try {
      final res = await ApiClient.get(ApiConstants.perfil);
      return PerfilResponse.fromJson(res as Map<String, dynamic>);
    } catch (e) {
      _error = e is ApiException ? e.message : 'No se pudo obtener el perfil.';
      notifyListeners();
      return null;
    }
  }

  Future<bool> actualizarPerfil({
    required String nombre,
    required String apellido,
    String? telefono,
    String? username,
    String? correo,
    String? passwordActual,
  }) => _accion(() async {
    final res = await ApiClient.put(
      ApiConstants.perfil,
      body: {
        'nombre': nombre.trim(),
        'apellido': apellido.trim(),
        'telefono': telefono?.trim(),
        if (username != null) 'username': username.trim().toLowerCase(),
        if (correo != null) 'correo': correo.trim().toLowerCase(),
        'password_actual': ?passwordActual,
      },
    ) as Map<String, dynamic>;
    if (res['sesion_revocada'] == true) {
      await contexto.cerrar(
        mensaje: 'Datos de acceso actualizados. Inicia sesión nuevamente.',
        pedirLogin: true,
      );
      return;
    }
    final perfil = PerfilResponse.fromJson(res);
    final actual = usuario;
    if (actual == null ||
        perfil.id != actual.id ||
        res['empresa_id'] != actual.empresaId) {
      throw StateError('El perfil no corresponde a tu sesión.');
    }
    await contexto.actualizar(
      UsuarioAutenticado(
        id: perfil.id,
        nombre: perfil.nombre,
        apellido: perfil.apellido,
        username: perfil.username,
        correo: perfil.correo,
        roles: perfil.roles,
        empresaId: actual.empresaId,
        empresaCodigo: actual.empresaCodigo,
      ),
    );
  });

  Future<bool> cambiarPassword({
    required String passwordActual,
    required String nuevoPassword,
    required String confirmarPasswordNuevo,
  }) => _accion(() async {
    await ApiClient.put(
      ApiConstants.perfilPassword,
      body: {
        'password_actual': passwordActual,
        'password_nuevo': nuevoPassword,
        'confirmar_password_nuevo': confirmarPasswordNuevo,
      },
    );
    await contexto.cerrar(
      mensaje: 'Contraseña actualizada. Inicia sesión nuevamente.',
      pedirLogin: true,
    );
  });

  Future<bool> desactivarCuenta(String password) => _accion(() async {
    await ApiClient.post(
      '${ApiConstants.perfil}/desactivar',
      body: {
        'password_actual': password,
        'confirmacion': 'DESACTIVAR MI CUENTA',
      },
    );
    await contexto.cerrar(
      mensaje: 'Cuenta desactivada. Tu historial se conserva.',
      pedirLogin: true,
    );
  });

  Future<String?> solicitarRecuperacion(String identificador) async {
    String? mensaje;
    final ok = await _accion(() async {
      final res = await ApiClient.post(
        '${ApiConstants.baseUrl}/autenticacion/password-reset/solicitar',
        body: {
          'identificador': identificador.trim(),
          'empresa_codigo': empresa?.codigo,
        },
        withAuth: false,
      ) as Map<String, dynamic>;
      mensaje = res['mensaje'] as String?;
    });
    return ok ? mensaje : null;
  }

  Future<bool> confirmarRecuperacion({
    required String identificador,
    required String codigo,
    required String password,
    required String confirmar,
  }) => _accion(() async {
    await ApiClient.post(
      '${ApiConstants.baseUrl}/autenticacion/password-reset/confirmar',
      body: {
        'identificador': identificador.trim(),
        'empresa_codigo': empresa?.codigo,
        'codigo': codigo.trim(),
        'password_nuevo': password,
        'confirmar_password_nuevo': confirmar,
      },
      withAuth: false,
    );
    await contexto.cerrar(
      mensaje: 'Contraseña actualizada. Inicia sesión nuevamente.',
      pedirLogin: true,
    );
  });
}
