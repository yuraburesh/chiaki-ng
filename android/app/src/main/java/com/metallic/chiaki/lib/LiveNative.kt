// AnyPlay 124: рідна частина трансляції друзям з телефона (android/app/src/main/cpp/anyplay-live.cpp)
package com.metallic.chiaki.lib

object LiveNative
{
	/** Чи є трансляція в цій збірці (рідна бібліотека з libdatachannel) */
	val available: Boolean by lazy {
		try
		{
			System.loadLibrary("chiaki-jni")
			headerReady()
			true
		}
		catch(e: Throwable) { false }
	}

	@JvmStatic external fun headerReady(): Boolean
	@JvmStatic external fun codec(): String
	@JvmStatic external fun gameBytes(): Long
	/** "" — готово, інакше текст помилки */
	@JvmStatic external fun create(iceUrls: Array<String>, paceKbps: Int): String
	@JvmStatic external fun gathered(): Boolean
	@JvmStatic external fun localSdp(): String
	@JvmStatic external fun applyAnswer(sdp: String): String
	/** new|connecting|connected|disconnected|failed|closed або off */
	@JvmStatic external fun state(): String
	@JvmStatic external fun openChannel(id: Int, label: String, ordered: Boolean, maxRetransmits: Int): Boolean
	@JvmStatic external fun send(id: Int, text: String): Boolean
	@JvmStatic external fun goLive(gameAudio: Boolean)
	@JvmStatic external fun setGameAudio(on: Boolean)
	@JvmStatic external fun setVideoOn(on: Boolean)
	@JvmStatic external fun requestKeyframe()
	@JvmStatic external fun takeKeyWanted(): Int
	/** [кадрів прийшло, надіслано, пропущено, ключових, байтів надіслано, черга мс, rtt мс, втрати %, переповнень] */
	@JvmStatic external fun stats(): LongArray?
	@JvmStatic external fun close(eventsChannel: Int)
}
