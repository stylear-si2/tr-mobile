class AnalisisReporte {
  final String id, narrativa, grafico, motivo, motor;
  final List<String> conclusiones, advertencias;
  final bool audioDisponible;
  const AnalisisReporte({
    required this.id,
    required this.narrativa,
    required this.grafico,
    required this.motivo,
    required this.motor,
    this.conclusiones = const [],
    this.advertencias = const [],
    this.audioDisponible = false,
  });
  factory AnalisisReporte.fromJson(Map<String, dynamic> json) =>
      AnalisisReporte(
        id: json['id'] as String,
        narrativa: json['narrativa'] as String,
        grafico: json['grafico'] as String,
        motivo: json['motivo_grafico'] as String,
        motor: json['motor'] as String,
        conclusiones: (json['conclusiones'] as List? ?? []).cast<String>(),
        advertencias: (json['advertencias'] as List? ?? []).cast<String>(),
        audioDisponible: json['audio_disponible'] == true,
      );
}
