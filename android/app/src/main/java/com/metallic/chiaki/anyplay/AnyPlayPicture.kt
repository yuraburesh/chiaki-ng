// AnyPlay: кольори картинки на телефоні — яскравість, контраст, насиченість, тепло.
// Декодер (MediaCodec) пише кадри прямо в SurfaceView, тож звичайним View-фільтром їх не змінити. Тому, лише коли
// кольори не на нулі, декодер пише в SurfaceTexture, а ColorRenderer одразу ж (на кожен кадр, без черги)
// малює його шейдером OpenGL ES 2 у ту саму SurfaceView. Це один прохід відеокарти (частки мілісекунди),
// без TextureView і без зайвого кадру в черзі. Коли все на нулі — картинка йде напряму, як і раніше.
package com.metallic.chiaki.anyplay

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object AnyPlayPicture
{
	private const val PREFS = "anyplay"
	val KEYS = arrayOf("brightness", "contrast", "saturation", "warmth")

	private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

	/** Значення -50..50 для кожного з KEYS */
	fun values(context: Context): IntArray = IntArray(KEYS.size) { prefs(context).getInt("pic_" + KEYS[it], 0).coerceIn(-50, 50) }

	fun json(context: Context): JSONObject
	{
		val v = values(context)
		val o = JSONObject()
		KEYS.forEachIndexed { i, k -> o.put(k, v[i]) }
		o.put("sharp", sharp(context))
		o.put("sharpSlow", sharpSlow(context))
		return o
	}

	/** Зберегти з JSON сторінки (відсутні ключі не змінюються) */
	fun set(context: Context, o: JSONObject)
	{
		val e = prefs(context).edit()
		for(k in KEYS)
			if(o.has(k))
				e.putInt("pic_$k", o.optInt(k, 0).coerceIn(-50, 50))
		if(o.has("sharp"))
			e.putInt(SHARP_KEY, o.optInt("sharp", SHARP_DEFAULT).coerceIn(0, 2))
		e.apply()
	}

	fun reset(context: Context)
	{
		val e = prefs(context).edit()
		for(k in KEYS)
			e.remove("pic_$k")
		e.apply()
	}

	// ── AnyPlay 123: чіткість (адаптивне підвищення різкості, як FidelityFX CAS) ──
	// 0 — вимкнено, 1 — помірна, 2 — сильна: дрібні деталі (вивіски, листя, обличчя) чіткіші, без ореолів на краях.
	// Рахує відеокарта в тому ж одному проході, що й кольори. Типово вимкнена: гравець вмикає сам у «Зображення»
	// (на старих телефонах обробка відеокартою — додатковий ризик, тож без згоди не вмикаємо).
	const val SHARP_KEY = "pic_sharp"
	const val SHARP_DEFAULT = 0
	private val SHARP_AMOUNT = floatArrayOf(0f, 0.55f, 1f)

	fun sharp(context: Context): Int = prefs(context).getInt(SHARP_KEY, SHARP_DEFAULT).coerceIn(0, 2)
	fun setSharp(context: Context, v: Int) = prefs(context).edit().putInt(SHARP_KEY, v.coerceIn(0, 2)).apply()

	/** Чіткість не встигала на цьому телефоні (кадри затримувались) — вимкнена до наступної версії програми */
	private const val SHARP_SLOW_KEY = "pic_sharp_slow_build"
	fun sharpSlow(context: Context) = prefs(context).getInt(SHARP_SLOW_KEY, 0) == AnyPlayCloud.BUILD
	fun markSharpSlow(context: Context) = prefs(context).edit().putInt(SHARP_SLOW_KEY, AnyPlayCloud.BUILD).apply()

	/**
	 * Параметри шейдера: [яскравість, контраст, насиченість, тепло, чіткість] або null, якщо все на нулі й чіткість
	 * вимкнена — тоді без обробки, декодер пише прямо на екран
	 */
	fun params(context: Context): FloatArray?
	{
		val v = values(context)
		val sh = if(sharpSlow(context)) 0f else SHARP_AMOUNT[sharp(context)]
		if(v.all { it == 0 } && sh == 0f)
			return null
		return floatArrayOf(
			v[0] / 50f * 0.22f,          // зсув яскравості
			1f + v[1] / 50f * 0.45f,     // контраст 0.55..1.45
			1f + v[2] / 50f * 0.9f,      // насиченість 0.1..1.9
			v[3] / 50f * 0.07f,          // тепло: червоний вгору, синій вниз
			sh)                          // чіткість 0..1
	}
}

/**
 * Обробка кольорів відеокартою: вхід — SurfaceTexture (input), вихід — поверхня SurfaceView (output).
 * Усе GL — у власному потоці. Порядок підключення важливий: спершу start() і декодер на input,
 * потім attachOutput() (поки декодер пише в output, EGL туди не підключиться); вимкнення — навпаки.
 */
