// AnyPlay для iPhone та iPad: звук гри (PCM 16 біт з рідної частини) через AVAudioEngine.
// Затримку тримаємо малою: якщо в черзі вже понад ~100 мс звуку, нові шматки відкидаємо.
import AVFoundation

final class AudioOut
{
	private let engine = AVAudioEngine()
	private let node = AVAudioPlayerNode()
	private var format: AVAudioFormat?
	private var channels = 2
	private let lock = NSLock()
	private var queued = 0          // кадрів у черзі
	private var rate: Double = 48000
	private var running = false

	init()
	{
		engine.attach(node)
	}

	func setFormat(channels: Int, rate: Double)
	{
		lock.lock(); defer { lock.unlock() }
		self.channels = max(1, min(2, channels))
		self.rate = rate
		guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(self.channels), interleaved: false) else { return }
		format = f
		if running { lock.unlock(); node.stop(); engine.stop(); lock.lock() }   // 145: див. stop()
		engine.disconnectNodeOutput(node)
		engine.connect(node, to: engine.mainMixerNode, format: f)
		do
		{
			try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
			try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.01)
			try AVAudioSession.sharedInstance().setActive(true)
			try engine.start()
			node.play()
			running = true
		}
		catch { running = false }
		queued = 0
	}

	/** З потоку сесії: frames кадрів на канал, переміжані */
	func play(_ pcm: UnsafePointer<Int16>, frames: Int)
	{
		lock.lock()
		guard running, let f = format, queued < Int(rate * 0.1) else { lock.unlock(); return }
		queued += frames
		let ch = channels
		lock.unlock()
		guard let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)), let data = b.floatChannelData else { return }
		b.frameLength = AVAudioFrameCount(frames)
		for c in 0..<ch
		{
			let out = data[c]
			for i in 0..<frames { out[i] = Float(pcm[i * ch + c]) / 32768 }
		}
		node.scheduleBuffer(b) { [weak self] in
			guard let s = self else { return }
			s.lock.lock(); s.queued = max(0, s.queued - frames); s.lock.unlock()
		}
	}

	func stop()
	{
		// 145: зупинка плеєра кличе обробники черги, а вони беруть lock — тримаючи lock тут, програма зависала («Вийти з гри»)
		lock.lock()
		let was = running
		running = false
		lock.unlock()
		if was { node.stop(); engine.stop() }
	}
}
