import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Instantáneas por servidor, empresa, usuario y roles; nunca almacena tokens.
class CacheConsultas {
  static const _storage = FlutterSecureStorage();
  static bool admite(Uri uri) =>
      RegExp(
        r'/api/v1/(catalogo|carrito|perfil|recomendaciones|notificaciones|reservas/mis-reservas|pagos/mis-pagos)(/|$)',
      ).hasMatch(uri.path) &&
      !uri.path.contains('/vestidor/');
  static String clave(String ambito, String url) =>
      'stylear_consulta_v1:${base64Url.encode(utf8.encode('$ambito|$url'))}';
  static Future<void> guardar(String ambito, String url, dynamic datos) async {
    try {
      final texto = jsonEncode({
        'fecha': DateTime.now().toUtc().toIso8601String(),
        'datos': datos,
      });
      if (texto.length <= 1000000) {
        await _storage.write(key: clave(ambito, url), value: texto);
      }
    } catch (_) {
      /* La consulta online no depende del almacenamiento local. */
    }
  }

  static Future<Map<String, dynamic>?> leer(String ambito, String url) async {
    try {
      final texto = await _storage.read(key: clave(ambito, url));
      return texto == null ? null : jsonDecode(texto) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
