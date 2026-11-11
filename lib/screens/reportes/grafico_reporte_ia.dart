import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/reporte_models.dart';

const _colores = [
  Color(0xff465934),
  Color(0xff315b7a),
  Color(0xff975032),
  Color(0xff6e4d81),
  Color(0xff946900),
  Color(0xff236b67),
  Color(0xffad4874),
  Color(0xff626b82),
];

class GraficoReporteIA extends StatelessWidget {
  final List<ReporteSerieItem> serie;
  final String tipo, titulo;
  const GraficoReporteIA({
    super.key,
    required this.serie,
    required this.tipo,
    required this.titulo,
  });
  @override
  Widget build(BuildContext context) {
    final datos = serie.take(40).toList();
    if (datos.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Semantics(
              label:
                  'Gráfico ${tipo.toLowerCase()}. Los valores se detallan debajo.',
              image: true,
              child: SizedBox(
                height: 240,
                child: CustomPaint(painter: _GraficoPainter(datos, tipo)),
              ),
            ),
            const SizedBox(height: 12),
            for (final (i, dato) in datos.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.only(top: 4, right: 8),
                      color: _color(datos, tipo, i),
                    ),
                    Expanded(
                      child: Text(
                        '${i + 1}. ${dato.label}: ${dato.valor.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (serie.length > 40)
              const Text(
                'El gráfico muestra los primeros 40 elementos. La tabla conserva el resultado completo.',
              ),
          ],
        ),
      ),
    );
  }
}

Color _color(List<ReporteSerieItem> datos, String tipo, int i) {
  if (tipo == 'BARRAS_AGRUPADAS') {
    final nombres = datos
        .map((d) => d.label.length > 13 ? d.label.substring(13) : d.label)
        .toSet()
        .toList();
    final nombre = datos[i].label.length > 13
        ? datos[i].label.substring(13)
        : datos[i].label;
    return _colores[nombres.indexOf(nombre) % _colores.length];
  }
  return tipo == 'LINEAS' || tipo == 'BARRAS'
      ? _colores[0]
      : _colores[i % _colores.length];
}

class _GraficoPainter extends CustomPainter {
  final List<ReporteSerieItem> datos;
  final String tipo;
  _GraficoPainter(this.datos, this.tipo);
  void texto(Canvas c, String t, Offset pos) {
    final p = TextPainter(
      text: TextSpan(
        text: t,
        style: const TextStyle(color: Color(0xff465047), fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(c, pos);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final circular = tipo == 'PASTEL' || tipo == 'DONA';
    final valores = datos.map((d) => d.valor.toDouble()).toList();
    if (circular) {
      final suma = valores.fold(0.0, (a, b) => a + b);
      if (suma <= 0 || valores.any((v) => v < 0)) return;
      final radio = math.min(size.width, size.height) * .43;
      final rect = Rect.fromCircle(
        center: Offset(size.width / 2, size.height / 2),
        radius: radio,
      );
      var angulo = -math.pi / 2;
      for (var i = 0; i < valores.length; i++) {
        final arco = valores[i] / suma * 2 * math.pi;
        canvas.drawArc(
          rect,
          angulo,
          arco,
          true,
          Paint()..color = _color(datos, tipo, i),
        );
        angulo += arco;
      }
      if (tipo == 'DONA') {
        canvas.drawCircle(
          rect.center,
          radio * .58,
          Paint()..color = Colors.white,
        );
      }
      return;
    }
    final area = Rect.fromLTWH(
      42,
      10,
      math.max(1, size.width - 48),
      size.height - 36,
    );
    final minimo = math.min(0.0, valores.reduce(math.min));
    final maximo = math.max(0.0, valores.reduce(math.max));
    final rango = maximo == minimo ? 1.0 : maximo - minimo;
    double y(double valor) =>
        area.bottom - (valor - minimo) / rango * area.height;
    final rejilla = Paint()
      ..color = const Color(0xffdce3d4)
      ..strokeWidth = 1;
    for (var j = 0; j <= 4; j++) {
      final valor = minimo + rango * j / 4;
      final altura = y(valor);
      canvas.drawLine(
        Offset(area.left, altura),
        Offset(area.right, altura),
        rejilla,
      );
      texto(
        canvas,
        valor.abs() >= 1000
            ? '${(valor / 1000).toStringAsFixed(1)}k'
            : valor.toStringAsFixed(0),
        Offset(0, altura - 6),
      );
    }
    final grupos = tipo == 'BARRAS_AGRUPADAS'
        ? datos
              .map((d) => d.label.length > 13 ? d.label.substring(13) : d.label)
              .toSet()
              .length
        : datos.length;
    final separaciones = tipo == 'BARRAS_AGRUPADAS'
        ? (datos.length / grupos).ceil() - 1
        : 0;
    final paso = area.width / (datos.length + separaciones * .6);
    final puntos = <Offset>[];
    for (var i = 0; i < valores.length; i++) {
      final extra = tipo == 'BARRAS_AGRUPADAS' ? (i ~/ grupos) * .6 : 0;
      final x = area.left + paso * (i + .5 + extra);
      final altura = y(valores[i]);
      if (tipo == 'LINEAS') {
        puntos.add(Offset(x, altura));
      } else {
        canvas.drawRect(
          Rect.fromLTRB(
            x - paso * .32,
            math.min(y(0), altura),
            x + paso * .32,
            math.max(y(0), altura),
          ),
          Paint()..color = _color(datos, tipo, i),
        );
      }
      if (datos.length <= 12 ||
          i % math.max(1, (datos.length / 8).ceil()) == 0) {
        texto(canvas, '${i + 1}', Offset(x - 3, area.bottom + 8));
      }
    }
    if (puntos.isNotEmpty) {
      final linea = Path()..moveTo(puntos.first.dx, puntos.first.dy);
      for (final p in puntos.skip(1)) {
        linea.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        linea,
        Paint()
          ..color = _colores[0]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      for (final p in puntos) {
        canvas.drawCircle(p, 3, Paint()..color = _colores[0]);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GraficoPainter old) =>
      old.datos != datos || old.tipo != tipo;
}
