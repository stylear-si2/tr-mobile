import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/auth_models.dart';
import '../../models/empresa_models.dart';
import '../storage/session_storage.dart';

class ContextoSesion extends ChangeNotifier {
  static final instance = ContextoSesion();
  EmpresaPublica? empresa;
  UsuarioAutenticado? usuario;
  String? token;
  String? aviso;
  bool requiereLogin = false;
  bool modoPlataforma = false;
  int generacion = 0;
  Future<void> _persistencia = Future.value();

  Future<void> _persistir(Future<void> Function() operacion) {
    _persistencia = _persistencia
        .catchError((Object _) {})
        .then((_) => operacion());
    return _persistencia;
  }

  static bool sesionValida(String token, UsuarioAutenticado usuario) {
    try {
      final partes = token.split('.');
      if (partes.length != 3) return false;
      final cuerpo = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(partes[1]))),
      ) as Map<String, dynamic>;
      final exp = cuerpo['exp'];
      final plataforma =
          usuario.roles.contains('ADMIN_SAAS') &&
          usuario.empresaId == null &&
          usuario.empresaCodigo == null &&
          cuerpo['empresa_codigo'] == null;
      final comercial =
          !usuario.roles.contains('ADMIN_SAAS') &&
          usuario.empresaId != null &&
          usuario.empresaId! > 0 &&
          usuario.empresaCodigo != null &&
          RegExp(r'^[a-z0-9][a-z0-9-]{1,39}$').hasMatch(usuario.empresaCodigo!);
      return exp is num &&
          exp * 1000 > DateTime.now().millisecondsSinceEpoch &&
          cuerpo['sid'] != null &&
          cuerpo['sub'].toString() == usuario.id.toString() &&
          cuerpo.containsKey('empresa_id') &&
          cuerpo['empresa_id'] == usuario.empresaId &&
          (plataforma || comercial);
    } catch (_) {
      return false;
    }
  }

  Future<void> seleccionar(
    EmpresaPublica? seleccion, {
    bool recuperar = false,
  }) async {
    if (seleccion?.estado == 'CANCELADA') {
      throw StateError('Empresa no disponible.');
    }
    empresa = seleccion;
    modoPlataforma = false;
    usuario = null;
    token = null;
    aviso = null;
    requiereLogin = false;
    generacion++;
    notifyListeners();
    await _persistir(() async {
      if (!recuperar) await SessionStorage.clearSession();
      await SessionStorage.setEmpresaCodigo(seleccion?.codigo);
    });
  }

  Future<void> abrirPlataforma() async {
    await seleccionar(null);
    modoPlataforma = true;
    notifyListeners();
  }

  Future<void> guardar(
    String nuevoToken,
    UsuarioAutenticado nuevoUsuario,
  ) async {
    if (!sesionValida(nuevoToken, nuevoUsuario) ||
        modoPlataforma != nuevoUsuario.roles.contains('ADMIN_SAAS') ||
        empresa?.id != nuevoUsuario.empresaId ||
        empresa?.codigo != nuevoUsuario.empresaCodigo) {
      throw StateError('La sesión no corresponde a la empresa elegida.');
    }
    token = nuevoToken;
    usuario = nuevoUsuario;
    aviso = null;
    requiereLogin = false;
    generacion++;
    notifyListeners();
    await _persistir(
      () =>
          SessionStorage.saveSession(token: nuevoToken, usuario: nuevoUsuario),
    );
  }

  Future<void> cerrar({String? mensaje, bool pedirLogin = false}) async {
    token = null;
    usuario = null;
    aviso = mensaje;
    requiereLogin = pedirLogin;
    generacion++;
    notifyListeners();
    await _persistir(SessionStorage.clearSession);
  }

  void restaurarVistaLocal(EmpresaPublica tienda, UsuarioAutenticado cuenta) {
    empresa = tienda;
    usuario = cuenta;
    token = null;
    requiereLogin = false;
    modoPlataforma = false;
    notifyListeners();
  }

  void suspenderParaOffline() {
    token = null;
    usuario = null;
    generacion++;
    notifyListeners();
  }

  Future<void> actualizar(UsuarioAutenticado actualizado) async {
    if (usuario?.id != actualizado.id ||
        usuario?.empresaId != actualizado.empresaId ||
        token == null) {
      return;
    }
    usuario = actualizado;
    notifyListeners();
    final actualToken = token!;
    await _persistir(
      () =>
          SessionStorage.saveSession(token: actualToken, usuario: actualizado),
    );
  }

  void continuarVisitante() {
    requiereLogin = false;
    aviso = null;
    notifyListeners();
  }
}

// Old requests may finish after a session change. Their providers are discarded;
// suppress their final notifications instead of touching the new user's state.
class SessionBoundNotifier extends ChangeNotifier {
  final int _generacion = ContextoSesion.instance.generacion;
  bool _eliminado = false;
  @override
  void notifyListeners() {
    if (!_eliminado && _generacion == ContextoSesion.instance.generacion) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _eliminado = true;
    super.dispose();
  }
}
