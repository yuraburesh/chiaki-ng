// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.session

import com.metallic.chiaki.anyplay.AnyPlayDiag
import android.graphics.SurfaceTexture
import android.util.Log
import android.view.*
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.metallic.chiaki.common.LogManager
import com.metallic.chiaki.lib.*
import com.metallic.chiaki.anyplay.ColorRenderer

sealed class StreamState
object StreamStateIdle: StreamState()
object StreamStateConnecting: StreamState()
object StreamStateConnected: StreamState()
data class StreamStateCreateError(val error: CreateError): StreamState()
data class StreamStateQuit(val reason: QuitReason, val reasonString: String?): StreamState()
data class StreamStateLoginPinRequest(val pinIncorrect: Boolean): StreamState()
/** AnyPlay: не вдалося з'єднатися з PS5 через інтернет (PSN). step — на якому кроці (Session.psnStep), diag — подробиці з журналу */
data class StreamStatePsnFailed(val error: ErrorCode, val step: Int = 0, val diag: PsnDiag = PsnDiag(0, 0, "")): StreamState()

class StreamSession(var connectInfo: ConnectInfo, val logManager: LogManager, val logVerbose: Boolean, val input: StreamInput)
{
	var session: Session? = null
		private set

	private val _state = MutableLiveData<StreamState>(StreamStateIdle)
	val state: LiveData<StreamState> get() = _state
	private val _rumbleState = MutableLiveData<RumbleEvent>(RumbleEvent(0U, 0U))
	val rumbleState: LiveData<RumbleEvent> get() = _rumbleState

	private var surfaceTexture: SurfaceTexture? = null
	private var surface: Surface? = null

	// AnyPlay 118.1: чи пішов у цю сесію хоч один стан з натисканням (для журналу: «керування не йде в гру»)
	@Volatile private var inputLogged: Session? = null

	init
	{
		input.controllerStateChangedCallback = { state ->
			val s = session
			if(s != null)
			{
				s.setControllerState(state)
				if(inputLogged !== s && (state.buttons != 0U || state.l2State > 0U || state.r2State > 0U ||
						state.leftX.toInt() != 0 || state.leftY.toInt() != 0 || state.rightX.toInt() != 0 || state.rightY.toInt() != 0))
				{
					inputLogged = s
					AnyPlayDiag.i("Ввід: перше натискання в цій сесії пішло в гру (кнопки 0x${state.buttons.toString(16)}, стан ${_state.value?.javaClass?.simpleName})")
				}
			}
		}
	}

	// AnyPlay: поки PSN пробиває з'єднання, сесію не можна звільняти — це зробить фоновий потік
	private val psnLock = Any()
	private var psnPending: Session? = null
	private val psnAbandoned = HashSet<Session>()

	fun shutdown()
	{
		val s = session
		session = null
		_state.value = StreamStateIdle
		if(s == null)
			return
		// AnyPlay: подія «трансляцію зупинено» від цієї, уже закритої сесії не повинна дійти до екрана гри —
		// інакше після перепідключення (зміна якості, повернення в застосунок) гра сама закривалась і викидало на головну
		s.eventCallback = null
		synchronized(psnLock)
		{
			if(psnPending === s)
			{
				psnAbandoned.add(s)
				s.eventCallback = null
				// AnyPlay 118: декодер цієї сесії вже тримає поверхню екрана, а сама сесія звільниться пізніше
				// (у фоні, коли PSN відповість, до хвилини). Відпускаємо поверхню одразу: інакше декодер нової сесії
				// не міг підключитися до неї — і в новій спробі був звук без картинки
				s.setSurface(null)
				s.psnCancel()
				return
			}
		}
		s.stop()
		s.dispose()
		//surfaceTexture?.release()
	}

	fun pause()
	{
		shutdown()
	}

	fun resume()
	{
		if(session != null)
			return
		try
		{
			val session = Session(connectInfo, logManager.createNewFile().file.absolutePath, logVerbose)
			_state.value = StreamStateConnecting
			session.eventCallback = { event -> if(this.session === session) eventCallback(event) }
			this.session = session
			// 118.1: нова сесія (перепідключення) одразу отримує поточний стан керування, а не лише після наступного дотику
			session.setControllerState(input.controllerState)
			val duid = connectInfo.psnDuid
			if(connectInfo.psnToken != null && duid != null)
			{
				synchronized(psnLock) { psnPending = session }
				Thread {
					val err = session.psnConnect(duid)
					synchronized(psnLock)
					{
						psnPending = null
						if(psnAbandoned.remove(session))
						{
							session.dispose()
							return@Thread
						}
						if(err.isSuccess)
							session.start()
						else
						{
							val step = session.psnStep()
							val diag = ChiakiPsn.diag()
							AnyPlayDiag.e("PSN connect failed: step $step, error ${err.value} ($err), HTTP ${diag.http}, curl ${diag.curl}: ${diag.line}")
							_state.postValue(StreamStatePsnFailed(err, step, diag))
						}
					}
				}.apply { name = "anyplay-psn"; isDaemon = true }.start()
			}
			else
				session.start()
			val surface = surface
			if(surface != null)
				session.setSurface(surface)
		}
		catch(e: CreateError)
		{
			_state.value = StreamStateCreateError(e)
		}
	}