class ColorRenderer(val output: Surface)
{
	companion object
	{
		private const val TAG = "AnyPlayColor"

		private const val VERTEX = """
attribute vec4 aPos;
attribute vec4 aTex;
uniform mat4 uSt;
varying vec2 vTex;
void main() {
  gl_Position = aPos;
  vTex = (uSt * aTex).xy;
}"""

		private const val FRAGMENT = """#extension GL_OES_EGL_image_external : require
precision mediump float;
varying vec2 vTex;
uniform samplerExternalOES uTex;
uniform vec4 uP;
uniform vec3 uS;   // xy — крок одного пікселя відео в координатах текстури, z — сила чіткості 0..1
void main() {
  vec3 c = texture2D(uTex, vTex).rgb;
  if(uS.z > 0.0) {
    // адаптивна чіткість (як FidelityFX CAS): що менший місцевий контраст, то сильніше підкреслюємо деталь;
    // на різких краях — слабше, тож ореолів немає. 5 вибірок «хрестом».
    vec3 n = texture2D(uTex, vTex - vec2(0.0, uS.y)).rgb;
    vec3 s = texture2D(uTex, vTex + vec2(0.0, uS.y)).rgb;
    vec3 w = texture2D(uTex, vTex - vec2(uS.x, 0.0)).rgb;
    vec3 e = texture2D(uTex, vTex + vec2(uS.x, 0.0)).rgb;
    vec3 mn = min(c, min(min(n, s), min(w, e)));
    vec3 mx = max(c, max(max(n, s), max(w, e)));
    vec3 amp = sqrt(clamp(min(mn, 1.0 - mx) / max(mx, 0.0001), 0.0, 1.0));
    vec3 wgt = -amp / mix(8.0, 5.0, uS.z);
    c = clamp((c + (n + s + w + e) * wgt) / (1.0 + 4.0 * wgt), 0.0, 1.0);
  }
  c = (c - 0.5) * uP.y + 0.5 + uP.x;
  float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c = mix(vec3(l), c, uP.z);
  c += vec3(uP.w, uP.w * 0.25, -uP.w);
  gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}"""
	}

	private val thread = HandlerThread("anyplay-color").apply { start() }
	private val handler = Handler(thread.looper)

