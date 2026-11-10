import 'dart:convert';
import 'dart:typed_data';

import '../../core/session/contexto_sesion.dart';
import 'acceso_vestidor_cliente.dart';
import 'services/guardar_foto_vestidor.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../catalogo/producto_detalle_screen.dart';
import 'services/vestidor_api_service.dart';

class ProbadorIaScreen extends StatefulWidget {
  final int? productoInicialId;

  const ProbadorIaScreen({super.key, this.productoInicialId});

  @override
  State<ProbadorIaScreen> createState() => _ProbadorIaScreenState();
}

class _ProbadorIaScreenState extends State<ProbadorIaScreen> {
  final ImagePicker _picker = ImagePicker();

  File? _imagenUsuario;
  Uint8List? _imagenResultado;
  bool _guardandoFoto = false;
  int _revisionFoto = 0;
  late final int _generacionSesion;
  bool _procesando = false;
  String _estadoProceso = '';

  List<Map<String, dynamic>> _prendas = [];
  Map<String, dynamic>? _prendaSeleccionada;
  String _tallaSeleccionada = 'M';
  bool _mostrarOriginal = false;
  bool _cargandoCatalogo = true;
  String _filtroCategoria = 'TODAS'; // 'TODAS', 'SUPERIOR', 'INFERIOR'

  final List<String> _tallasDisponibles = ['S', 'M', 'L', 'XL'];

  List<Map<String, dynamic>> get _prendasFiltradas {
    if (_filtroCategoria == 'SUPERIOR') {
      return _prendas.where((p) {
        final tipo = (p['tipo_prenda'] ?? '').toString().toUpperCase();
        return tipo == 'SUPERIOR' || tipo == 'VESTIDO';
      }).toList();
    } else if (_filtroCategoria == 'INFERIOR') {
      return _prendas.where((p) {
        final tipo = (p['tipo_prenda'] ?? '').toString().toUpperCase();
        final nom = (p['nombre'] ?? '').toString().toLowerCase();
        return tipo == 'INFERIOR' ||
            nom.contains('jean') ||
            nom.contains('pant');
      }).toList();
    }
    return _prendas;
  }

  @override
  void initState() {
    super.initState();
    _generacionSesion = ContextoSesion.instance.generacion;
    ContextoSesion.instance.addListener(_cambioSesion);
    _cargarPrendas();
  }

  void _cambioSesion() {
    if (!mounted || ContextoSesion.instance.generacion == _generacionSesion) {
      return;
    }
    _revisionFoto++;
    setState(() {
      _imagenResultado = null;
      _imagenUsuario = null;
      _procesando = false;
    });
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _revisionFoto++;
    _imagenResultado = null;
    ContextoSesion.instance.removeListener(_cambioSesion);
    super.dispose();
  }

  Future<void> _guardarFoto() async {
    final foto = _imagenResultado;
    if (foto == null ||
        _guardandoFoto ||
        !context.read<AuthProvider>().esCliente) {
      return;
    }
    setState(() => _guardandoFoto = true);
    try {
      final guardada = await GuardarFotoVestidor.guardar(foto);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              guardada
                  ? 'Foto guardada en el destino elegido del teléfono.'
                  : 'Guardado cancelado.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo guardar la foto. Intenta nuevamente.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _guardandoFoto = false);
    }
  }