	private fun eventCallback(event: Event)
	{
		when(event)
		{
			is ConnectedEvent -> _state.postValue(StreamStateConnected)
			is QuitEvent -> _state.postValue(
				StreamStateQuit(
					event.reason,
					event.reasonString
				)
			)
			is LoginPinRequestEvent -> _state.postValue(
				StreamStateLoginPinRequest(
					event.pinIncorrect
				)
			)
			is RumbleEvent -> _rumbleState.postValue(event)
		}
	}

	// AnyPlay: кольори картинки (AnyPlayPicture). Коли вони не на нулі, декодер пише в ColorRenderer,
	// а той малює в SurfaceView; інакше декодер пише в SurfaceView напряму, як було завжди.
	private var viewSurface: Surface? = null
	private var color: ColorRenderer? = null
	private var colorParams: FloatArray? = null
	/** AnyPlay 118: обробка кольорів на цьому телефоні не показала жодного кадру — до кінця гри картинка напряму */
	var colorBlocked = false
		private set

	/** null — без обробки кольорів */
	fun setColor(params: FloatArray?)
	{
		colorParams = if(colorBlocked) null else params
		color?.let { c -> if(colorParams != null) c.params = colorParams!! }
		routeSurface()
	}

	/** Поверхня екрана гри є (SurfaceView створено) */
	val hasSurface get() = viewSurface != null

	/** Обробка кольорів зараз увімкнена (декодер пише в ColorRenderer) */
	val colorActive get() = color != null

	/** Скільки кадрів обробка кольорів намалювала на екрані (-1 — обробка вимкнена) */
	fun colorFrames(): Long = color?.drawn ?: -1L

	/** AnyPlay 118: обробка кольорів не малює картинку — вимкнути її до кінця гри, картинка піде напряму */
	fun blockColor()
	{
		if(colorBlocked)
			return
		colorBlocked = true
		AnyPlayDiag.w("Обробка кольорів не показала картинку: до кінця гри картинка напряму")
		colorParams = null
		routeSurface()
	}

	/** AnyPlay 118: картинка не йде — попросити ключовий кадр */
	fun requestKeyFrame(reason: String) = session?.requestKeyFrame(reason)

	/** AnyPlay 118: картинка так і не з'явилась — створити декодер заново */
	fun resetDecoder(): Boolean = session?.resetDecoder() ?: false

	private fun routeSurface()
	{
		val out = viewSurface
		val want = colorParams
		val c = color
		if(c != null && (out == null || want == null || c.output !== out))
		{
			// вимикаємо обробку: спершу GL відпускає SurfaceView, потім декодер пише туди напряму
			color = null
			c.detachOutput()
			surface = out
			session?.setSurface(out)
			c.release()
			if(out == null || want == null)
				return
		}
		if(out == null)
			return
		if(want == null)
		{
			if(surface !== out)
			{
				surface = out
				session?.setSurface(out)
			}
			return
		}
		if(color != null)
			return
		val r = ColorRenderer(out)
		val input = if(r.start()) r.input else null
		if(input == null)
		{
			// 118.1: до цього тут був лише return — декодер так і не отримував поверхню, і гра йшла без картинки
			// («Received video data, but decoder is not initialized» у журналі Galaxy S7). Тепер — картинка напряму
			AnyPlayDiag.e("Обробка кольорів недоступна на цьому телефоні: картинка напряму")
			r.release()
			colorBlocked = true
			colorParams = null
			surface = out
			session?.setSurface(out)
			return
		}
		r.params = want
		surface = input
		session?.setSurface(input)
		if(!r.attachOutput())
		{
			AnyPlayDiag.e("Обробка кольорів не підключилась до екрана: картинка напряму")
			colorBlocked = true
			colorParams = null
			surface = out
			session?.setSurface(out)
			r.release()
			return
		}
		color = r
	}

	fun attachToSurfaceView(surfaceView: SurfaceView)
	{
		surfaceView.holder.addCallback(object: SurfaceHolder.Callback {
			override fun surfaceCreated(holder: SurfaceHolder) { }

			override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int)
			{
				val surface = holder.surface
				viewSurface = surface
				if(colorParams == null && color == null)
				{
					this@StreamSession.surface = surface
					session?.setSurface(surface)
				}
				else
					routeSurface()
			}

			override fun surfaceDestroyed(holder: SurfaceHolder)
			{
				viewSurface = null
				val c = color
				color = null
				c?.detachOutput()
				this@StreamSession.surface = null
				session?.setSurface(null)
				c?.release()
			}
		})
	}

	fun attachToTextureView(textureView: TextureView)
	{
		textureView.surfaceTextureListener = object: TextureView.SurfaceTextureListener {
			override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int)
			{
				if(surfaceTexture != null)
					return
				surfaceTexture = surface
				this@StreamSession.surface = Surface(surfaceTexture)
				session?.setSurface(Surface(surface))
			}

			override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean
			{
				// return false if we want to keep the surface texture
				return surfaceTexture == null
			}

			override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) { }
			override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
		}

		val surfaceTexture = surfaceTexture
		if(surfaceTexture != null)
			textureView.setSurfaceTexture(surfaceTexture)
	}

	fun setLoginPin(pin: String)
	{
		session?.setLoginPin(pin)
	}
}