	private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
	private var context: EGLContext = EGL14.EGL_NO_CONTEXT
	private var config: EGLConfig? = null
	private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
	private var window: EGLSurface = EGL14.EGL_NO_SURFACE
	private var program = 0
	private var texture = 0
	private var aPos = 0
	private var aTex = 0
	private var uSt = 0
	private var uP = 0
	private var uS = 0
	private var texture2: SurfaceTexture? = null
	private val st = FloatArray(16)
	private val quad: FloatBuffer = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
		put(floatArrayOf(-1f, -1f, 0f, 0f,   1f, -1f, 1f, 0f,   -1f, 1f, 0f, 1f,   1f, 1f, 1f, 1f))
		position(0)
	}

	@Volatile var params = floatArrayOf(0f, 1f, 1f, 0f, 0f)

	/** Розмір кадру відео (для кроку пікселя в чіткості) */
	@Volatile var videoWidth = 1280
	@Volatile var videoHeight = 720

	/** AnyPlay 118: скільки кадрів справді намальовано на екрані (перевірка «картинка є») */
	@Volatile var drawn = 0L
		private set

	/** Поверхня для декодера (є після вдалого start()) */
	var input: Surface? = null
		private set

	private fun <T> sync(def: T, block: () -> T): T
	{
		var result = def
		val done = CountDownLatch(1)
		val posted = handler.post {
			try { result = block() }
			catch(e: Throwable) { Log.e(TAG, "GL: ${e.message}") }
			finally { done.countDown() }
		}
		if(posted)
			done.await(3, TimeUnit.SECONDS)
		return result
	}

	/** EGL, шейдер, вхідна SurfaceTexture. false — не вдалося, тоді картинка піде напряму */
	fun start(): Boolean = sync(false) {
		display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
		val ver = IntArray(2)
		if(display == EGL14.EGL_NO_DISPLAY || !EGL14.eglInitialize(display, ver, 0, ver, 1))
			return@sync false
		val attrs = intArrayOf(
			EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
			EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
			EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
			EGL14.EGL_NONE)
		val configs = arrayOfNulls<EGLConfig>(1)
		val n = IntArray(1)
		if(!EGL14.eglChooseConfig(display, attrs, 0, configs, 0, 1, n, 0) || n[0] < 1)
			return@sync false
		config = configs[0]
		context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
		if(context == EGL14.EGL_NO_CONTEXT)
			return@sync false
		pbuffer = EGL14.eglCreatePbufferSurface(display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
		if(pbuffer == EGL14.EGL_NO_SURFACE || !EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context))
			return@sync false
		program = buildProgram()
		if(program == 0)
			return@sync false
		aPos = GLES20.glGetAttribLocation(program, "aPos")
		aTex = GLES20.glGetAttribLocation(program, "aTex")
		uSt = GLES20.glGetUniformLocation(program, "uSt")
		uP = GLES20.glGetUniformLocation(program, "uP")
		uS = GLES20.glGetUniformLocation(program, "uS")
		val t = IntArray(1)
		GLES20.glGenTextures(1, t, 0)
		texture = t[0]
		GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
		GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
		GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
		GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
		GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
		val tex = SurfaceTexture(texture)
		tex.setOnFrameAvailableListener({ drawFrame() }, handler)
		texture2 = tex
		input = Surface(tex)
		true
	}

	/** Підключити вихід (SurfaceView), коли декодер уже пише в input */
	fun attachOutput(): Boolean = sync(false) {
		if(window != EGL14.EGL_NO_SURFACE)
			return@sync true
		val w = EGL14.eglCreateWindowSurface(display, config, output, intArrayOf(EGL14.EGL_NONE), 0)
		if(w == EGL14.EGL_NO_SURFACE)
			return@sync false
		window = w
		EGL14.eglMakeCurrent(display, window, window, context)
		EGL14.eglSwapInterval(display, 0)   // не чекаємо на кадр екрана: найсвіжіший кадр одразу
		true
	}

	/** Відключитись від SurfaceView (перед тим, як декодер знову писатиме туди напряму) */
	fun detachOutput()
	{
		sync(Unit) {
			if(window != EGL14.EGL_NO_SURFACE)
			{
				EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
				EGL14.eglDestroySurface(display, window)
				window = EGL14.EGL_NO_SURFACE
			}
		}
	}

	fun release()
	{
		sync(Unit) {
			if(display != EGL14.EGL_NO_DISPLAY)
			{
				if(window != EGL14.EGL_NO_SURFACE)
					EGL14.eglDestroySurface(display, window)
				window = EGL14.EGL_NO_SURFACE
				texture2?.setOnFrameAvailableListener(null)
				input?.release()
				texture2?.release()
				if(program != 0) GLES20.glDeleteProgram(program)
				if(texture != 0) GLES20.glDeleteTextures(1, intArrayOf(texture), 0)
				EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
				if(pbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, pbuffer)
				if(context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
				EGL14.eglReleaseThread()
				EGL14.eglTerminate(display)
			}
			display = EGL14.EGL_NO_DISPLAY
			input = null
			texture2 = null
		}
		thread.quitSafely()
	}

	private fun drawFrame()
	{
		val tex = texture2 ?: return
		try
		{
			if(window == EGL14.EGL_NO_SURFACE)
			{
				tex.updateTexImage()   // забираємо кадр, щоб декодер не стояв
				return
			}
			tex.updateTexImage()
			tex.getTransformMatrix(st)
			val w = IntArray(1)
			val h = IntArray(1)
			EGL14.eglQuerySurface(display, window, EGL14.EGL_WIDTH, w, 0)
			EGL14.eglQuerySurface(display, window, EGL14.EGL_HEIGHT, h, 0)
			GLES20.glViewport(0, 0, w[0], h[0])
			GLES20.glUseProgram(program)
			GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
			GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
			quad.position(0)
			GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad)
			GLES20.glEnableVertexAttribArray(aPos)
			quad.position(2)
			GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, quad)
			GLES20.glEnableVertexAttribArray(aTex)
			GLES20.glUniformMatrix4fv(uSt, 1, false, st, 0)
			val p = params
			GLES20.glUniform4f(uP, p[0], p[1], p[2], p[3])
			// крок пікселя: у координатах текстури після матриці SurfaceTexture (вона лише обрізає/віддзеркалює)
			val sx = kotlin.math.abs(st[0]) / videoWidth.coerceAtLeast(1)
			val sy = kotlin.math.abs(st[5]) / videoHeight.coerceAtLeast(1)
			GLES20.glUniform3f(uS, sx, sy, if(p.size > 4) p[4] else 0f)
			GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
			if(EGL14.eglSwapBuffers(display, window))
				drawn++
			else if(drawn == 0L)
				Log.e(TAG, "eglSwapBuffers: 0x" + Integer.toHexString(EGL14.eglGetError()))
		}
		catch(e: Exception)
		{
			Log.e(TAG, "Кадр не намальовано: ${e.message}")
		}
	}

	private fun shader(type: Int, src: String): Int
	{
		val s = GLES20.glCreateShader(type)
		GLES20.glShaderSource(s, src)
		GLES20.glCompileShader(s)
		val ok = IntArray(1)
		GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
		if(ok[0] == 0)
		{
			Log.e(TAG, "Шейдер: " + GLES20.glGetShaderInfoLog(s))
			GLES20.glDeleteShader(s)
			return 0
		}
		return s
	}

	private fun buildProgram(): Int
	{
		val v = shader(GLES20.GL_VERTEX_SHADER, VERTEX)
		val f = shader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT)
		if(v == 0 || f == 0)
			return 0
		val p = GLES20.glCreateProgram()
		GLES20.glAttachShader(p, v)
		GLES20.glAttachShader(p, f)
		GLES20.glLinkProgram(p)
		val ok = IntArray(1)
		GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
		GLES20.glDeleteShader(v)
		GLES20.glDeleteShader(f)
		if(ok[0] == 0)
		{
			Log.e(TAG, "Програма: " + GLES20.glGetProgramInfoLog(p))
			GLES20.glDeleteProgram(p)
			return 0
		}
		return p
	}
}
