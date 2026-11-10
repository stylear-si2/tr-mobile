import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../models/analisis_reporte.dart';
import '../../core/session/contexto_sesion.dart';
import '../../models/reporte_models.dart';
import '../../services/reporte_service.dart';
import '../saas/saas_widgets.dart';

class AnalisisReportePanel extends StatefulWidget {
  final ReporteFiltros filtros;
  final String? firmaResultado;
  final bool habilitado, vozHabilitada;
  final ValueChanged<AnalisisReporte?> onResultado;
  const AnalisisReportePanel({
    super.key,
    required this.filtros,
    this.firmaResultado,
    required this.habilitado,
    required this.vozHabilitada,
    required this.onResultado,
  });
  @override
  State<AnalisisReportePanel> createState() => _AnalisisReportePanelState();
}

class _AnalisisReportePanelState extends State<AnalisisReportePanel>
    with PantallaSesion {
  AnalisisReporte? _analisis;
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _estado;
  Uint8List? _audio;
  bool _cargando = false, _generandoAudio = false, _reproduciendo = false;
  String? _error;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    ContextoSesion.instance.addListener(_cambioSesion);
  }

  void _cambioSesion() {
    if (!vigente) {
      _revision++;
      unawaited(_player?.stop());
      _audio = null;
      if (mounted) {
        setState(() {
          _analisis = null;
          _cargando = false;
          _generandoAudio = false;
          _reproduciendo = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant AnalisisReportePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.vozHabilitada || !widget.habilitado) {
      unawaited(_player?.stop());
    }
  }

  @override
  void dispose() {
    ContextoSesion.instance.removeListener(_cambioSesion);
    _revision++;
    unawaited(_estado?.cancel());
    unawaited(_player?.dispose());
    _audio = null;
    super.dispose();
  }

  Future<void> _analizar() async {
    if (_cargando) return;
    final revision = ++_revision;
    await _player?.stop();
    if (!vigente) return;
    widget.onResultado(null);
    setState(() {
      _cargando = true;
      _error = null;
      _analisis = null;
      _audio = null;
      _reproduciendo = false;
    });
    try {
      final a = await ReporteService.analizar(
        widget.filtros,
        firmaResultado: widget.firmaResultado,
      );
      if (!vigente || revision != _revision) return;
      setState(() => _analisis = a);
      widget.onResultado(a);
    } catch (e) {
      if (vigente && revision == _revision) {
        setState(() => _error = explicar(e));
      }
    } finally {
      if (vigente && revision == _revision) setState(() => _cargando = false);
    }
  }

  Future<void> _escuchar() async {
    final a = _analisis;
    if (a == null || _generandoAudio) return;
    final revision = _revision;
    setState(() {
      _generandoAudio = true;
      _error = null;
    });
    try {
      if (_reproduciendo) {
        await _player?.pause();
        return;
      }
      final bytes = _audio ?? await ReporteService.audioAnalisis(a.id);
      if (!vigente || revision != _revision) return;
      _audio = bytes;
      if (_player == null) {
        _player = AudioPlayer();
        _estado = _player!.onPlayerStateChanged.listen((estado) {
          if (vigente) {
            setState(() => _reproduciendo = estado == PlayerState.playing);
          }
        });
      }
      if (_player!.state == PlayerState.paused) {
        await _player!.resume();
      } else {
        await _player!.play(BytesSource(bytes, mimeType: 'audio/wav'));
      }
    } catch (_) {
      if (vigente && revision == _revision) {
        setState(
          () => _error = 'No se pudo reproducir la voz. El análisis escrito sigue disponible.',
        );
      }
    } finally {
      if (vigente && revision == _revision) {
        setState(() => _generandoAudio = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Análisis inteligente',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Explicación y gráfico seleccionados a partir de los resultados del reporte.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: widget.habilitado && !_cargando && !_generandoAudio
                ? _analizar
                : null,
            icon: const Icon(Icons.auto_awesome),
            label: Text(
              _cargando
                  ? 'Analizando…'
                  : _analisis == null
                  ? 'Analizar con IA'
                  : 'Actualizar análisis',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_analisis case final a?) ...[
            const SizedBox(height: 12),
            Text(
              a.motor == 'REGLAS'
                  ? 'Resumen automático · IA no disponible'
                  : a.motor == 'SIN_DATOS'
                  ? 'Sin datos'
                  : 'Generado con IA · Revisa los datos de respaldo',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            SelectableText(
              a.narrativa,
              style: const TextStyle(height: 1.6, fontSize: 15),
            ),
            for (final conclusion in a.conclusiones)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('• $conclusion'),
              ),
            const Divider(height: 28),
            Text('Gráfico seleccionado: ${a.motivo}'),
            for (final aviso in a.advertencias)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(aviso),
              ),
            if (a.audioDisponible && widget.vozHabilitada) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _generandoAudio ? null : _escuchar,
                icon: Icon(_reproduciendo ? Icons.pause : Icons.volume_up),
                label: Text(
                  _generandoAudio
                      ? 'Preparando voz…'
                      : _reproduciendo
                      ? 'Pausar'
                      : _audio == null
                      ? 'Escuchar análisis'
                      : 'Reproducir análisis',
                ),
              ),
              const Text(
                'La voz se genera al solicitarla y se reutiliza al volver a escucharla.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'El análisis es opcional. La tabla sigue disponible.',
                style: TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    ),
  );
}
