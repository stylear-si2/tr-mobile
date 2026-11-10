package com.example.mobile_tr

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.provider.Settings

class MainActivity : FlutterFragmentActivity() {
    private var fotoPendiente: ByteArray? = null
    private var resultadoFoto: MethodChannel.Result? = null
    private val solicitudFoto = 2419
    private val canal = "stylear_transacciones_v1"
    private var puente: MethodChannel? = null
    private var pendiente: Map<String, Long>? = null
    private fun referencia(intent: Intent?): Map<String, Long>? {
        val nid = intent?.getLongExtra("stylear_notificacion_id", 0) ?: 0
        val eid = intent?.getLongExtra("stylear_empresa_id", 0) ?: 0
        return if (nid > 0 && eid > 0) mapOf("notificacion_id" to nid, "empresa_id" to eid) else null
    }
    private fun crearCanal() {
        if (Build.VERSION.SDK_INT >= 26) {
            val gestor = getSystemService(NotificationManager::class.java)
            if (gestor.getNotificationChannel(canal) == null) {
                gestor.createNotificationChannel(NotificationChannel(canal, "Actualizaciones de StyleAR", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Compras, reservas, entregas y atención de tu cuenta"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                })
            }
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "stylear/vestidor-fotos").setMethodCallHandler { call, result ->
            if (call.method != "guardar") { result.notImplemented(); return@setMethodCallHandler }
            val bytes = call.argument<ByteArray>("bytes")
            if (bytes == null || bytes.isEmpty() || bytes.size > 10 * 1024 * 1024) {
                result.error("IMAGEN", "La imagen no es válida", null); return@setMethodCallHandler
            }
            if (resultadoFoto != null) { result.error("OCUPADO", "Ya hay un guardado en curso", null); return@setMethodCallHandler }
            fotoPendiente = bytes
            resultadoFoto = result
            try {
                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "image/jpeg"
                    putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                    putExtra(Intent.EXTRA_TITLE, "StyleAR-vestidor-${System.currentTimeMillis()}.jpg")
                }, solicitudFoto)
            } catch (_: Exception) {
                fotoPendiente = null; resultadoFoto = null
                result.error("GUARDAR", "No se pudo abrir el selector de archivos", null)
            }
        }
        crearCanal()
        pendiente = referencia(intent)
        puente = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "stylear/notificaciones")
        puente!!.setMethodCallHandler { call, result ->
            val gestor = getSystemService(NotificationManager::class.java)
            when (call.method) {
                "inicializar" -> { crearCanal(); result.success(null) }
                "inicio" -> { result.success(pendiente); pendiente = null }
                "cancelar" -> { gestor.cancelAll(); result.success(null) }
                "estado" -> result.success(mapOf("permitidas" to (Build.VERSION.SDK_INT < 24 || gestor.areNotificationsEnabled()), "importancia" to (if (Build.VERSION.SDK_INT >= 26) gestor.getNotificationChannel(canal)?.importance else 4)))
                "ajustes" -> {
                    startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                    result.success(null)
                }
                "mostrar" -> {
                    val nid = call.argument<Number>("notificacion_id")?.toLong() ?: 0
                    val eid = call.argument<Number>("empresa_id")?.toLong() ?: 0
                    if (nid <= 0 || eid <= 0) { result.error("REFERENCIA", "Referencia inválida", null); return@setMethodCallHandler }
                    val tag = "stylear_${eid}_${nid}"
                    val abrir = Intent(this, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        .putExtra("stylear_notificacion_id", nid).putExtra("stylear_empresa_id", eid)
                    val accion = PendingIntent.getActivity(this, tag.hashCode(), abrir, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, canal) else Notification.Builder(this)
                    val titulo = call.argument<String>("titulo")?.take(120)?.takeIf { it.isNotBlank() } ?: "StyleAR"
                    val mensaje = call.argument<String>("mensaje")?.take(800) ?: "Abre tu bandeja para consultar el aviso."
                    val aviso = builder.setSmallIcon(R.drawable.ic_stylear_notification).setContentTitle(titulo)
                        .setContentText(mensaje).setStyle(Notification.BigTextStyle().bigText(mensaje))
                        .setContentIntent(accion).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE)
                        .setPriority(Notification.PRIORITY_HIGH).setCategory(Notification.CATEGORY_STATUS).build()
                    try { gestor.notify(tag, 0, aviso); result.success(null) }
                    catch (_: SecurityException) { result.error("PERMISO", "Permiso de avisos no disponible", null) }
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != solicitudFoto) return
        val result = resultadoFoto
        val bytes = fotoPendiente
        fotoPendiente = null; resultadoFoto = null
        if (result == null) return
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || bytes == null) { result.success(false); return }
        try {
            contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
                ?: throw java.io.IOException("Archivo no disponible")
            result.success(true)
        } catch (_: Exception) {
            result.error("GUARDAR", "No se pudo guardar la foto en el destino elegido", null)
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendiente = referencia(intent)
        pendiente?.let { puente?.invokeMethod("abrir", it) }
    }
}