  Future<void> _cargarPrendas() async {
    try {
      final items = await VestidorApiService.listarPrendasDisponibles();
      if (!mounted) return;
      setState(() {
        _prendas = items;
        if (items.isNotEmpty) {
          if (widget.productoInicialId != null) {
            final inicial = items.firstWhere(
              (p) => p['producto_id'] == widget.productoInicialId,
              orElse: () => items.first,
            );
            _prendaSeleccionada = inicial;
            final tipo = (inicial['tipo_prenda'] ?? '')
                .toString()
                .toUpperCase();
            final nom = (inicial['nombre'] ?? '').toString().toLowerCase();
            if (tipo == 'INFERIOR' ||
                nom.contains('jean') ||
                nom.contains('pant')) {
              _filtroCategoria = 'INFERIOR';
            } else if (tipo == 'SUPERIOR') {
              _filtroCategoria = 'SUPERIOR';
            }
          } else {
            _prendaSeleccionada = items.first;
          }
        }
        _cargandoCatalogo = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargandoCatalogo = false);
    }
  }

  Future<void> _seleccionarImagen(ImageSource origen) async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: origen,
        maxWidth: 1400,
        maxHeight: 1800,
        imageQuality: 88,
      );
      if (picked != null) {
        setState(() {
          _imagenUsuario = File(picked.path);
          _imagenResultado = null;
          _mostrarOriginal = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo abrir la cámara/galería: $e')),
        );
      }
    }
  }

  Future<void> _ejecutarTryOnIA() async {
    if (_imagenUsuario == null || _prendaSeleccionada == null) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    if (!auth.estaAutenticado || !auth.esCliente) return;
    final revision = ++_revisionFoto;
    final productoId = _prendaSeleccionada!['producto_id'] as int;

    final tipo = (_prendaSeleccionada!['tipo_prenda'] ?? '')
        .toString()
        .toUpperCase();
    final nom = (_prendaSeleccionada!['nombre'] ?? '').toString().toLowerCase();
    final bool esInferior =
        tipo == 'INFERIOR' || nom.contains('jean') || nom.contains('pant');

    setState(() {
      _procesando = true;
      _estadoProceso = 'Subiendo fotografía de alta resolución...';
    });

    Timer? ticker;
    ticker = Timer.periodic(const Duration(seconds: 3), (t) {
      if (!mounted || !_procesando) {
        t.cancel();
        return;
      }
      setState(() {
        if (t.tick == 1) {
          _estadoProceso = esInferior
              ? 'Detectando silueta anatómica y extremidades inferiores...'
              : 'Segmentando silueta y postura corporal con IA...';
        } else if (t.tick == 2) {
          _estadoProceso = esInferior
              ? 'Ajustando proporción del pantalón de cintura a tobillos...'
              : 'Generando caída textil y adaptando torso con IA...';
        } else if (t.tick == 3) {
          _estadoProceso =
              'Sintetizando iluminación y sombras fotorrealistas...';
        } else {
          _estadoProceso = 'Finalizando renderizado de alta definición...';
        }
      });
    });

    try {
      final resultado = await VestidorApiService.probarPrendaConIA(
        imagen: _imagenUsuario!,
        productoId: productoId,
        talla: _tallaSeleccionada,
      );

      ticker.cancel();
      if (!mounted) return;

      if (revision != _revisionFoto ||
          ContextoSesion.instance.generacion != _generacionSesion) {
        return;
      }
      final codificada = resultado['imagen_resultado_base64'] as String?;
      if (codificada == null || codificada.isEmpty) {
        throw const FormatException('El servidor no devolvió una imagen.');
      }
      final foto = base64Decode(codificada);
      setState(() {
        _imagenResultado = foto;
        _procesando = false;
        _mostrarOriginal = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            esInferior
                ? 'Prueba del pantalón lista. Puedes comparar o guardar el resultado.'
                : 'Prueba lista. Puedes comparar o guardar el resultado.',
          ),
          backgroundColor: const Color(0xFF10B981),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      ticker.cancel();
      if (!mounted) return;
      if (revision != _revisionFoto) return;
      setState(() => _procesando = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error en el probador IA: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _irADetallePrenda() {
    if (_prendaSeleccionada == null) return;
    final id = _prendaSeleccionada!['producto_id'] as int;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ProductoDetalleScreen(productoId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (!auth.estaAutenticado || !auth.esCliente) {
      return const AccesoVestidorCliente();
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: Color(0xFF00E5FF), size: 22),
            SizedBox(width: 8),
            Text(
              'Probador IA Virtual',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          if (_imagenUsuario != null)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white70),
              tooltip: 'Reiniciar foto',
              onPressed: () {
                setState(() {
                  _imagenUsuario = null;
                  _imagenResultado = null;
                });
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Visor Central
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: _buildVisorPrincipal(),
              ),
            ),

            // Controles inferiores
            _buildBarraInferior(),
          ],
        ),
      ),
    );
  }

  Widget _buildVisorPrincipal() {
    // 1. Si no hay foto seleccionada
    if (_imagenUsuario == null) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white10),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.camera_front_rounded,
                size: 56,
                color: Color(0xFF00E5FF),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Estudio de Moda Inteligente',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Toma una foto de cuerpo entero o selecciona una de tu galería para probarte la ropa con IA.',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 13,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: const Color(0xFF0F172A),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.camera_alt_rounded),
                    label: const Text(
                      'Tomar Foto',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _seleccionarImagen(ImageSource.camera),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text(
                      'Galería',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () => _seleccionarImagen(ImageSource.gallery),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lightbulb_outline, color: Colors.amber, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tip: Procura que la foto sea vertical con buena iluminación para un ajuste exacto.',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 2. Si hay foto (procesando, con resultado o lista para procesar)
    final mostrarUrl = (_imagenResultado != null && !_mostrarOriginal);

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Imagen (Original o Resultado IA)
          mostrarUrl
              ? Image.memory(
                  _imagenResultado!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                )
              : Image.file(_imagenUsuario!, fit: BoxFit.cover),

          // Gradiente superior sutil
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 70,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Badge indicador superior
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _imagenResultado != null
                      ? const Color(0xFF10B981)
                      : const Color(0xFF00E5FF),
                  width: 1.2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _imagenResultado != null
                        ? Icons.verified
                        : Icons.photo_camera_back,
                    color: _imagenResultado != null
                        ? const Color(0xFF10B981)
                        : const Color(0xFF00E5FF),
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _imagenResultado != null
                        ? (_mostrarOriginal
                              ? 'Foto Original'
                              : 'Ajuste IA • StyleAR')
                        : 'Foto Cargada',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Botón Comparador Antes / Después (si ya hay resultado)
          if (_imagenResultado != null)
            Positioned(
              top: 12,
              right: 12,
              child: GestureDetector(
                onTapDown: (_) => setState(() => _mostrarOriginal = true),
                onTapUp: (_) => setState(() => _mostrarOriginal = false),
                onTapCancel: () => setState(() => _mostrarOriginal = false),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.compare_arrows_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Mantén para comparar',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Overlay de Procesando
          if (_procesando)
            Container(
              color: Colors.black.withValues(alpha: 0.75),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 50,
                      height: 50,
                      child: CircularProgressIndicator(
                        color: Color(0xFF00E5FF),
                        strokeWidth: 3.5,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _estadoProceso,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Optimizado por StyleAR Cloud AI Engine',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBarraInferior() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Selector de Prenda y Talla
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Prendas 3D Disponibles',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              // Selector de Talla
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: _tallasDisponibles.map((t) {
                    final selected = _tallaSeleccionada == t;
                    return GestureDetector(
                      onTap: () => setState(() => _tallaSeleccionada = t),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF00E5FF)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          t,
                          style: TextStyle(
                            color: selected
                                ? const Color(0xFF0F172A)
                                : Colors.white60,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Filtros rápidos de categoría
          Row(
            children: [
              _buildFiltroChip('TODAS', 'Todas'),
              const SizedBox(width: 6),
              _buildFiltroChip('SUPERIOR', 'Superiores (Top)'),
              const SizedBox(width: 6),
              _buildFiltroChip('INFERIOR', 'Pantalones (Bottom)'),
            ],
          ),
          const SizedBox(height: 10),

          // Carrusel horizontal de prendas
          if (_cargandoCatalogo)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF00E5FF)),
            )
          else if (_prendasFiltradas.isEmpty)
            const SizedBox(
              height: 80,
              child: Center(
                child: Text(
                  'No hay prendas en esta categoría.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            )
          else
            SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _prendasFiltradas.length,
                separatorBuilder: (context, index) => const SizedBox(width: 10),
                itemBuilder: (ctx, i) {
                  final p = _prendasFiltradas[i];
                  final isSelected =
                      _prendaSeleccionada?['producto_id'] == p['producto_id'];
                  final tipo = (p['tipo_prenda'] ?? '')
                      .toString()
                      .toUpperCase();
                  final nom = (p['nombre'] ?? '').toString().toLowerCase();
                  final esInferior =
                      tipo == 'INFERIOR' ||
                      nom.contains('jean') ||
                      nom.contains('pant');

                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _prendaSeleccionada = p;
                        _imagenResultado = null; // Reiniciar para nueva prueba
                      });
                    },
                    child: Container(
                      width: 175,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF00E5FF).withValues(alpha: 0.15)
                            : Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFF00E5FF)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              p['imagen_url'] ?? '',
                              width: 50,
                              height: 68,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Container(
                                    width: 50,
                                    height: 68,
                                    color: Colors.black26,
                                    child: const Icon(
                                      Icons.checkroom,
                                      color: Colors.white54,
                                    ),
                                  ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: esInferior
                                            ? Colors.orangeAccent.withValues(
                                                alpha: 0.2,
                                              )
                                            : Colors.blueAccent.withValues(
                                                alpha: 0.2,
                                              ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        esInferior ? 'BOTTOM' : 'TOP',
                                        style: TextStyle(
                                          color: esInferior
                                              ? Colors.orangeAccent
                                              : Colors.lightBlueAccent,
                                          fontSize: 8,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      'Bs. ${(p['precio_desde'] ?? 0.0).toStringAsFixed(0)}',
                                      style: const TextStyle(
                                        color: Color(0xFF00E5FF),
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  p['nombre'] ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  p['tipo_corte'] ?? 'REGULAR',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 9,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 16),

          if (_imagenResultado != null) ...[
            OutlinedButton.icon(
              onPressed: _guardandoFoto ? null : _guardarFoto,
              icon: const Icon(Icons.save_alt, color: Colors.white),
              label: Text(
                _guardandoFoto ? 'Guardando...' : 'Guardar foto en el teléfono',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'El resultado solo se conserva si eliges Guardar.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
          // Botones de acción final
          if (_imagenResultado != null)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Otra Prenda'),
                    onPressed: () => setState(() => _imagenResultado = null),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.shopping_bag_outlined),
                    label: const Text(
                      'Reservar Prenda',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: _irADetallePrenda,
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: const Color(0xFF0F172A),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 4,
                ),
                icon: const Icon(Icons.auto_awesome),
                label: const Text(
                  'Probar Prenda con IA',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                onPressed: (_imagenUsuario != null && !_procesando)
                    ? _ejecutarTryOnIA
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFiltroChip(String categoria, String label) {
    final bool isSelected = _filtroCategoria == categoria;
    return GestureDetector(
      onTap: () => setState(() => _filtroCategoria = categoria),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00E5FF) : Colors.white10,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFF00E5FF) : Colors.white12,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF0F172A) : Colors.white70,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
