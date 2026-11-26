// AnyPlay 118.2: діагностика смерті процесу. На Galaxy S7 власника гра гинула без жодного сліду: застосунок не бачить
// системних записів падінь, logcat «chatty» стирав останні рядки, а журнал сесії сидів у буфері. Тепер:
//  - власний журнал програми (файл, кожен рядок одразу на диск, з часом і номером процесу), а не лише logcat;
//  - падіння Kotlin/Java (UncaughtExceptionHandler) і рідного коду (обробник сигналів у crash-handler.c) — у файли;
//  - сторож головного потоку: завис довше ніж на 2 с — стек головного потоку в журнал;
//  - прохання системи звільнити пам'ять (onTrimMemory) і причини минулих завершень процесу (Android 11+) — у журнал.
// Усе це першим іде в наступний журнал для підтримки (AnyPlayCloud.uploadLog).
package com.metallic.chiaki.anyplay

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import com.metallic.chiaki.lib.ChiakiPsn
import java.io.File
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object AnyPlayDiag
{
	private const val TAG = "AnyPlay"
	private const val APP_LOG_MAX = 256 * 1024L     // журнал програми: коли більший — лишаємо другу половину
	private const val STALL_MS = 2000L
	private const val STALL_UPLOAD_MS = 5000L
	private const val PREFS = "anyplay"
	private const val KEY_EXIT_SEEN = "exit_reason_seen"

	@Volatile private var appLog: File? = null
	@Volatile private var crashDir: File? = null
	@Volatile private var appCtx: Context? = null
	private val lock = Any()
	private var installed = false

	fun crashDir(context: Context): File = File(context.applicationContext.filesDir, "crash").also { it.mkdirs() }

	/** Один раз на процес (виклик з onCreate будь-якого екрана) */
	fun install(context: Context)
	{
		synchronized(lock)
		{
			if(installed)
				return
			installed = true
		}
		val app = context.applicationContext
		appCtx = app
		val dir = crashDir(app)
		crashDir = dir
		appLog = File(app.filesDir, "anyplay_app.log")
		i("— процес ${Process.myPid()} запущено, AnyPlay ${AnyPlayCloud.BUILD}, ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}; ${memoryLine(app)}")

		// падіння Kotlin/Java: стек у файл, далі — як без нас (система закриє процес)
		val previous = Thread.getDefaultUncaughtExceptionHandler()
		Thread.setDefaultUncaughtExceptionHandler { t, e ->
			try
			{
				val sw = StringWriter()
				e.printStackTrace(PrintWriter(sw))
				val text = "\n=== AnyPlay: падіння Java/Kotlin у потоці «${t.name}», ${stamp()}, процес ${Process.myPid()} ===\n$sw"
				File(dir, "java-crash.txt").appendText(text)
				appendAppLog("E", "Падіння в потоці «${t.name}»: $e")
			}
			catch(x: Throwable) {}
			previous?.uncaughtException(t, e)
		}

		// падіння рідного коду (сигнали): файл відкриває бібліотека заздалегідь
		try { ChiakiPsn.setCrashFile(File(dir, "native-crash.txt").absolutePath) }
		catch(e: Throwable) { w("Обробник падінь рідного коду не встановлено: $e") }

		startMainWatchdog()
		logExitReasons(app)
	}

	private fun stamp(): String = SimpleDateFormat("dd.MM HH:mm:ss.SSS", Locale.ROOT).format(Date())

	private fun memoryLine(context: Context): String = try
	{
		val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
		val mi = ActivityManager.MemoryInfo()
		am.getMemoryInfo(mi)
		val rt = Runtime.getRuntime()
		"пам'ять: вільно ${mi.availMem / 1048576} з ${mi.totalMem / 1048576} МБ${if(mi.lowMemory) " (мало!)" else ""}, " +
			"Java ${(rt.totalMemory() - rt.freeMemory()) / 1048576}/${rt.maxMemory() / 1048576} МБ, клас пам'яті ${am.memoryClass} МБ"
	}
	catch(e: Throwable) { "пам'ять: ?" }

	private fun appendAppLog(level: String, msg: String)
	{
		val f = appLog ?: return
		try
		{
			synchronized(lock)
			{
				if(f.length() > APP_LOG_MAX)
				{
					val keep = f.readBytes().let { it.copyOfRange(it.size / 2, it.size) }
					f.writeBytes(keep)
				}
				// запис одразу в ядро (переживе смерть процесу); fsync не робимо — він гальмував би головний потік
				FileOutputStream(f, true).use {
					it.write("${stamp()} ${Process.myPid()} $level $msg\n".toByteArray(Charsets.UTF_8))
				}
			}
		}
		catch(e: Throwable) {}
	}

	fun i(msg: String) { Log.i(TAG, msg); appendAppLog("I", msg) }
	fun w(msg: String) { Log.w(TAG, msg); appendAppLog("W", msg) }
	fun e(msg: String) { Log.e(TAG, msg); appendAppLog("E", msg) }

	/** Система просить звільнити пам'ять (викликають екрани з onTrimMemory) */
	fun trimMemory(context: Context, level: Int)
	{
		if(level >= 10)   // TRIM_MEMORY_RUNNING_LOW і вище: справді мало пам'яті
			w("Система просить звільнити пам'ять (рівень $level); ${memoryLine(context)}")
	}

	// ── сторож головного потоку ──
	@Volatile private var mainAck = 0L
	private fun startMainWatchdog()
	{
		val main = Handler(Looper.getMainLooper())
		Thread {
			var stalledSince = 0L
			var reported = false
			var uploaded = false
			while(true)
			{
				val posted = SystemClock.uptimeMillis()
				main.post { mainAck = SystemClock.uptimeMillis() }
				try { Thread.sleep(500) } catch(e: InterruptedException) { return@Thread }
				val now = SystemClock.uptimeMillis()
				if(mainAck >= posted)
				{
					if(reported)
						w("Головний потік знову відповідає (завис на ${now - stalledSince} мс)")
					stalledSince = 0L
					reported = false
					continue
				}
				if(stalledSince == 0L)
					stalledSince = posted
				if(!reported && now - stalledSince >= STALL_MS)
				{
					reported = true
					val trace = Looper.getMainLooper().thread.stackTrace.take(40).joinToString("\n") { "    at $it" }
					val text = "Головний потік не відповідає вже ${now - stalledSince} мс; де він зараз:\n$trace"
					w(text)
					try { crashDir?.let { File(it, "main-stall.txt").appendText("\n=== ${stamp()}, процес ${Process.myPid()} ===\n$text\n") } }
					catch(e: Throwable) {}
				}
				// AnyPlay 121: зависання довше 5 с — журнал на сервер одразу, з цього ж потоку, поки система не закрила
				// застосунок (на Galaxy S7 власника гра так і гинула: екран стояв, а журнал потім не надсилався)
				if(reported && !uploaded && now - stalledSince >= STALL_UPLOAD_MS)
				{
					uploaded = true
					val trace = Looper.getMainLooper().thread.stackTrace.take(40).joinToString("\n") { "    at $it" }
					w("Головний потік не відповідає ${(now - stalledSince) / 1000} с, надсилаю журнал; де він зараз:\n$trace")
					appCtx?.let { ctx ->
						try { AnyPlayCloud.uploadLog(ctx, "error", "Програма зависла: головний потік не відповідає ${(now - stalledSince) / 1000} с", force = true) }
						catch(e: Throwable) {}
					}
				}
			}
		}.apply { name = "anyplay-watchdog"; isDaemon = true; priority = Thread.MAX_PRIORITY }.start()
	}

	/** Android 11+: чому минулого разу завершився процес (система, пам'ять, падіння, ANR) */
	private fun logExitReasons(context: Context)
	{
		if(Build.VERSION.SDK_INT < Build.VERSION_CODES.R)
			return
		try
		{
			val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
			val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
			val seen = prefs.getLong(KEY_EXIT_SEEN, 0)
			val list = am.getHistoricalProcessExitReasons(context.packageName, 0, 5).filter { it.timestamp > seen }
			for(r in list.reversed())
				w("Минуле завершення процесу ${r.pid}: причина ${r.reason}, стан ${r.status}, важливість ${r.importance}, " +
					"пам'ять ${r.pss / 1024} МБ, ${SimpleDateFormat("dd.MM HH:mm:ss", Locale.ROOT).format(Date(r.timestamp))}: ${r.description ?: ""}")
			list.maxOfOrNull { it.timestamp }?.let { prefs.edit().putLong(KEY_EXIT_SEEN, it).apply() }
		}
		catch(e: Throwable) {}
	}

	/** Файли падінь і зависань за добу — першими в журнал для підтримки */
	fun crashReport(context: Context): String
	{
		val dir = crashDir(context)
		val now = System.currentTimeMillis()
		val sb = StringBuilder()
		dir.listFiles()?.filter { it.isFile && it.length() > 0 }?.sortedBy { it.lastModified() }?.forEach { f ->
			if(now - f.lastModified() > 3 * 24 * 3600 * 1000L)
			{
				f.delete()
				return@forEach
			}
			if(now - f.lastModified() > 24 * 3600 * 1000L)
				return@forEach
			val bytes = f.readBytes()
			val tail = if(bytes.size > 48 * 1024) bytes.copyOfRange(bytes.size - 48 * 1024, bytes.size) else bytes
			sb.append("\n===== ").append(f.name).append(" (").append(SimpleDateFormat("dd.MM HH:mm:ss", Locale.ROOT).format(Date(f.lastModified())))
				.append(") =====\n").append(String(tail, Charsets.UTF_8))
		}
		return sb.toString()
	}

	/** Чи є свіжі падіння, про які ще не повідомили (час останнього запису у файли падінь) */
	fun lastCrashAt(context: Context): Long =
		crashDir(context).listFiles()?.filter { it.isFile && it.length() > 0 }?.maxOfOrNull { it.lastModified() } ?: 0L

	/** Хвіст журналу програми (усі процеси за останній час) */
	fun appLogTail(context: Context, max: Int): String
	{
		val f = File(context.applicationContext.filesDir, "anyplay_app.log")
		if(!f.exists())
			return ""
		// 130: лише кінець файла (цілий файл міг бути завеликим для пам'яті)
		val tail = synchronized(lock) {
			java.io.RandomAccessFile(f, "r").use { raf ->
				val n = minOf(raf.length(), max.toLong()).toInt()
				val b = ByteArray(n)
				raf.seek(raf.length() - n)
				raf.readFully(b)
				b
			}
		}
		return String(tail, Charsets.UTF_8)
	}
}
