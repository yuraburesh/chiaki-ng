// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

/**
 * AnyPlay: when to ask the console for a new key (IDR) frame and which frames to hold back from
 * the decoder until it arrives.
 *
 * Why: HEVC P-frames from the PS5 often reference frames through the SPS reference picture set,
 * so the receiver cannot tell that a reference is missing. A lost or broken frame then makes the
 * decoder (especially D3D11VA/Vulkan/VideoToolbox, which do not clear missing references) paint
 * smeared colour wedges, and on a still screen (PS5 home) nothing replaces them for minutes,
 * because the console only sends a key frame when asked.
 *
 * Rules:
 *  - Start: nothing goes to the decoder until the first I-frame (the loading screen stays up).
 *    If the first frame is not an I-frame, an IDR is requested at once.
 *  - Any sign of corruption (FEC failure, missing frames, missing reference, decoder error,
 *    frame flagged corrupt) asks for an IDR. In "hard" mode P-frames are also held back until it
 *    arrives, so the last good picture stays on screen instead of garbage.
 *  - While the IDR has not arrived it is asked for again once per second.
 *  - Holding back never lasts forever: after a limit frames go through again (the request keeps
 *    repeating), so a console that is slow to answer can't freeze the picture.
 *
 * Pure logic without locking or I/O, so it can be unit tested; the caller locks and sends.
 */

#ifndef CHIAKI_IDRPOLICY_H
#define CHIAKI_IDRPOLICY_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CHIAKI_IDR_RETRY_MS 1000           // repeat an unanswered request this often
#define CHIAKI_IDR_MIN_GAP_MS 250          // never send two requests closer than this
#define CHIAKI_IDR_START_HOLD_MAX_MS 5000  // at the start hold P-frames back at most this long
#define CHIAKI_IDR_HOLD_MAX_MS 1000        // during play hold P-frames back at most this long
// AnyPlay 118.1 storm guard: a decoder that keeps rejecting frames (Galaxy S7 log: every key frame refused because
// the decoder had no input buffer) made the receiver ask every 250 ms, and the console answered with a key frame
// every 2-3 frames. After this many requests within the window the minimum gap becomes CHIAKI_IDR_STORM_GAP_MS.
#define CHIAKI_IDR_STORM_WINDOW_MS 4000
#define CHIAKI_IDR_STORM_REQUESTS 6
#define CHIAKI_IDR_STORM_GAP_MS 1500
// Reports of missing/corrupt frames to the console: the same broken range (same first frame) at most once per
// this interval, and at most CHIAKI_CORRUPT_REPORT_MAX_PER_S reports per second in total.
#define CHIAKI_CORRUPT_REPORT_REPEAT_MS 1000
#define CHIAKI_CORRUPT_REPORT_MAX_PER_S 8

typedef enum
{
	CHIAKI_IDR_FRAME_I = 0,
	CHIAKI_IDR_FRAME_P = 1,
	CHIAKI_IDR_FRAME_UNKNOWN = 2
} ChiakiIdrFrameType;

typedef struct chiaki_idr_policy_t
{
	bool seen_key;          // an I-frame has gone to the decoder since the stream started
	bool hold;              // P-frames are held back until an I-frame
	bool wanted;            // an IDR is wanted and has not arrived yet
	bool unsent;            // wanted, but the request was put off (too soon after the last one)
	uint64_t hold_since_ms; // 0 = start of the stream (set by the first frame)
	uint64_t last_request_ms;
	uint32_t requests;      // requests sent, including repeats
	uint32_t held_frames;   // frames held back in total
	uint64_t burst_start_ms;  // storm guard window start
	uint32_t burst_requests;  // requests in the current window
} ChiakiIdrPolicy;

/** AnyPlay 118.1: limit for "corrupt frame" reports to the console (see CHIAKI_CORRUPT_REPORT_*) */
typedef struct chiaki_corrupt_report_limit_t
{
	bool any;
	uint16_t from;          // first frame of the last reported range
	uint64_t last_ms;       // when it was reported
	uint64_t window_ms;     // start of the current one-second window
	uint32_t window_count;  // reports in it
	uint32_t suppressed;    // reports not sent (total)
} ChiakiCorruptReportLimit;

static inline void chiaki_corrupt_report_limit_init(ChiakiCorruptReportLimit *l)
{
	l->any = false;
	l->from = 0;
	l->last_ms = 0;
	l->window_ms = 0;
	l->window_count = 0;
	l->suppressed = 0;
}

/** @return true if the report for the range starting at `from` should be sent now */
static inline bool chiaki_corrupt_report_allow(ChiakiCorruptReportLimit *l, uint64_t now_ms, uint16_t from)
{
	if(!now_ms)
		now_ms = 1;
	if(l->any && from == l->from && now_ms - l->last_ms < CHIAKI_CORRUPT_REPORT_REPEAT_MS)
	{
		l->suppressed++;
		return false;   // the same break that is still growing: the console already knows
	}
	if(!l->window_ms || now_ms - l->window_ms >= 1000)
	{
		l->window_ms = now_ms;
		l->window_count = 0;
	}
	if(l->window_count >= CHIAKI_CORRUPT_REPORT_MAX_PER_S)
	{
		l->suppressed++;
		return false;
	}
	l->window_count++;
	l->any = true;
	l->from = from;
	l->last_ms = now_ms;
	return true;
}

