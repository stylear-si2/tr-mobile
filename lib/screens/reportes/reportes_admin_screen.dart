import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/plan_provider.dart';
import '../saas/saas_widgets.dart';
import 'dashboard_comercial_tab.dart';
import 'analitica_screen.dart';
import 'programados_reportes_tab.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_colors.dart';
import '../../core/network/api_exceptions.dart';
import '../../models/reporte_models.dart';
import '../../models/analisis_reporte.dart';
import 'analisis_reporte_panel.dart';
import 'grafico_reporte_ia.dart';
import '../../services/file_download_service.dart';
import '../../services/reporte_service.dart';
import '../../services/voz_service.dart';

/// Reportes y dashboard comercial con alcance de administrador o encargado (CU22).
class ReportesAdminScreen extends StatefulWidget {
  const ReportesAdminScreen({super.key});

  @override
  State<ReportesAdminScreen> createState() => _ReportesAdminScreenState();
}

class _ReportesAdminScreenState extends State<ReportesAdminScreen>
    with SingleTickerProviderStateMixin, PantallaSesion {
  // ── Estado del catálogo ──────────────────────────────────────────────
  ReporteCatalogo? _catalogo;
  bool _cargandoCatalogo = false;
  String? _errorCatalogo;

  // ── Filtros seleccionados ────────────────────────────────────────────
  TipoReporte _tipoSeleccionado = TipoReporte.ventas;
  DateTime _fechaDesde = DateTime.now().subtract(const Duration(days: 30));
  DateTime _fechaHasta = DateTime.now();
  int? _sucursalId;
  String _agrupacion = 'DIA';
  int? _categoriaId;
  int? _productoId;
  int _limite = 10;
  bool _soloBajoStock = false;
  String? _estado;
  String? _metodoPago;
  String? _proveedorPago;
  String? _tipoEntrega;
  String? _rol;
  bool? _activo;

  // ── Estado del reporte ───────────────────────────────────────────────
  ReporteResultado? _resultado;
  bool _generando = false;
  String? _errorReporte;

  // ── Exportar ─────────────────────────────────────────────────────────
  bool _exportando = false;

  ReporteFiltros? _filtrosResultado;
  String? _tipoVenta;
  int _revisionConsulta = 0;
  int _revisionAnalisis = 0;
  AnalisisReporte? _analisis;
  bool get _esAdmin => context.read<AuthProvider>().esAdmin;
  bool _capacidad(String clave) =>
      context.read<PlanProvider>().capacidades?.habilita(clave) == true;
  // ── Tab controller ───────────────────────────────────────────────────
  late TabController _tabController;

  static const _dateFormat = 'yyyy-MM-dd';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _esAdmin ? 4 : 3, vsync: this);
    _cargarCatalogo();
  }

  @override
  void dispose() {
    VozService.cancelar();
    _tabController.dispose();
    super.dispose();
  }

  // ── Carga de catálogo ────────────────────────────────────────────────

  Future<void> _cargarCatalogo() async {
    setState(() {
      _cargandoCatalogo = true;
      _errorCatalogo = null;
    });
    try {
      final catalogo = await ReporteService.obtenerCatalogo();
      if (mounted && vigente) {
        setState(() {
          _catalogo = catalogo;
          if (!_esAdmin) _sucursalId = catalogo.sucursales.firstOrNull?.id;
        });
        // Generar automáticamente el reporte inicial con los filtros por defecto
        _generarReporte(irAResultados: false);
      }
    } on ApiException catch (e) {
      if (mounted && vigente) setState(() => _errorCatalogo = e.message);
    } catch (_) {
      if (mounted && vigente) {
        setState(
          () => _errorCatalogo = 'Error al cargar el catálogo de reportes.',
        );
      }
    } finally {
      if (mounted && vigente) setState(() => _cargandoCatalogo = false);
    }
  }

  // ── Generar reporte ──────────────────────────────────────────────────

  Future<void> _generarReporte({
    bool irAResultados = true,
    int pagina = 1,
    bool reutilizar = false,
  }) async {
    if (_generando) return;
    final revision = ++_revisionConsulta;
    setState(() {
      _generando = true;
      _errorReporte = null;
      if (!reutilizar) {
        _resultado = null;
        _analisis = null;
        _revisionAnalisis++;
      }
    });

    try {
      final filtros = reutilizar ? _filtrosResultado! : _buildFiltros();
      final resultado = await ReporteService.detalle(filtros, pagina: pagina);
      if (mounted && vigente) {
        if (revision != _revisionConsulta) return;
        setState(() {
          if (_resultado != null &&
              (jsonEncode(_resultado!.resumen) !=
                      jsonEncode(resultado.resumen) ||
                  jsonEncode(
                        _resultado!.serieGrafico
                            .map((s) => [s.label, s.valor])
                            .toList(),
                      ) !=
                      jsonEncode(
                        resultado.serieGrafico
                            .map((s) => [s.label, s.valor])
                            .toList(),
                      ))) {
            _analisis = null;
            _revisionAnalisis++;
          }
          _resultado = resultado;
          _filtrosResultado = filtros;
        });
        if (irAResultados) {
          _tabController.animateTo(1);
        }
      }
    } on ApiException catch (e) {
      if (mounted && vigente) setState(() => _errorReporte = e.message);
    } catch (_) {
      if (mounted && vigente) {
        setState(() => _errorReporte = 'Error al generar el reporte.');
      }
    } finally {
      if (mounted && vigente) setState(() => _generando = false);
    }
  }

  // ── Exportar ─────────────────────────────────────────────────────────

  Future<void> _exportar(String formato) async {
    if (_resultado == null ||
        _exportando ||
        _resultado!.totalFilas > 5000 ||
        (formato != 'html' &&
            !_capacidad(
              formato == 'pdf' ? 'reportes_pdf' : 'reportes_excel',
            ))) {
      return;
    }

    setState(() => _exportando = true);

    try {
      final filtros = _filtrosResultado!;
      final Uint8List bytes;
      final String ext;
      final String mimeType;

      if (formato == 'html') {
        final completo = await ReporteService.generar(filtros);
        if (!mounted || !vigente) return;
        bytes = Uint8List.fromList(utf8.encode(_buildHtmlReporte(completo)));
        ext = 'html';
        mimeType = 'text/html; charset=utf-8';
      } else if (formato == 'pdf') {
        bytes = await ReporteService.exportarPdf(
          filtros,
          analisisId: _analisis?.id,
        );
        ext = 'pdf';
        mimeType = 'application/pdf';
      } else {
        bytes = await ReporteService.exportarExcel(
          filtros,
          analisisId: _analisis?.id,
        );
        ext = 'xlsx';
        mimeType =
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      }

      if (!mounted || !vigente) return;
      final fname =
          '${filtros.tipo.valor.toLowerCase()}_${filtros.fechaDesde}_${filtros.fechaHasta}.$ext';
      final ubicacion = await FileDownloadService.guardarYMostrarArchivo(
        bytes: bytes,
        nombreArchivo: fname,
        mimeType: mimeType,
      );

      if (!mounted || !vigente) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ubicacion == null
                ? 'Descarga iniciada.'
                : 'Archivo guardado en: $ubicacion',
          ),
          backgroundColor: AppColors.success,
          duration: const Duration(seconds: 4),
        ),
      );
    } on ApiException catch (e) {
      if (mounted && vigente) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: AppColors.danger),
        );
      }
    } catch (e) {
      if (mounted && vigente) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al exportar el reporte.'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    } finally {
      if (mounted && vigente) setState(() => _exportando = false);
    }
  }

  String _buildHtmlReporte(ReporteResultado resultado) {
    final fechaDesde = DateFormat(_dateFormat).format(_fechaDesde);
    final fechaHasta = DateFormat(_dateFormat).format(_fechaHasta);
    final generadoEn = resultado.generadoEn.isNotEmpty
        ? resultado.generadoEn
        : DateTime.now().toIso8601String();

    final buffer = StringBuffer()
      ..writeln('<!doctype html>')
      ..writeln('<html lang="es">')
      ..writeln('<head>')
      ..writeln('<meta charset="utf-8">')
      ..writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
      )
      ..writeln('<title>${_htmlEscape(resultado.titulo)}</title>')
      ..writeln('''
<style>
  :root { color-scheme: light; --accent:#82936a; --border:#deded8; --text:#181818; --muted:#6f6f6f; }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: Arial, Helvetica, sans-serif; background: #f7f7f3; color: var(--text); }
  main { max-width: 1100px; margin: 32px auto; padding: 0 20px 40px; }
  .card { background: #fff; border: 1px solid var(--border); border-radius: 18px; padding: 24px; box-shadow: 0 10px 28px rgba(0,0,0,.06); }
  .eyebrow { color: var(--accent); font-size: 12px; font-weight: 800; letter-spacing: .18em; text-transform: uppercase; }
  h1 { margin: 8px 0 8px; font-size: 34px; line-height: 1.1; }
  .meta { color: var(--muted); margin: 4px 0; }
  .note { margin-top: 14px; padding: 12px 14px; background: #eef4e6; border-radius: 12px; color: #49613f; }
  .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin: 24px 0; }
  .metric { border: 1px solid var(--border); border-radius: 14px; padding: 16px; background: #fbfbf8; }
  .metric span { display: block; color: var(--muted); font-size: 13px; font-weight: 700; }
  .metric strong { display: block; margin-top: 8px; font-size: 26px; }
  h2 { margin: 26px 0 12px; font-size: 20px; }
  .bars { display: grid; gap: 10px; margin-bottom: 18px; }
  .bar-row { display: grid; grid-template-columns: minmax(90px, 180px) 1fr minmax(60px, 100px); gap: 10px; align-items: center; }
  .bar-label { color: var(--muted); overflow-wrap: anywhere; }
  .bar-track { height: 18px; background: #eeeeea; border-radius: 999px; overflow: hidden; }
  .bar-fill { height: 100%; background: var(--accent); border-radius: 999px; }
  .bar-value { text-align: right; font-weight: 700; }
  .table-wrap { overflow-x: auto; border: 1px solid var(--border); border-radius: 14px; }
  table { width: 100%; border-collapse: collapse; min-width: 720px; }
  th, td { padding: 12px 14px; border-bottom: 1px solid var(--border); text-align: left; vertical-align: top; }
  th { background: #f1f1ee; color: #666; font-size: 13px; text-transform: uppercase; letter-spacing: .04em; }
  tr:last-child td { border-bottom: 0; }
  footer { margin-top: 20px; color: var(--muted); font-size: 12px; text-align: center; }
  @media print { body { background: #fff; } main { margin: 0; max-width: none; } .card { box-shadow: none; border: 0; } }
</style>
''')
      ..writeln('</head>')
      ..writeln('<body>')
      ..writeln('<main>')
      ..writeln('<section class="card">')
      ..writeln('<div class="eyebrow">Reporte StyleAR</div>')
      ..writeln('<h1>${_htmlEscape(resultado.titulo)}</h1>')
      ..writeln(
        '<p class="meta">Periodo: ${_htmlEscape(fechaDesde)} al ${_htmlEscape(fechaHasta)}</p>',
      )
      ..writeln('<p class="meta">Generado: ${_htmlEscape(generadoEn)}</p>')
      ..writeln('<p class="meta">Filas: ${resultado.totalFilas}</p>');

    final nota = resultado.nota?.trim();
    if (nota != null && nota.isNotEmpty) {
      buffer.writeln('<div class="note">${_htmlEscape(nota)}</div>');
    }

    if (resultado.indicadores.isNotEmpty) {
      buffer.writeln('<div class="metrics">');
      for (final indicador in resultado.indicadores) {
        buffer
          ..writeln('<div class="metric">')
          ..writeln('<span>${_htmlEscape(indicador.label)}</span>')
          ..writeln(
            '<strong>${_htmlEscape(_valorCelda(indicador.valor))}</strong>',
          )
          ..writeln('</div>');
      }
      buffer.writeln('</div>');
    }

    if (resultado.serieGrafico.isNotEmpty) {
      final maxVal = resultado.serieGrafico
          .map((e) => e.valor.toDouble())
          .reduce((a, b) => a > b ? a : b);
      buffer
        ..writeln('<h2>Evolución temporal</h2>')
        ..writeln('<div class="bars">');
      for (final item in resultado.serieGrafico) {
        final width = maxVal > 0
            ? (item.valor.toDouble() / maxVal * 100).clamp(2, 100)
            : 2;
        buffer
          ..writeln('<div class="bar-row">')
          ..writeln('<div class="bar-label">${_htmlEscape(item.label)}</div>')
          ..writeln(
            '<div class="bar-track"><div class="bar-fill" style="width:$width%"></div></div>',
          )
          ..writeln(
            '<div class="bar-value">${_htmlEscape(item.valor.toString())}</div>',
          )
          ..writeln('</div>');
      }
      buffer.writeln('</div>');
    }

    if (resultado.filas.isNotEmpty) {
      buffer
        ..writeln('<h2>Tabla de datos</h2>')
        ..writeln('<div class="table-wrap">')
        ..writeln('<table>')
        ..writeln('<thead><tr>');
      for (final columna in resultado.columnas) {
        buffer.writeln('<th>${_htmlEscape(columna.label)}</th>');
      }
      buffer.writeln('</tr></thead><tbody>');
      for (final fila in resultado.filas) {
        buffer.writeln('<tr>');
        for (final columna in resultado.columnas) {
          buffer.writeln(
            '<td>${_htmlEscape(_valorCelda(fila[columna.key]))}</td>',
          );
        }
        buffer.writeln('</tr>');
      }
      buffer
        ..writeln('</tbody>')
        ..writeln('</table>')
        ..writeln('</div>');
    }

    buffer
      ..writeln('<footer>Archivo HTML generado desde StyleAR.</footer>')
      ..writeln('</section>')
      ..writeln('</main>')
      ..writeln('</body>')
      ..writeln('</html>');

    return buffer.toString();
  }

  String _valorCelda(dynamic valor) {
    if (valor == null) return '';
    if (valor is bool) return valor ? 'Sí' : 'No';
    return valor.toString();
  }

  String _htmlEscape(String valor) {
    return const HtmlEscape(HtmlEscapeMode.element).convert(valor);
  }

  ReporteFiltros _buildFiltros() => ReporteFiltros(
    tipo: _tipoSeleccionado,
    tipoVenta: _tipoVenta,
    fechaDesde: DateFormat(_dateFormat).format(_fechaDesde),
    fechaHasta: DateFormat(_dateFormat).format(_fechaHasta),
    sucursalId: _sucursalId,
    agrupacion: _agrupacion,
    categoriaId: _categoriaId,
    productoId: _productoId,
    limite: _limite,
    soloBajoStock: _soloBajoStock,
    estado: _estado,
    metodoPago: _metodoPago,
    proveedorPago: _proveedorPago,
    tipoEntrega: _tipoEntrega,
    rol: _rol,
    activo: _activo,
  );

  // ── Selección de fechas ──────────────────────────────────────────────

  Future<void> _seleccionarFecha({required bool esDesde}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: esDesde ? _fechaDesde : _fechaHasta,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      locale: const Locale('es'),
    );
    if (picked != null && mounted) {
      setState(() {
        if (esDesde) {
          _fechaDesde = picked;
          if (_fechaDesde.isAfter(_fechaHasta)) _fechaHasta = _fechaDesde;
        } else {
          _fechaHasta = picked;
          if (_fechaHasta.isBefore(_fechaDesde)) _fechaDesde = _fechaHasta;
        }
      });
    }
  }

  // ── Operaciones de Reportes Programados ───────────────────────────────

  Future<void> _abrirDialogoVoz() async {
    if (!_capacidad('reportes_interpretacion')) return;
    String origen = 'TEXTO';
    final textController = TextEditingController();
    bool interpretando = false;
    bool escuchando = false;
    String? errorVoz;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalContext, setModalState) {
            Future<void> interpretarActual() async {
              final texto = textController.text.trim();
              if (texto.isEmpty) {
                setModalState(
                  () => errorVoz = 'Por favor ingresa o dicta una consulta.',
                );
                return;
              }
              setModalState(() {
                interpretando = true;
                escuchando = false;
                errorVoz = null;
              });
              try {
                final res = await ReporteService.interpretar(
                  texto,
                  origen: origen,
                );
                if (!modalContext.mounted) return;
                Navigator.pop(ctx);
                if (mounted && vigente) {
                  _aplicarInterpretacion(res, texto);
                }
              } catch (e) {
                if (!modalContext.mounted) return;
                setModalState(() {
                  interpretando = false;
                  errorVoz = 'Error al interpretar consulta: $e';
                });
              }
            }

            return Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(modalContext).viewInsets.bottom + 20,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.mic,
                            color: AppColors.accent,
                            size: 26,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Generar Reporte por Voz / IA',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Text(
                                'Dicta por voz o escribe tu consulta en lenguaje natural',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () async {
                            await VozService.cancelar();
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: textController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Ej. "Ventas de esta semana" o "Inventario bajo stock"',
                        hintStyle: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                        filled: true,
                        fillColor: AppColors.background,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                        prefixIcon: Icon(
                          escuchando
                              ? Icons.graphic_eq
                              : Icons.record_voice_over_outlined,
                          color: escuchando
                              ? AppColors.danger
                              : AppColors.accent,
                        ),
                        suffixIcon: textController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () =>
                                    setModalState(() => textController.clear()),
                              )
                            : null,
                      ),
                      onChanged: (_) {
                        origen = 'TEXTO';
                        setModalState(() {});
                      },
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: escuchando
                            ? AppColors.danger
                            : AppColors.accent,
                        side: BorderSide(
                          color: escuchando
                              ? AppColors.danger
                              : AppColors.accent,
                        ),
                        minimumSize: const Size.fromHeight(44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: interpretando
                          ? null
                          : () async {
                              if (!_capacidad('reportes_voz')) {
                                setModalState(
                                  () => errorVoz = 'El dictado no está habilitado en tu plan.',
                                );
                                return;
                              }
                              if (escuchando) {
                                await VozService.detener();
                                setModalState(() => escuchando = false);
                                return;
                              }

                              setModalState(() {
                                escuchando = true;
                                errorVoz = null;
                              });
                              await VozService.escuchar(
                                onTexto: (texto, finalizado) {
                                  if (!vigente || !modalContext.mounted) return;
                                  origen = 'VOZ';
                                  if (!modalContext.mounted) return;
                                  setModalState(() {
                                    textController.text = texto;
                                    textController.selection =
                                        TextSelection.fromPosition(
                                          TextPosition(
                                            offset: textController.text.length,
                                          ),
                                        );
                                    escuchando = !finalizado;
                                  });
                                  if (finalizado &&
                                      texto.trim().isNotEmpty &&
                                      !interpretando) {
                                    Future.microtask(interpretarActual);
                                  }
                                },
                                onError: (mensaje) {
                                  if (!modalContext.mounted) return;
                                  setModalState(() {
                                    escuchando = false;
                                    errorVoz = mensaje;
                                  });
                                },
                              );
                            },
                      icon: Icon(
                        escuchando
                            ? Icons.stop_circle_outlined
                            : Icons.mic_none,
                      ),
                      label: Text(
                        escuchando ? 'Detener dictado' : 'Dictar consulta',
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Sugerencias rápidas por comando de voz:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children:
                          [
                            'Ventas de esta semana',
                            'Ventas del último mes',
                            'Inventario bajo stock',
                            'Productos más vendidos',
                            'Reservas de los últimos 15 días',
                            'Transferencias de este mes',
                          ].map((prompt) {
                            return ActionChip(
                              avatar: const Icon(
                                Icons.mic_none,
                                size: 14,
                                color: AppColors.primary,
                              ),
                              label: Text(
                                prompt,
                                style: const TextStyle(fontSize: 11),
                              ),
                              backgroundColor: Colors.grey[100],
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(color: Colors.grey[300]!),
                              ),
                              onPressed: () {
                                setModalState(() {
                                  textController.text = prompt;
                                });
                              },
                            );
                          }).toList(),
                    ),
                    if (errorVoz != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        errorVoz!,
                        style: const TextStyle(
                          color: AppColors.danger,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: interpretando ? null : interpretarActual,
                      icon: interpretando
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.auto_awesome),
                      label: Text(
                        interpretando
                            ? 'Interpretando con IA...'
                            : 'Interpretar y Generar Reporte',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    await VozService.cancelar();
    textController.dispose();
  }

  void _aplicarInterpretacion(
    ReporteInterpretacionResultado res,
    String textoOriginal,
  ) {
    final f = res.filtros;
    if (f.containsKey('tipo') && f['tipo'] != null) {
      final t = TipoReporte.desdeValor(f['tipo'].toString());
      if (t != null) _tipoSeleccionado = t;
    }
    if (f.containsKey('fecha_desde') && f['fecha_desde'] != null) {
      try {
        _fechaDesde = DateTime.parse(f['fecha_desde'].toString());
      } catch (_) {}
    }
    if (f.containsKey('fecha_hasta') && f['fecha_hasta'] != null) {
      try {
        _fechaHasta = DateTime.parse(f['fecha_hasta'].toString());
      } catch (_) {}
    }
    if (f.containsKey('sucursal_id')) {
      final sucursalValor = f['sucursal_id'];
      if (sucursalValor is int) {
        _sucursalId = sucursalValor;
      } else {
        _sucursalId = int.tryParse(sucursalValor?.toString() ?? '');
      }
    }
    _categoriaId = (f['categoria_id'] as num?)?.toInt();
    _productoId = (f['producto_id'] as num?)?.toInt();
    _limite = (f['limite'] as num?)?.toInt() ?? 10;
    if (f.containsKey('agrupacion') && f['agrupacion'] != null) {
      _agrupacion = f['agrupacion'].toString();
    }
    if (f.containsKey('solo_bajo_stock') && f['solo_bajo_stock'] != null) {
      _soloBajoStock = f['solo_bajo_stock'] == true;
    }
    _estado = null;
    _metodoPago = null;
    _proveedorPago = null;
    _tipoEntrega = null;
    _rol = null;
    _activo = null;

    final estado = _textoFiltro(f['estado']);
    if (estado != null && _opcionesEstado().containsKey(estado)) {
      _estado = estado;
    }

    final metodoPago = _textoFiltro(f['metodo_pago']);
    if (metodoPago == 'TARJETA') {
      _metodoPago = metodoPago;
    }

    final proveedorPago = _textoFiltro(f['proveedor_pago']);
    if (proveedorPago == 'STRIPE') {
      _proveedorPago = proveedorPago;
    }

    final tipoEntrega = _textoFiltro(f['tipo_entrega']);
    if (tipoEntrega == 'RECOJO_SUCURSAL' || tipoEntrega == 'DELIVERY') {
      _tipoEntrega = tipoEntrega;
    }

    final rol = _textoFiltro(f['rol']);
    if (rol == 'CLIENTE' ||
        rol == 'ADMINISTRADOR' ||
        rol == 'ENCARGADO_SUCURSAL') {
      _rol = rol;
    }

    if (f.containsKey('activo')) {
      final activoValor = f['activo'];
      if (activoValor is bool) {
        _activo = activoValor;
      } else if (activoValor != null) {
        final textoActivo = activoValor.toString().toLowerCase();
        if (textoActivo == 'true') _activo = true;
        if (textoActivo == 'false') _activo = false;
      }
    }

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Voz/IA: "$textoOriginal" interpretado.'),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 3),
      ),
    );

    _generarReporte(irAResultados: true);
  }

  String? _textoFiltro(dynamic valor) {
    final texto = valor?.toString().trim();
    if (texto == null || texto.isEmpty || texto.toLowerCase() == 'null') {
      return null;
    }
    return texto.toUpperCase();
  }

  bool _usaFiltroEstado() {
    return {
      TipoReporte.ventas,
      TipoReporte.reservas,
      TipoReporte.movimientos,
      TipoReporte.transferencias,
      TipoReporte.pagos,
      TipoReporte.deliveries,
    }.contains(_tipoSeleccionado);
  }

  bool _usaFiltroEntrega() {
    return {
      TipoReporte.ventas,
      TipoReporte.ventasPorSucursal,
      TipoReporte.ingresosPorCategoria,
      TipoReporte.productosMasVendidos,
      TipoReporte.pagos,
    }.contains(_tipoSeleccionado);
  }

  Map<String, String> _opcionesEstado() {
    switch (_tipoSeleccionado) {
      case TipoReporte.ventas:
        return const {
          'PENDIENTE_PAGO': 'Pendiente de pago',
          'COMPLETADA': 'Completada',
          'ANULADA': 'Anulada',
          'RECHAZADA': 'Rechazada',
          'CANCELADA': 'Cancelada',
        };
      case TipoReporte.reservas:
        return const {
          'PENDIENTE': 'Pendiente',
          'CONFIRMADA': 'Confirmada',
          'CANCELADA': 'Cancelada',
          'VENCIDA': 'Vencida',
          'RECOGIDA': 'Recogida',
        };
      case TipoReporte.movimientos:
        return const {
          'ENTRADA': 'Entrada',
          'SALIDA': 'Salida',
          'AJUSTE_POSITIVO': 'Ajuste positivo',
          'AJUSTE_NEGATIVO': 'Ajuste negativo',
          'TRANSFERENCIA_ENTRADA': 'Transferencia entrada',
          'TRANSFERENCIA_SALIDA': 'Transferencia salida',
          'VENTA_PRESENCIAL': 'Venta presencial',
          'VENTA_DIGITAL': 'Venta digital',
        };
      case TipoReporte.transferencias:
        return const {
          'PENDIENTE': 'Pendiente',
          'ENVIADA': 'Enviada',
          'RECIBIDA': 'Recibida',
          'CANCELADA': 'Cancelada',
        };
      case TipoReporte.pagos:
        return const {
          'PENDIENTE': 'Pendiente',
          'PAGADO': 'Pagado',
          'RECHAZADO': 'Rechazado',
          'EXPIRADO': 'Expirado',
          'CANCELADO': 'Cancelado',
        };
      case TipoReporte.deliveries:
        return const {
          'PENDIENTE': 'Pendiente',
          'EN_PREPARACION': 'En preparación',
          'EN_CAMINO': 'En camino',
          'ENTREGADO': 'Entregado',
          'CANCELADO': 'Cancelado',
        };
      default:
        return const {};
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    context.watch<PlanProvider>();
    if (!context.watch<AuthProvider>().esAdminOEncargado) {
      return const SizedBox.shrink();
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reportes & Dashboard',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              'Panel de análisis',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.accent,
          labelColor: AppColors.textPrimary,
          unselectedLabelColor: AppColors.textSecondary,
          isScrollable: true,
          tabs: [
            const Tab(icon: Icon(Icons.tune, size: 18), text: 'Filtros'),
            const Tab(
              icon: Icon(Icons.bar_chart, size: 18),
              text: 'Resultados',
            ),
            const Tab(icon: Icon(Icons.insights, size: 18), text: 'Dashboard'),
            if (_esAdmin)
              const Tab(
                icon: Icon(Icons.schedule, size: 18),
                text: 'Automáticos',
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.insights),
                  label: const Text('Analítica inteligente'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AnaliticaScreen(),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.mic),
                  label: const Text('Reporte por voz'),
                  onPressed: _abrirDialogoVoz,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Actualizar'),
                  onPressed: () => _generarReporte(irAResultados: false),
                ),
              ],
            ),
          ),
          Expanded(
            child: _cargandoCatalogo
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.accent),
                  )
                : _errorCatalogo != null
                ? _ErrorView(
                    mensaje: _errorCatalogo!,
                    onReintentar: _cargarCatalogo,
                  )
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildFiltrosTab(),
                      _buildResultadosTab(),
                      if (_catalogo != null)
                        DashboardComercialTab(
                          catalogo: _catalogo!,
                          encargado: !_esAdmin,
                        )
                      else
                        const SizedBox.shrink(),
                      if (_esAdmin && _catalogo != null)
                        ProgramadosReportesTab(catalogo: _catalogo!),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ── Tab de Filtros ────────────────────────────────────────────────────

  Widget _buildFiltrosTab() {
    final sucursales = _catalogo?.sucursales ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Banner de Generación por Voz / IA
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, Color(0xFF2C3E50)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.mic,
                    color: AppColors.accent,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Generar por Voz / IA',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Dicta o selecciona consultas en lenguaje natural.',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: _abrirDialogoVoz,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Hablar',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          DropdownButtonFormField<String>(
            initialValue: _tipoVenta,
            decoration: const InputDecoration(labelText: 'Canal de venta'),
            items: const [
              DropdownMenuItem<String>(value: null, child: Text('Todos')),
              DropdownMenuItem(value: 'PRESENCIAL', child: Text('Presencial')),
              DropdownMenuItem(value: 'DIGITAL', child: Text('Digital')),
            ],
            onChanged: (v) => setState(() => _tipoVenta = v),
          ),
          // Tipo de Reporte
          _SectionTitle(titulo: 'Tipo de Reporte'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: TipoReporte.values
                .where(
                  (t) => _catalogo?.tipos.any((v) => v.id == t.valor) == true,
                )
                .map((tipo) {
                  final seleccionado = _tipoSeleccionado == tipo;
                  return ChoiceChip(
                    label: Text(tipo.etiqueta),
                    selected: seleccionado,
                    onSelected: (_) => setState(() {
                      _tipoSeleccionado = tipo;
                      _categoriaId = null;
                      _productoId = null;
                      _estado = null;
                      _metodoPago = null;
                      _proveedorPago = null;
                      _tipoEntrega = null;
                      _rol = null;
                      _activo = null;
                      _resultado = null;
                    }),
                    selectedColor: AppColors.primary,
                    labelStyle: TextStyle(
                      color: seleccionado
                          ? Colors.white
                          : AppColors.textPrimary,
                      fontSize: 12,
                      fontWeight: seleccionado
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                    backgroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: seleccionado
                            ? AppColors.primary
                            : AppColors.border,
                      ),
                    ),
                  );
                })
                .toList(),
          ),
          const SizedBox(height: 24),

          // Rango de Fechas
          _SectionTitle(titulo: 'Rango de Fechas'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _DateSelector(
                  label: 'Desde',
                  fecha: _fechaDesde,
                  onTap: () => _seleccionarFecha(esDesde: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DateSelector(
                  label: 'Hasta',
                  fecha: _fechaHasta,
                  onTap: () => _seleccionarFecha(esDesde: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Sucursal
          if (sucursales.isNotEmpty) ...[
            _SectionTitle(titulo: 'Sucursal'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int?>(
                  value: _sucursalId,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text(
                        'Todas las sucursales',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    ...sucursales.map(
                      (s) => DropdownMenuItem<int?>(
                        value: s.id,
                        child: Text(
                          '${s.nombre} (${s.ciudad})',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (val) => setState(() {
                    _sucursalId = val;
                    _resultado = null;
                  }),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Agrupación
          _SectionTitle(titulo: 'Agrupación de datos'),
          const SizedBox(height: 10),
          Row(
            children: ['DIA', 'SEMANA', 'MES'].map((ag) {
              final sel = _agrupacion == ag;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _agrupacion = ag),
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: sel ? AppColors.primary : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: sel ? AppColors.primary : AppColors.border,
                      ),
                    ),
                    child: Text(
                      ag == 'DIA'
                          ? 'Día'
                          : ag == 'SEMANA'
                          ? 'Semana'
                          : 'Mes',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: sel ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          if ([
            TipoReporte.ventas,
            TipoReporte.ventasPorSucursal,
            TipoReporte.ingresosPorCategoria,
            TipoReporte.productosMasVendidos,
            TipoReporte.inventario,
          ].contains(_tipoSeleccionado)) ...[
            _SectionTitle(titulo: 'Categoría y producto'),
            const SizedBox(height: 10),
            _DropdownFiltro<int>(
              value: _categoriaId,
              hint: 'Todas las categorías',
              items: {
                for (final c
                    in _catalogo?.categorias ?? <ReporteCatalogoItem>[])
                  int.parse(c.id): c.nombre,
              },
              onChanged: (v) => setState(() {
                _categoriaId = v;
                _productoId = null;
              }),
            ),
            const SizedBox(height: 10),
            _DropdownFiltro<int>(
              value: _productoId,
              hint: 'Todos los productos',
              items: {
                for (final p in _catalogo?.productos ?? <ReporteCatalogoItem>[])
                  if (_categoriaId == null || p.categoriaId == _categoriaId)
                    int.parse(p.id): p.nombre,
              },
              onChanged: (v) => setState(() => _productoId = v),
            ),
            const SizedBox(height: 16),
          ],
          if (_tipoSeleccionado == TipoReporte.productosMasVendidos) ...[
            _SectionTitle(titulo: 'Productos del ranking'),
            const SizedBox(height: 10),
            _DropdownFiltro<int>(
              value: _limite,
              hint: 'Cantidad',
              items: {
                for (final n in {_limite, 5, 10, 20, 50, 100})
                  n: '$n productos',
              },
              onChanged: (v) => setState(() => _limite = v ?? 10),
            ),
            const SizedBox(height: 16),
          ],
          if (_usaFiltroEstado()) ...[
            _SectionTitle(titulo: 'Estado / tipo'),
            const SizedBox(height: 10),
            _DropdownFiltro<String>(
              value: _estado,
              hint: 'Todos',
              items: _opcionesEstado(),
              onChanged: (v) => setState(() {
                _estado = v;
                _resultado = null;
              }),
            ),
            const SizedBox(height: 16),
          ],

          if (_usaFiltroEntrega()) ...[
            _SectionTitle(titulo: 'Tipo de entrega'),
            const SizedBox(height: 10),
            _DropdownFiltro<String>(
              value: _tipoEntrega,
              hint: 'Todas',
              items: const {
                'RECOJO_SUCURSAL': 'Recojo en sucursal',
                'DELIVERY': 'Delivery',
              },
              onChanged: (v) => setState(() {
                _tipoEntrega = v;
                _resultado = null;
              }),
            ),
            const SizedBox(height: 16),
          ],

          if (_tipoSeleccionado == TipoReporte.pagos) ...[
            _SectionTitle(titulo: 'Pago'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _DropdownFiltro<String>(
                    value: _metodoPago,
                    hint: 'Método',
                    items: const {'TARJETA': 'Tarjeta'},
                    onChanged: (v) => setState(() {
                      _metodoPago = v;
                      _resultado = null;
                    }),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DropdownFiltro<String>(
                    value: _proveedorPago,
                    hint: 'Proveedor',
                    items: const {'STRIPE': 'Stripe'},
                    onChanged: (v) => setState(() {
                      _proveedorPago = v;
                      _resultado = null;
                    }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          if (_tipoSeleccionado == TipoReporte.usuarios) ...[
            _SectionTitle(titulo: 'Usuarios'),
            const SizedBox(height: 10),
            _DropdownFiltro<String>(
              value: _rol,
              hint: 'Todos los roles',
              items: const {
                'CLIENTE': 'Cliente',
                'ADMINISTRADOR': 'Administrador',
                'ENCARGADO_SUCURSAL': 'Encargado de sucursal',
              },
              onChanged: (v) => setState(() {
                _rol = v;
                _resultado = null;
              }),
            ),
            const SizedBox(height: 10),
            _DropdownFiltro<bool>(
              value: _activo,
              hint: 'Todos los estados',
              items: const {true: 'Activos', false: 'Inactivos'},
              onChanged: (v) => setState(() {
                _activo = v;
                _resultado = null;
              }),
            ),
            const SizedBox(height: 16),
          ],

          // Solo bajo stock
          if (_tipoSeleccionado == TipoReporte.inventario)
            SwitchListTile.adaptive(
              value: _soloBajoStock,
              onChanged: (v) => setState(() => _soloBajoStock = v),
              title: const Text(
                'Solo productos con bajo stock',
                style: TextStyle(fontSize: 13),
              ),
              activeThumbColor: AppColors.accent,
              contentPadding: EdgeInsets.zero,
            ),

          const SizedBox(height: 30),

          // Botón generar
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
            onPressed: _generando ? null : _generarReporte,
            icon: _generando
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.analytics_outlined),
            label: Text(
              _generando ? 'Generando...' : 'Generar Reporte',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),

          if (_errorReporte != null) ...[
            const SizedBox(height: 12),
            _ErrorInline(mensaje: _errorReporte!),
          ],
        ],
      ),
    );
  }

  // ── Tab de Resultados ─────────────────────────────────────────────────

  Widget _buildResultadosTab() {
    if (_errorReporte != null && _resultado == null) {
      return _ErrorView(
        mensaje: _errorReporte!,
        onReintentar: () => _generarReporte(),
      );
    }
    if (_generando) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppColors.accent),
            SizedBox(height: 16),
            Text(
              'Generando reporte...',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (_resultado == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.analytics_outlined,
                size: 72,
                color: AppColors.primary.withValues(alpha: 0.3),
              ),
              const SizedBox(height: 16),
              const Text(
                'Sin reporte cargado',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Genera el reporte para analizar ventas, inventario, reservas o transferencias.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () => _generarReporte(irAResultados: true),
                icon: const Icon(Icons.analytics_outlined),
                label: const Text('Generar reporte ahora'),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () => _tabController.animateTo(0),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Personalizar filtros'),
              ),
            ],
          ),
        ),
      );
    }

    final r = _resultado!;

    if (r.sinDatos) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inbox_outlined, size: 72, color: Colors.grey[300]),
              const SizedBox(height: 16),
              const Text(
                'Sin datos para los filtros seleccionados',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              if (r.nota != null)
                Text(
                  r.nota!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () => _tabController.animateTo(0),
                icon: const Icon(Icons.tune),
                label: const Text('Modificar filtros'),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Barra de acceso rápido a filtros
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.tune, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${r.titulo} · ${_filtrosResultado!.fechaDesde} al ${_filtrosResultado!.fechaHasta}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _tabController.animateTo(0),
                  child: const Text('Cambiar', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Encabezado del reporte
          if (_errorReporte != null) ErrorSaas(_errorReporte!),
          _ReporteHeader(resultado: r),
          const SizedBox(height: 16),

          AnalisisReportePanel(
            key: ValueKey(_revisionAnalisis),
            filtros: _filtrosResultado!,
            firmaResultado: r.firmaResultado,
            habilitado: _capacidad('reportes_interpretacion'),
            vozHabilitada: _capacidad('reportes_voz'),
            onResultado: (a) {
              if (vigente) setState(() => _analisis = a);
            },
          ),
          const SizedBox(height: 16),
          // Indicadores
          if (r.indicadores.isNotEmpty) ...[
            _GridIndicadores(indicadores: r.indicadores),
            const SizedBox(height: 16),
          ],

          // Gráfico de barras
          if (r.serieGrafico.isNotEmpty) ...[
            if (_analisis case final a?)
              GraficoReporteIA(
                serie: r.serieGrafico,
                tipo: a.grafico,
                titulo: r.titulo,
              )
            else
              _GraficoBarras(serie: r.serieGrafico, titulo: r.titulo),
            const SizedBox(height: 16),
          ],

          // Tabla de datos
          if (r.filas.isNotEmpty) ...[
            _TablaReporte(
              key: ValueKey(r.pagina),
              columnas: r.columnas,
              filas: r.filas,
            ),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: r.pagina > 1 && !_generando
                      ? () => _generarReporte(
                          pagina: r.pagina - 1,
                          reutilizar: true,
                        )
                      : null,
                  child: const Text('Página anterior'),
                ),
                Text(
                  'Página ${r.pagina} de ${(r.totalFilas / r.tamano).ceil()} · ${r.totalFilas} registros',
                ),
                OutlinedButton(
                  onPressed: r.pagina * r.tamano < r.totalFilas && !_generando
                      ? () => _generarReporte(
                          pagina: r.pagina + 1,
                          reutilizar: true,
                        )
                      : null,
                  child: const Text('Página siguiente'),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],

          // Botones de exportación
          if (r.resumen.isNotEmpty) ...[
            Text(
              'Totales del resultado completo: ${r.totalFilas} registros · ${r.resumen['unidades'] ?? 0} unidades',
            ),
            ...((r.resumen['importes_por_moneda'] as List?) ?? []).map((v) {
              final m = v as Map;
              return Text('Importe ${m['moneda']}: ${m['importe']}');
            }),
          ],
          if (r.totalFilas > 5000)
            const Text(
              'El resultado supera 5.000 filas. Puedes recorrer las páginas; reduce el período para exportar sin truncar.',
            ),
          _ExportButtons(
            exportando: _exportando,
            onPdf: _capacidad('reportes_pdf') && r.totalFilas <= 5000
                ? () => _exportar('pdf')
                : null,
            onExcel: _capacidad('reportes_excel') && r.totalFilas <= 5000
                ? () => _exportar('excel')
                : null,
            onHtml: r.totalFilas <= 5000 ? () => _exportar('html') : null,
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // ── Tab de Reportes Automáticos / Programados ──────────────────────────
}

// ─── Widgets auxiliares ───────────────────────────────────────────────────────

class _DropdownFiltro<T> extends StatelessWidget {
  final T? value;
  final String hint;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;

  const _DropdownFiltro({
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T?>(
          value: value,
          isExpanded: true,
          hint: Text(
            hint,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          items: [
            DropdownMenuItem<T?>(
              value: null,
              child: Text(
                hint,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            ...items.entries.map(
              (entry) => DropdownMenuItem<T?>(
                value: entry.key,
                child: Text(entry.value, style: const TextStyle(fontSize: 13)),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String titulo;
  const _SectionTitle({required this.titulo});

  @override
  Widget build(BuildContext context) => Text(
    titulo,
    style: const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: AppColors.textSecondary,
      letterSpacing: 0.5,
    ),
  );
}

class _DateSelector extends StatelessWidget {
  final String label;
  final DateTime fecha;
  final VoidCallback onTap;
  const _DateSelector({
    required this.label,
    required this.fecha,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(
                  Icons.calendar_today_outlined,
                  size: 14,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  DateFormat('d MMM yyyy', 'es').format(fecha),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String mensaje;
  final VoidCallback onReintentar;
  const _ErrorView({required this.mensaje, required this.onReintentar});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, color: AppColors.danger, size: 48),
        const SizedBox(height: 12),
        Text(
          mensaje,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: onReintentar,
          child: const Text('Reintentar'),
        ),
      ],
    ),
  );
}

class _ErrorInline extends StatelessWidget {
  final String mensaje;
  const _ErrorInline({required this.mensaje});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.dangerSoft,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: AppColors.danger, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            mensaje,
            style: const TextStyle(color: AppColors.danger, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

// ─── Encabezado del reporte ───────────────────────────────────────────────────

class _ReporteHeader extends StatelessWidget {
  final ReporteResultado resultado;
  const _ReporteHeader({required this.resultado});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            resultado.titulo,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          if (resultado.nota != null) ...[
            const SizedBox(height: 4),
            Text(
              resultado.nota!,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(
                Icons.access_time_outlined,
                size: 12,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                'Generado: ${resultado.generadoEn.split('T').first}',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${resultado.totalFilas} registros',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Grid de indicadores KPI ──────────────────────────────────────────────────

class _GridIndicadores extends StatelessWidget {
  final List<ReporteIndicador> indicadores;
  const _GridIndicadores({required this.indicadores});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: indicadores.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.0,
      ),
      itemBuilder: (_, i) {
        final ind = indicadores[i];
        final isMoneda =
            ind.label.toLowerCase().contains('total') ||
            ind.label.toLowerCase().contains('ingreso') ||
            ind.label.toLowerCase().contains('promedio') ||
            ind.label.toLowerCase().contains('monto');
        final valorFmt = isMoneda
            ? NumberFormat.currency(
                locale: 'es_BO',
                symbol: 'Bs. ',
              ).format(ind.valor)
            : NumberFormat.decimalPattern('es').format(ind.valor);

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                ind.label,
                style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                valorFmt,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Gráfico de barras custom ─────────────────────────────────────────────────

class _GraficoBarras extends StatelessWidget {
  final List<ReporteSerieItem> serie;
  final String titulo;
  const _GraficoBarras({required this.serie, required this.titulo});

  @override
  Widget build(BuildContext context) {
    if (serie.isEmpty) return const SizedBox.shrink();

    final maxVal = serie
        .map((e) => e.valor.toDouble())
        .reduce((a, b) => a > b ? a : b);
    final isMoneda =
        titulo.toLowerCase().contains('venta') ||
        titulo.toLowerCase().contains('ingreso');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.bar_chart_outlined,
                size: 16,
                color: AppColors.accent,
              ),
              const SizedBox(width: 6),
              Text(
                'Evolución temporal',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 180,
            child: _BarChartCustom(
              serie: serie,
              maxVal: maxVal,
              isMoneda: isMoneda,
            ),
          ),
        ],
      ),
    );
  }
}

class _BarChartCustom extends StatelessWidget {
  final List<ReporteSerieItem> serie;
  final double maxVal;
  final bool isMoneda;
  const _BarChartCustom({
    required this.serie,
    required this.maxVal,
    required this.isMoneda,
  });

  @override
  Widget build(BuildContext context) {
    // Muestra máx 12 items (condensar si hay más)
    final items = serie.length > 12
        ? [for (int i = 0; i < serie.length; i += serie.length ~/ 12) serie[i]]
        : serie;

    return LayoutBuilder(
      builder: (context, constraints) {
        const valueHeight = 18.0;
        const labelHeight = 18.0;
        const verticalGap = 6.0;
        final barMaxHeight =
            (constraints.maxHeight - valueHeight - labelHeight - verticalGap)
                .clamp(24.0, constraints.maxHeight);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: items.asMap().entries.map((entry) {
            final item = entry.value;
            final ratio = maxVal > 0 ? (item.valor.toDouble() / maxVal) : 0.0;
            final isMax =
                item.valor ==
                items.map((e) => e.valor).reduce((a, b) => a > b ? a : b);

            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    SizedBox(
                      height: valueHeight,
                      child: Center(
                        child: isMax
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  isMoneda
                                      ? 'Bs.${item.valor.toStringAsFixed(0)}'
                                      : item.valor.toStringAsFixed(0),
                                  style: const TextStyle(
                                    fontSize: 7,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(height: 2),
                    AnimatedContainer(
                      duration: Duration(milliseconds: 400 + entry.key * 50),
                      curve: Curves.easeOutCubic,
                      height: (barMaxHeight * ratio).clamp(4.0, barMaxHeight),
                      decoration: BoxDecoration(
                        color: isMax ? AppColors.accent : AppColors.primary,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: labelHeight,
                      child: Text(
                        _shortLabel(item.label),
                        style: const TextStyle(
                          fontSize: 7,
                          color: AppColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  String _shortLabel(String label) {
    if (label.length > 5) return label.substring(0, 5);
    return label;
  }
}

// ─── Tabla de datos del reporte ───────────────────────────────────────────────

class _TablaReporte extends StatefulWidget {
  final List<ReporteColumna> columnas;
  final List<Map<String, dynamic>> filas;
  const _TablaReporte({super.key, required this.columnas, required this.filas});

  @override
  State<_TablaReporte> createState() => _TablaReporteState();
}

class _TablaReporteState extends State<_TablaReporte> {
  int _pagina = 0;

  @override
  Widget build(BuildContext context) {
    const totalPaginas = 1;
    const inicio = 0;
    final fin = widget.filas.length;
    final filasActuales = widget.filas.sublist(inicio, fin);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Encabezado de tabla
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(
                  Icons.table_chart_outlined,
                  size: 16,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 6),
                const Text(
                  'Tabla de datos',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${widget.filas.length} filas',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Tabla con scroll horizontal
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 36,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 48,
              columnSpacing: 16,
              headingTextStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
              dataTextStyle: const TextStyle(
                fontSize: 11,
                color: AppColors.textPrimary,
              ),
              headingRowColor: WidgetStateProperty.all(AppColors.background),
              columns: widget.columnas
                  .map((c) => DataColumn(label: Text(c.label)))
                  .toList(),
              rows: filasActuales.map((fila) {
                return DataRow(
                  cells: widget.columnas.map((c) {
                    final val = fila[c.key];
                    String txt = val?.toString() ?? '-';
                    return DataCell(Text(txt));
                  }).toList(),
                );
              }).toList(),
            ),
          ),
          // Paginación
          if (totalPaginas > 1)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: _pagina > 0
                        ? () => setState(() => _pagina--)
                        : null,
                    color: AppColors.primary,
                  ),
                  Text(
                    'Pág ${_pagina + 1} de $totalPaginas',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: _pagina < totalPaginas - 1
                        ? () => setState(() => _pagina++)
                        : null,
                    color: AppColors.primary,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Botones de exportación ───────────────────────────────────────────────────

class _ExportButtons extends StatelessWidget {
  final bool exportando;
  final VoidCallback? onPdf;
  final VoidCallback? onExcel;
  final VoidCallback? onHtml;
  const _ExportButtons({
    required this.exportando,
    required this.onPdf,
    required this.onExcel,
    required this.onHtml,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Divider(),
        const SizedBox(height: 8),
        if (exportando)
          const Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accent,
                ),
                SizedBox(width: 12),
                Text(
                  'Descargando...',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ],
            ),
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              _ExportButton(
                label: 'PDF',
                icon: Icons.picture_as_pdf_outlined,
                color: AppColors.danger,
                onPressed: onPdf,
              ),
              _ExportButton(
                label: 'Excel',
                icon: Icons.table_chart_outlined,
                color: AppColors.success,
                onPressed: onExcel,
              ),
              _ExportButton(
                label: 'HTML',
                icon: Icons.html_outlined,
                color: AppColors.accent,
                onPressed: onHtml,
              ),
            ],
          ),
      ],
    );
  }
}

class _ExportButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  const _ExportButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: color),
          foregroundColor: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}
