package uwu.vyto4ka.vysh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "uwu.vyto4ka.vysh/wakelock"
    private val iconChannelName = "uwu.vyto4ka.vysh/app_icon"
    private val filesChannelName = "uwu.vyto4ka.vysh/local_files"

    /// Сохранения в Download, ждущие ответа на запрос разрешения (Android 9-).
    private val pendingSaves = mutableListOf<Pair<MethodCall, MethodChannel.Result>>()
    private val storagePermissionRequest = 4041
    private val notificationsPermissionRequest = 4042

    /// Ожидание выбора места сохранения в системном диалоге (SAF).
    private var pendingSaveDocument: MethodChannel.Result? = null
    /// Байты для записи в файл, выбранный в диалоге saveDocument.
    /// Держим в Activity: данные уже собраны, до записи - только выбор места.
    private var dataBytes: ByteArray? = null
    private val saveDocumentRequest = 4043
    private var notificationsAsked = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Канал прежнего названия: wake lock теперь держит сам сервис,
        // Dart только сообщает, есть ли живые сессии.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    requestNotificationsOnce()
                    val title = call.argument<String>("title") ?: getString(R.string.ssh_connected)
                    result.success(SshForegroundService.start(this, title))
                }
                "release" -> {
                    SshForegroundService.stop(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, filesChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    if (needsStoragePermission()) {
                        // Android 9 и ниже: без разрешения в общую Download не записать.
                        pendingSaves.add(call to result)
                        if (pendingSaves.size == 1) {
                            requestPermissions(
                                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                storagePermissionRequest
                            )
                        }
                    } else {
                        handleSave(call, result)
                    }
                }
                "saveDocument" -> {
                    // Системный диалог «Сохранить как» (SAF): пользователь
                    // сам выбирает место и имя файла. Второй вызов до ответа
                    // на первый не имеет смысла - отменяем прежний.
                    pendingSaveDocument?.error("CANCELLED", "Superseded", null)
                    pendingSaveDocument = result
                    dataBytes = call.argument<ByteArray>("bytes")
                    try {
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = call.argument<String>("mimeType")
                                ?: "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, call.argument<String>("suggestedName") ?: "")
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, saveDocumentRequest)
                    } catch (e: Exception) {
                        pendingSaveDocument = null
                        dataBytes = null
                        result.error("SAVE_ERROR", e.message, null)
                    }
                }
                "shareText" -> {
                    try {
                        // Системное меню «Поделиться» для выделенного текста.
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        }
                        startActivity(Intent.createChooser(send, null))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_ERROR", e.message, null)
                    }
                }
                "openUrl" -> {
                    try {
                        // Браузер/системное приложение для ссылки (страница
                        // релиза при обновлении). Процессов на Android нет,
                        // openWithSystem до этого URL не открывал.
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: ""))
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_URL_ERROR", e.message, null)
                    }
                }
                "installApk" -> {
                    try {
                        // Системный диалог пакетного установщика:
                        // «Обновить это приложение?». APK кладём в приватный
                        // cache/updates и отдаём через FileProvider - прямые
                        // file:// URI с targetSdk 24+ запрещены.
                        val source = java.io.File(call.argument<String>("path") ?: "")
                        if (!source.exists()) {
                            result.error("INSTALL_ERROR", "APK not found: $source", null)
                            return@setMethodCallHandler
                        }
                        val dir = java.io.File(cacheDir, "updates").apply { mkdirs() }
                        // Своя копия: исходный файл живёт во временной папке,
                        // которую установщик мог бы не дочитать.
                        val apk = java.io.File(dir, "vysh_update.apk")
                        if (apk.exists()) apk.delete()
                        source.copyTo(apk, overwrite = true)

                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", apk)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                "revealPath" -> {
                    try {
                        // Открываем системный экран «Загрузки» - там лежат файлы
                        // из общей Download, и любой менеджер их видит. Папку по
                        // пути (file://) открыть нельзя: с targetSdk 24+ такой
                        // Intent падает с FileUriExposedException (Android 8-9).
                        val intent = Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("REVEAL_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, iconChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getMonetColors" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val accent = getColor(android.R.color.system_accent1_200)
                            val accentPrimary = getColor(android.R.color.system_accent1_500)
                            val neutralDark = getColor(android.R.color.system_neutral1_900)
                            result.success(mapOf(
                                "accent" to (accent.toLong() and 0xFFFFFFFFL),
                                "accentPrimary" to (accentPrimary.toLong() and 0xFFFFFFFFL),
                                "background" to (neutralDark.toLong() and 0xFFFFFFFFL)
                            ))
                        } else {
                            result.success(null)
                        }
                    } catch (_: Exception) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        // SSH-сессии живут в Dart-движке этой Activity и погибают вместе с ней:
        // держать процесс дальше незачем.
        SshForegroundService.stop(this)
        pendingSaveDocument?.error("CANCELLED", "Activity destroyed", null)
        pendingSaveDocument = null
        val waiting = pendingSaves.toList()
        pendingSaves.clear()
        for ((_, result) in waiting) {
            result.error("SAVE_ERROR", "Activity destroyed", null)
        }
        super.onDestroy()
    }

    /// Android 13+: без разрешения уведомление сервиса не видно в шторке,
    /// и пользователь не знает, что соединение держится в фоне. Спрашиваем
    /// при первом подключении, один раз за запуск.
    private fun requestNotificationsOnce() {
        if (notificationsAsked || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        notificationsAsked = true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationsPermissionRequest
            )
        }
    }

    // ─── Скачивание в общую Download ────────────────────────────────

    private fun needsStoragePermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != storagePermissionRequest) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        val waiting = pendingSaves.toList()
        pendingSaves.clear()
        for ((call, result) in waiting) {
            if (granted) {
                handleSave(call, result)
            } else {
                result.error(
                    "PERMISSION_DENIED",
                    "WRITE_EXTERNAL_STORAGE denied",
                    null
                )
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveDocumentRequest) return
        val result = pendingSaveDocument ?: return
        pendingSaveDocument = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            // Пользователь закрыл диалог - не ошибка, просто отмена.
            result.success(null)
            return
        }
        // Запись в content:// - тяжёлая операция, не в главном потоке.
        val bytes = dataBytes
        dataBytes = null
        Thread {
            try {
                contentResolver.openOutputStream(uri, "wt")?.use { out ->
                    out.write(bytes ?: ByteArray(0))
                    out.flush()
                } ?: throw IllegalStateException("Output stream failed")
                runOnUiThread { result.success(uri.toString()) }
            } catch (e: Exception) {
                runOnUiThread { result.error("SAVE_ERROR", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun handleSave(call: MethodCall, result: MethodChannel.Result) {
        // Файл уже скачан во временный путь - переносим его в общую Download.
        val tempPath = call.argument<String>("tempPath") ?: ""
        val name = call.argument<String>("name") ?: ""
        val subDir = call.argument<String>("subDir") ?: ""
        val mimeType = call.argument<String>("mimeType")
            ?: "application/octet-stream"
        // Копия гигабайтного файла в главном потоке - «Приложение не отвечает».
        Thread {
            try {
                val uri = saveToDownloads(tempPath, name, subDir, mimeType).toString()
                runOnUiThread { result.success(uri) }
            } catch (e: Exception) {
                runOnUiThread { result.error("SAVE_ERROR", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    /// Переносит скачанный во временный путь файл в общую папку Download.
    /// [subDir] - относительный путь внутри Download (структура скачанной папки).
    /// Android 10+: MediaStore.Downloads - разрешений не нужно, файл виден
    /// всем приложениям и в системном экране «Загрузки».
    /// Старые Android: прямой перенос в /storage/emulated/0/Download
    /// (нужно разрешение WRITE_EXTERNAL_STORAGE, его запрашиваем заранее).
    private fun saveToDownloads(tempPath: String, name: String, subDir: String, mimeType: String): Uri {
        val temp = java.io.File(tempPath)
        if (!temp.exists()) throw java.io.FileNotFoundException(tempPath)
        val cleanSub = subDir.split('/', '\\')
            .filter { it.isNotEmpty() && it != "." && it != ".." }
            .joinToString("/")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Downloads.DISPLAY_NAME, name)
                put(android.provider.MediaStore.Downloads.MIME_TYPE, mimeType)
                put(
                    android.provider.MediaStore.Downloads.RELATIVE_PATH,
                    if (cleanSub.isEmpty()) Environment.DIRECTORY_DOWNLOADS
                    else "${Environment.DIRECTORY_DOWNLOADS}/$cleanSub"
                )
                // Пока копируем, файл скрыт от других приложений.
                put(android.provider.MediaStore.Downloads.IS_PENDING, 1)
                // Уже занятое имя MediaStore сам переименует в «name (1).ext».
            }
            val resolver = contentResolver
            val uri = resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    temp.inputStream().use { it.copyTo(out) }
                } ?: throw IllegalStateException("MediaStore output stream failed")
                val done = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(uri, done, null, null)
            } catch (e: Exception) {
                // Недописанную запись не оставляем.
                try { resolver.delete(uri, null, null) } catch (_: Exception) {}
                throw e
            }
            temp.delete()
            return uri
        }

        // Android 9 и ниже: классическая файловая система.
        val root = java.io.File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).path
        )
        val dir = if (cleanSub.isEmpty()) root else java.io.File(root, cleanSub)
        if (!dir.exists() && !dir.mkdirs()) {
            throw java.io.IOException("Cannot create directory ${dir.path}")
        }
        var target = java.io.File(dir, name)
        var i = 1
        while (target.exists()) {
            val dot = name.lastIndexOf('.')
            val base = if (dot > 0) name.substring(0, dot) else name
            val ext = if (dot > 0) name.substring(dot) else ""
            target = java.io.File(dir, "$base ($i)$ext")
            i++
        }
        try {
            temp.copyTo(target, overwrite = false)
        } catch (e: Exception) {
            target.delete()
            throw e
        }
        temp.delete()
        // Чтобы файл сразу появился в «Загрузках» и у других приложений.
        android.media.MediaScannerConnection.scanFile(this, arrayOf(target.path), null, null)
        return Uri.fromFile(target)
    }
}