static inline void chiaki_idr_policy_init(ChiakiIdrPolicy *p)
{
	p->seen_key = false;
	p->hold = true;
	p->wanted = false;
	p->unsent = false;
	p->hold_since_ms = 0;
	p->last_request_ms = 0;
	p->requests = 0;
	p->held_frames = 0;
	p->burst_start_ms = 0;
	p->burst_requests = 0;
}

static inline bool chiaki_idr_policy_request_due_(const ChiakiIdrPolicy *p, uint64_t now_ms, uint64_t gap_ms)
{
	// storm guard: many requests in a short time — ask less often (a normal loss sends one or two)
	if(p->burst_requests >= CHIAKI_IDR_STORM_REQUESTS && now_ms - p->burst_start_ms < CHIAKI_IDR_STORM_WINDOW_MS
		&& gap_ms < CHIAKI_IDR_STORM_GAP_MS)
		gap_ms = CHIAKI_IDR_STORM_GAP_MS;
	return p->last_request_ms == 0 || now_ms - p->last_request_ms >= gap_ms;
}

// a request put off by the minimum gap goes out as soon as the gap allows, a sent one is repeated once per second
static inline uint64_t chiaki_idr_policy_repeat_gap_(const ChiakiIdrPolicy *p)
{
	return p->unsent ? CHIAKI_IDR_MIN_GAP_MS : CHIAKI_IDR_RETRY_MS;
}

static inline void chiaki_idr_policy_mark_sent_(ChiakiIdrPolicy *p, uint64_t now_ms)
{
	if(!p->burst_start_ms || now_ms - p->burst_start_ms >= CHIAKI_IDR_STORM_WINDOW_MS)
	{
		p->burst_start_ms = now_ms ? now_ms : 1;
		p->burst_requests = 0;
	}
	p->burst_requests++;
	p->last_request_ms = now_ms ? now_ms : 1;
	p->requests++;
	p->unsent = false;
}

/**
 * A complete frame is about to go to the decoder.
 * @param send set to true when an IDR request should be sent now (the caller sends it)
 * @return true to pass the frame to the decoder, false to hold it back
 */
static inline bool chiaki_idr_policy_frame(ChiakiIdrPolicy *p, uint64_t now_ms, ChiakiIdrFrameType type, bool *send)
{
	*send = false;
	if(p->hold_since_ms == 0 && !p->seen_key)
		p->hold_since_ms = now_ms ? now_ms : 1;

	if(type == CHIAKI_IDR_FRAME_I)
	{
		p->seen_key = true;
		p->hold = false;
		p->wanted = false;
		p->unsent = false;
		return true;
	}

	if(p->hold)
	{
		const uint64_t limit = p->seen_key ? CHIAKI_IDR_HOLD_MAX_MS : CHIAKI_IDR_START_HOLD_MAX_MS;
		if(now_ms - p->hold_since_ms >= limit)
		{
			// the console did not answer in time: show what comes, keep asking
			p->hold = false;
			p->wanted = true;
		}
		else if(type == CHIAKI_IDR_FRAME_P)
		{
			// at the start the first frame should be the I-frame; anything else means it was lost
			if(!p->wanted)
			{
				p->wanted = true;
				p->unsent = true;
			}
			if(chiaki_idr_policy_request_due_(p, now_ms, chiaki_idr_policy_repeat_gap_(p)))
			{
				chiaki_idr_policy_mark_sent_(p, now_ms);
				*send = true;
			}
			p->held_frames++;
			return false;
		}
		else
		{
			// unknown type (could not be parsed): P-frames always parse, so this is most likely the key frame
			// packed differently; stop holding, and if it was not one, the repeated request still fixes it
			p->seen_key = true;
			p->hold = false;
		}
	}

	if(p->wanted && chiaki_idr_policy_request_due_(p, now_ms, chiaki_idr_policy_repeat_gap_(p)))
	{
		chiaki_idr_policy_mark_sent_(p, now_ms);
		*send = true;
	}
	return true;
}

/**
 * Something is broken in the picture (lost frame, FEC failure, decoder error...).
 * @param hold also hold P-frames back until the IDR (keeps the last good picture on screen)
 * @return true when an IDR request should be sent now (the caller sends it)
 */
static inline bool chiaki_idr_policy_corrupt(ChiakiIdrPolicy *p, uint64_t now_ms, bool hold)
{
	// a new hold only for a new break: while the last one is still unanswered the hold limit already ran out once
	if(hold && p->seen_key && !p->hold && !p->wanted)
	{
		p->hold = true;
		p->hold_since_ms = now_ms ? now_ms : 1;
	}
	if(p->wanted)
		return false;   // already asked: the per-second repeat in chiaki_idr_policy_frame takes care of it
	p->wanted = true;
	if(!chiaki_idr_policy_request_due_(p, now_ms, CHIAKI_IDR_MIN_GAP_MS))
	{
		p->unsent = true;
		return false;   // chiaki_idr_policy_frame sends it once the gap allows
	}
	chiaki_idr_policy_mark_sent_(p, now_ms);
	return true;
}

/**
 * An IDR request was sent by someone else (e.g. the user asked to fix the picture).
 */
static inline void chiaki_idr_policy_sent_externally(ChiakiIdrPolicy *p, uint64_t now_ms, bool hold)
{
	if(hold && p->seen_key && !p->hold)
	{
		p->hold = true;
		p->hold_since_ms = now_ms ? now_ms : 1;
	}
	p->wanted = true;
	chiaki_idr_policy_mark_sent_(p, now_ms);
}

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_IDRPOLICY_H
