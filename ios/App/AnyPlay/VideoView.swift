// AnyPlay для iPhone та iPad: відео з PS5 (Annex-B, H.265 або H.264) — в апаратний декодер iPhone через
// AVSampleBufferDisplayLayer. Набори параметрів (VPS/SPS/PPS) задають формат, кадри йдуть одразу на показ.
import AVFoundation
import UIKit

final class VideoView: UIView
{
	override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
	var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

	/** Декодер збився — попросити в приставки ключовий кадр */
	var onNeedKeyFrame: (() -> Void)?

	private var format: CMVideoFormatDescription?
	private var vps: Data?, sps: Data?, pps: Data?
	/** Формат потоку: на PS5 просимо H.265 (усі iPhone з iOS 15 мають апаратний декодер) */
	var hevc = true
	private var needKey = true
	private let lock = NSLock()
	private(set) var shown: UInt64 = 0

	override init(frame: CGRect)
	{
		super.init(frame: frame)
		backgroundColor = .black
		display.videoGravity = .resizeAspect
		isUserInteractionEnabled = false
	}

	required init?(coder: NSCoder) { fatalError() }

	var shownCount: UInt64 { lock.lock(); defer { lock.unlock() }; return shown }

	/** З потоку сесії: один кадр Annex-B */
	func feed(_ buf: UnsafeBufferPointer<UInt8>)
	{
		guard let base = buf.baseAddress, buf.count > 4 else { return }
		var nals: [(Int, Int)] = []   // (початок без стартового коду, довжина)
		var i = 0, start = -1
		let n = buf.count
		while i + 2 < n
		{
			if base[i] == 0 && base[i + 1] == 0 && base[i + 2] == 1
			{
				if start >= 0 { nals.append((start, trimEnd(base, start, i))) }
				start = i + 3
				i += 3
				continue
			}
			i += 1
		}
		if start >= 0 && start < n { nals.append((start, n - start)) }

		var frame = Data()
		var key = false
		var paramsChanged = false
		for (s, len) in nals where len > 0
		{
			let h = base[s]
			let nal = Data(bytes: base + s, count: len)
			if hevc
			{
				switch Int((h >> 1) & 0x3f)
				{
				case 32: if vps != nal { vps = nal; paramsChanged = true }; continue
				case 33: if sps != nal { sps = nal; paramsChanged = true }; continue
				case 34: if pps != nal { pps = nal; paramsChanged = true }; continue
				case 16...21: key = true
				default: break
				}
			}
			else
			{
				switch Int(h & 0x1f)
				{
				case 7: if sps != nal { sps = nal; paramsChanged = true }; continue
				case 8: if pps != nal { pps = nal; paramsChanged = true }; continue
				case 5: key = true
				default: break
				}
			}
			var be = UInt32(len).bigEndian
			frame.append(Data(bytes: &be, count: 4))
			frame.append(nal)
		}
		if paramsChanged { makeFormat() }
		guard let fmt = format, !frame.isEmpty else { return }
		// 139: програма згорнута — кадри не показуємо (екран у фоні недоступний, шар перейшов би в «збій»)
		if paused { needKey = true; return }
		if needKey && !key { return }
		needKey = false
		enqueue(frame, fmt)
	}

	private func trimEnd(_ base: UnsafePointer<UInt8>, _ start: Int, _ next: Int) -> Int
	{
		var e = next
		while e > start && base[e - 1] == 0 { e -= 1 }   // нулі перед наступним стартовим кодом
		return e - start
	}

	private func makeFormat()
	{
		var f: CMFormatDescription?
		if hevc, let v = vps, let s = sps, let p = pps
		{
			let sets = [v, s, p]
			let st: OSStatus = withPointers(sets) { ptrs, sizes in
				CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: ptrs,
					parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &f)
			}
			if st != noErr { f = nil }
		}
		else if !hevc, let s = sps, let p = pps
		{
			let st: OSStatus = withPointers([s, p]) { ptrs, sizes in
				CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
					parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &f)
			}
			if st != noErr { f = nil }
		}
		if let f = f
		{
			format = f
			needKey = true
		}
	}

	private func withPointers<R>(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R
	{
		let copies = sets.map { d -> UnsafeMutablePointer<UInt8> in
			let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
			d.copyBytes(to: p, count: d.count)
			return p
		}
		defer { copies.forEach { $0.deallocate() } }
		let ptrs = copies.map { UnsafePointer($0) }
		let sizes = sets.map { $0.count }
		return ptrs.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) } }
	}

	private func enqueue(_ frame: Data, _ fmt: CMVideoFormatDescription)
	{
		var block: CMBlockBuffer?
		let count = frame.count
		guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count, blockAllocator: kCFAllocatorDefault,
			customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let bb = block else { return }
		frame.withUnsafeBytes { raw in
			_ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: count)
		}
		var sample: CMSampleBuffer?
		var size = count
		guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt, sampleCount: 1,
			sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
			let sb = sample else { return }
		if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0
		{
			let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
			CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
				Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
		}
		let d = display
		if d.status == .failed
		{
			d.flush()
			needKey = true
			onNeedKeyFrame?()
			return
		}
		d.enqueue(sb)
		lock.lock(); shown += 1; lock.unlock()
	}

	/** 139: згорнули — не показувати кадри; повернулись — чистий шар і чекаємо ключовий кадр.
	 *  Формат (SPS/PPS) лишаємо: приставка шле його лише на початку трансляції, без нього картинка була б чорною назавжди */
	var paused = false
	func resume()
	{
		paused = false
		needKey = true
		display.flush()
		if display.status == .failed { display.flushAndRemoveImage() }
	}

	/** Нове підключення: старий формат і кадри не потрібні */
	func reset()
	{
		format = nil; vps = nil; sps = nil; pps = nil; needKey = true; paused = false
		display.flushAndRemoveImage()
	}
}
