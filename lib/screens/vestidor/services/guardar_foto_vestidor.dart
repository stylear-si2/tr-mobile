
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Solo se invoca por la acción explícita Guardar; nunca durante el renderizado.
class GuardarFotoVestidor {
  static const canal = MethodChannel('stylear/vestidor-fotos');
  static Future<bool> guardar(Uint8List bytes) async {
    if (defaultTargetPlatform != TargetPlatform.android || kIsWeb) {
      throw UnsupportedError(
        'El guardado de fotos está disponible en Android.',
      );
    }
    return await canal.invokeMethod<bool>('guardar', {'bytes': bytes}) ?? false;
  }
}
