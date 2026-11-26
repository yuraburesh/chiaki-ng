// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <chiaki/videoreceiver.h>
#include <chiaki/time.h>
#include "../include/chiaki/session.h"

#include <string.h>

static ChiakiErrorCode chiaki_video_receiver_flush_frame(ChiakiVideoReceiver *video_receiver);

static void add_ref_frame(ChiakiVideoReceiver *video_receiver, int32_t frame)
{
	if(video_receiver->reference_frames[0] != -1)
	{
		memmove(&video_receiver->reference_frames[1], &video_receiver->reference_frames[0], sizeof(int32_t) * 15);
		video_receiver->reference_frames[0] = frame;
		return;
	}
	for(int i=15; i>=0; i--)
	{
		if(video_receiver->reference_frames[i] == -1)
		{
			video_receiver->reference_frames[i] = frame;
			return;
		}
	}
}

static bool have_ref_frame(ChiakiVideoReceiver *video_receiver, int32_t frame)
{
	for(int i=0; i<16; i++)
		if(video_receiver->reference_frames[i] == frame)
			return true;
	return false;
}

CHIAKI_EXPORT void chiaki_video_receiver_init(ChiakiVideoReceiver *video_receiver, struct chiaki_session_t *session, ChiakiPacketStats *packet_stats)
{
	video_receiver->session = session;
	video_receiver->log = session->log;
	memset(video_receiver->profiles, 0, sizeof(video_receiver->profiles));
	video_receiver->profiles_count = 0;
	video_receiver->profile_cur = -1;

	video_receiver->frame_index_cur = -1;
	video_receiver->frame_index_prev = -1;
	video_receiver->frame_index_prev_complete = 0;

	chiaki_frame_processor_init(&video_receiver->frame_processor, video_receiver->log);
	video_receiver->packet_stats = packet_stats;

	video_receiver->frames_lost = 0;
	video_receiver->frames_lost_total = 0;
	memset(video_receiver->reference_frames, -1, sizeof(video_receiver->reference_frames));
	chiaki_bitstream_init(&video_receiver->bitstream, video_receiver->log, video_receiver->session->connect_info.video_profile.codec);
	chiaki_mutex_init(&video_receiver->waiting_for_idr_mutex, false);
	video_receiver->waiting_for_idr = false;
	video_receiver->idr_request_last_ms = 0;
	chiaki_idr_policy_init(&video_receiver->idr);
	video_receiver->idr_wait_since_ms = 0;
	video_receiver->idr_requests_total = 0;
	video_receiver->decode_errors_total = 0;
	chiaki_corrupt_report_limit_init(&video_receiver->corrupt_reports);
	chiaki_mutex_init(&video_receiver->frames_lost_mutex, false);
}

CHIAKI_EXPORT void chiaki_video_receiver_fini(ChiakiVideoReceiver *video_receiver)
{
	for(size_t i=0; i<video_receiver->profiles_count; i++)
		free(video_receiver->profiles[i].header);
	chiaki_mutex_fini(&video_receiver->waiting_for_idr_mutex);
	chiaki_mutex_fini(&video_receiver->frames_lost_mutex);
	chiaki_frame_processor_fini(&video_receiver->frame_processor);
}

// AnyPlay: sends a key frame request the IDR policy decided on (outside the lock)
static void video_receiver_send_idr(ChiakiVideoReceiver *video_receiver, const char *reason, int32_t frame_index)
{
	ChiakiErrorCode err = stream_connection_send_idr_request(&video_receiver->session->stream_connection);
	chiaki_mutex_lock(&video_receiver->waiting_for_idr_mutex);
	video_receiver->idr_requests_total++;
	uint32_t n = video_receiver->idr_requests_total;
	uint64_t now_ms = chiaki_time_now_monotonic_ms();
	if(!video_receiver->idr_wait_since_ms)
		video_receiver->idr_wait_since_ms = now_ms;
	uint64_t waiting_ms = now_ms - video_receiver->idr_wait_since_ms;
	bool hold = video_receiver->idr.hold;
	chiaki_mutex_unlock(&video_receiver->waiting_for_idr_mutex);
	if(err == CHIAKI_ERR_SUCCESS)
		CHIAKI_LOGI(video_receiver->log, "[anyplay-video] key frame requested #%u reason=%s frame=%d waiting_ms=%llu hold=%d",
				(unsigned)n, reason, (int)frame_index, (unsigned long long)waiting_ms, hold ? 1 : 0);
	else
		CHIAKI_LOGW(video_receiver->log, "[anyplay-video] key frame request #%u could not be sent: %s (reason=%s, will retry)",
				(unsigned)n, chiaki_error_string(err), reason);
}

// AnyPlay: something in the picture is broken; ask for a key frame (the policy limits how often)
static void video_receiver_corrupt(ChiakiVideoReceiver *video_receiver, const char *reason, int32_t frame_index, bool decoder_error)
{
	const bool hold = video_receiver->session->connect_info.enable_idr_on_fec_failure;
	chiaki_mutex_lock(&video_receiver->waiting_for_idr_mutex);
	if(decoder_error)
		video_receiver->decode_errors_total++;
	const bool was_wanted = video_receiver->idr.wanted;
	const uint64_t now_ms = chiaki_time_now_monotonic_ms();
	const bool send = chiaki_idr_policy_corrupt(&video_receiver->idr, now_ms, hold);
	if(!was_wanted)
		video_receiver->idr_wait_since_ms = now_ms;
	chiaki_mutex_unlock(&video_receiver->waiting_for_idr_mutex);
	if(send)
		video_receiver_send_idr(video_receiver, reason, frame_index);
	else if(!was_wanted)
		CHIAKI_LOGI(video_receiver->log, "[anyplay-video] picture broken (reason=%s frame=%d), key frame request follows shortly", reason, (int)frame_index);
}

CHIAKI_EXPORT void chiaki_video_receiver_report_corrupt(ChiakiVideoReceiver *video_receiver, const char *reason, bool decoder_error)
{
	if(!video_receiver)
		return;
	video_receiver_corrupt(video_receiver, reason ? reason : "decoder", video_receiver->frame_index_cur, decoder_error);
}

CHIAKI_EXPORT uint32_t chiaki_video_receiver_get_idr_requests_total(ChiakiVideoReceiver *video_receiver)
{
	chiaki_mutex_lock(&video_receiver->waiting_for_idr_mutex);
	uint32_t r = video_receiver->idr_requests_total;
	chiaki_mutex_unlock(&video_receiver->waiting_for_idr_mutex);
	return r;
}

CHIAKI_EXPORT uint32_t chiaki_video_receiver_get_decode_errors_total(ChiakiVideoReceiver *video_receiver)
{
	chiaki_mutex_lock(&video_receiver->waiting_for_idr_mutex);
	uint32_t r = video_receiver->decode_errors_total;
	chiaki_mutex_unlock(&video_receiver->waiting_for_idr_mutex);
	return r;
}

/**
 * Someone else has just sent an IDR request (StreamSession::RequestIDR): hold P-frames back until it comes.
 * Passing false is kept for compatibility and only drops the hold.
 */
CHIAKI_EXPORT void chiaki_video_receiver_set_waiting_for_idr(ChiakiVideoReceiver *video_receiver, bool waiting_for_idr)
{
	chiaki_mutex_lock(&video_receiver->waiting_for_idr_mutex);
	const uint64_t now_ms = chiaki_time_now_monotonic_ms();
	if(waiting_for_idr)
	{
		if(!video_receiver->idr.wanted)
			video_receiver->idr_wait_since_ms = now_ms;
		chiaki_idr_policy_sent_externally(&video_receiver->idr, now_ms, true);
		video_receiver->idr_requests_total++;
	}
	else
		video_receiver->idr.hold = false;
	chiaki_mutex_unlock(&video_receiver->waiting_for_idr_mutex);
}

CHIAKI_EXPORT bool chiaki_video_receiver_get_waiting_for_idr(ChiakiVideoReceiver *video_receiver)
{
	chiaki_mutex_lock(&video_receiver->waiting_for_idr_mutex);
	bool waiting_for_idr = video_receiver->idr.wanted || video_receiver->idr.hold;
	chiaki_mutex_unlock(&video_receiver->waiting_for_idr_mutex);
	return waiting_for_idr;
}

CHIAKI_EXPORT int32_t chiaki_video_receiver_get_frames_lost_total(ChiakiVideoReceiver *video_receiver)
{
	int32_t total;
	chiaki_mutex_lock(&video_receiver->frames_lost_mutex);
	total = video_receiver->frames_lost_total;
	chiaki_mutex_unlock(&video_receiver->frames_lost_mutex);
	return total;
}

CHIAKI_EXPORT void chiaki_video_receiver_stream_info(ChiakiVideoReceiver *video_receiver, ChiakiVideoProfile *profiles, size_t profiles_count)
{
	if(video_receiver->profiles_count > 0)
	{
		CHIAKI_LOGE(video_receiver->log, "Video Receiver profiles already set");
		return;
	}

	memcpy(video_receiver->profiles, profiles, profiles_count * sizeof(ChiakiVideoProfile));
	video_receiver->profiles_count = profiles_count;

	CHIAKI_LOGI(video_receiver->log, "Video Profiles:");
	for(size_t i=0; i<video_receiver->profiles_count; i++)
	{
		ChiakiVideoProfile *profile = &video_receiver->profiles[i];
		CHIAKI_LOGI(video_receiver->log, "  %zu: %ux%u", i, profile->width, profile->height);
		//chiaki_log_hexdump(video_receiver->log, CHIAKI_LOG_DEBUG, profile->header, profile->header_sz);
	}
}

CHIAKI_EXPORT void chiaki_video_receiver_av_packet(ChiakiVideoReceiver *video_receiver, ChiakiTakionAVPacket *packet)
{
	// old frame?
	ChiakiSeqNum16 frame_index = packet->frame_index;
	ChiakiErrorCode err = CHIAKI_ERR_SUCCESS;
	if(video_receiver->frame_index_cur >= 0
		&& chiaki_seq_num_16_lt(frame_index, (ChiakiSeqNum16)video_receiver->frame_index_cur))
	{
		CHIAKI_LOGW(video_receiver->log, "Video Receiver received old frame packet");
		return;
	}

	// check adaptive stream index
	if(video_receiver->profile_cur < 0 || video_receiver->profile_cur != packet->adaptive_stream_index)
	{
		if(packet->adaptive_stream_index >= video_receiver->profiles_count)
		{
			CHIAKI_LOGE(video_receiver->log, "Packet has invalid adaptive stream index %u >= %u",
					(unsigned int)packet->adaptive_stream_index,
					(unsigned int)video_receiver->profiles_count);
			return;
		}
		video_receiver->profile_cur = packet->adaptive_stream_index;

		ChiakiVideoProfile *profile = video_receiver->profiles + video_receiver->profile_cur;
		CHIAKI_LOGI(video_receiver->log, "Switched to profile %d, resolution: %ux%u", video_receiver->profile_cur, profile->width, profile->height);
		if(video_receiver->session->video_sample_cb)
			video_receiver->session->video_sample_cb(profile->header, profile->header_sz, 0, false, video_receiver->session->video_sample_cb_user);
		if(!chiaki_bitstream_header(&video_receiver->bitstream, profile->header, profile->header_sz))
			CHIAKI_LOGW(video_receiver->log, "Failed to parse video header");
	}

	// next frame?
	if(video_receiver->frame_index_cur < 0 ||
		chiaki_seq_num_16_gt(frame_index, (ChiakiSeqNum16)video_receiver->frame_index_cur))
	{
		if(video_receiver->packet_stats)
			chiaki_frame_processor_report_packet_stats(&video_receiver->frame_processor, video_receiver->packet_stats);

		// last frame not flushed yet?
		if(video_receiver->frame_index_cur >= 0 && video_receiver->frame_index_prev != video_receiver->frame_index_cur)
			err = chiaki_video_receiver_flush_frame(video_receiver);

		if(err != CHIAKI_ERR_SUCCESS)
			CHIAKI_LOGW(video_receiver->log, "Video receiver could not flush frame.");

		ChiakiSeqNum16 next_frame_expected = (ChiakiSeqNum16)(video_receiver->frame_index_prev_complete + 1);
		if(chiaki_seq_num_16_gt(frame_index, next_frame_expected)
			&& !(frame_index == 1 && video_receiver->frame_index_cur < 0)) // ok for frame 1
		{
			// AnyPlay 118.1: the same growing range is reported (and logged) at most once per second
			if(chiaki_corrupt_report_allow(&video_receiver->corrupt_reports, chiaki_time_now_monotonic_ms(), next_frame_expected))
			{
				CHIAKI_LOGW(video_receiver->log, "Detected missing or corrupt frame(s) from %d to %d%s", next_frame_expected, (int)frame_index,
						video_receiver->corrupt_reports.suppressed ? " (repeats limited)" : "");
				err = stream_connection_send_corrupt_frame(&video_receiver->session->stream_connection, next_frame_expected, frame_index - 1);
				if(err != CHIAKI_ERR_SUCCESS)
					CHIAKI_LOGW(video_receiver->log, "Error sending corrupt frame.");
			}
			// AnyPlay: the frames after the gap may reference the lost ones
			video_receiver_corrupt(video_receiver, "missing_frames", frame_index, false);
		}

		video_receiver->frame_index_cur = frame_index;
		err = chiaki_frame_processor_alloc_frame(&video_receiver->frame_processor, packet);
		if(err != CHIAKI_ERR_SUCCESS)
			CHIAKI_LOGW(video_receiver->log, "Video receiver could not allocate frame for packet.");
	}

	err = chiaki_frame_processor_put_unit(&video_receiver->frame_processor, packet);
	if(err != CHIAKI_ERR_SUCCESS)
		CHIAKI_LOGW(video_receiver->log, "Video receiver could not put unit.");

	// if we are currently building up a frame
	if(video_receiver->frame_index_cur != video_receiver->frame_index_prev)
	{
		// if we already have enough for the whole frame, flush it already
		if(chiaki_frame_processor_flush_possible(&video_receiver->frame_processor) || packet->unit_index == packet->units_in_frame_total - 1)
			err = chiaki_video_receiver_flush_frame(video_receiver);
		if(err != CHIAKI_ERR_SUCCESS)
			CHIAKI_LOGW(video_receiver->log, "Video receiver could not flush frame.");
	}
}

static ChiakiErrorCode chiaki_video_receiver_flush_frame(ChiakiVideoReceiver *video_receiver)
{
	uint8_t *frame;
	size_t frame_size;
	ChiakiFrameProcessorFlushResult flush_result = chiaki_frame_processor_flush(&video_receiver->frame_processor, &frame, &frame_size);

	if(flush_result == CHIAKI_FRAME_PROCESSOR_FLUSH_RESULT_FAILED
		|| flush_result == CHIAKI_FRAME_PROCESSOR_FLUSH_RESULT_FEC_FAILED)
	{
		if (flush_result == CHIAKI_FRAME_PROCESSOR_FLUSH_RESULT_FEC_FAILED)
		{
			ChiakiSeqNum16 next_frame_expected = (ChiakiSeqNum16)(video_receiver->frame_index_prev_complete + 1);
			if(chiaki_corrupt_report_allow(&video_receiver->corrupt_reports, chiaki_time_now_monotonic_ms(), next_frame_expected))
				stream_connection_send_corrupt_frame(&video_receiver->session->stream_connection, next_frame_expected, video_receiver->frame_index_cur);
			// AnyPlay: a lost frame always asks for a key frame (before 115 only with the "IDR on FEC failure"
			// setting, so on a still screen the broken picture stayed for minutes); the setting now means
			// "hold the last good picture until the key frame comes" instead of showing broken frames
			video_receiver_corrupt(video_receiver, "fec_failure", video_receiver->frame_index_cur, false);
			ChiakiEvent event = { 0 };
			event.type = CHIAKI_EVENT_VIDEO_FEC_FAILURE;
			event.video_fec_failure.frame_index = video_receiver->frame_index_cur;
			event.video_fec_failure.idr_request_sent = true; // the receiver keeps asking until it comes
			chiaki_session_send_event(video_receiver->session, &event);
			int32_t lost = video_receiver->frame_index_cur - next_frame_expected + 1;
			chiaki_mutex_lock(&video_receiver->frames_lost_mutex);
			video_receiver->frames_lost += lost;
			video_receiver->frames_lost_total += lost;
			chiaki_mutex_unlock(&video_receiver->frames_lost_mutex);
			video_receiver->frame_index_prev = video_receiver->frame_index_cur;
		}
		else
			video_receiver_corrupt(video_receiver, "incomplete_frame", video_receiver->frame_index_cur, false);
		CHIAKI_LOGW(video_receiver->log, "Failed to complete frame %d", (int)video_receiver->frame_index_cur);
		return CHIAKI_ERR_UNKNOWN;
	}

	bool succ = flush_result != CHIAKI_FRAME_PROCESSOR_FLUSH_RESULT_FEC_FAILED;
	bool recovered = false;

	ChiakiBitstreamSlice slice;
	bool slice_ok = chiaki_bitstream_slice(&video_receiver->bitstream, frame, frame_size, &slice);
	ChiakiIdrFrameType frame_type = CHIAKI_IDR_FRAME_UNKNOWN;
	if(slice_ok && slice.slice_type == CHIAKI_BITSTREAM_SLICE_I)
		frame_type = CHIAKI_IDR_FRAME_I;
	else if(slice_ok && slice.slice_type == CHIAKI_BITSTREAM_SLICE_P)
		frame_type = CHIAKI_IDR_FRAME_P;

	// AnyPlay: hold frames back until the key frame (start of the stream, or after a break in hold mode)
	{
		bool send_idr = false;
		chiaki_mutex_lock(&video_receiver->waiting_for_idr_mutex);
		const bool was_wanted = video_receiver->idr.wanted;
		const bool was_seen_key = video_receiver->idr.seen_key;
		const uint64_t now_ms = chiaki_time_now_monotonic_ms();
		const bool pass = chiaki_idr_policy_frame(&video_receiver->idr, now_ms, frame_type, &send_idr);
		const uint64_t waited_ms = video_receiver->idr_wait_since_ms ? now_ms - video_receiver->idr_wait_since_ms : 0;
		const uint32_t held_frames = video_receiver->idr.held_frames;
		const bool key_arrived = frame_type == CHIAKI_IDR_FRAME_I && (was_wanted || !was_seen_key);
		if(key_arrived)
			video_receiver->idr_wait_since_ms = 0;
		chiaki_mutex_unlock(&video_receiver->waiting_for_idr_mutex);
		if(key_arrived)
			CHIAKI_LOGI(video_receiver->log, "[anyplay-video] key frame %d arrived%s, waited_ms=%llu, held_frames_total=%u",
					(int)video_receiver->frame_index_cur, was_seen_key ? "" : " (start of stream)",
					(unsigned long long)waited_ms, (unsigned)held_frames);
		if(send_idr)
			video_receiver_send_idr(video_receiver, was_seen_key ? "still_broken" : "no_key_frame_at_start", video_receiver->frame_index_cur);
		if(!pass)
		{
			CHIAKI_LOGV(video_receiver->log, "Skipping P-frame %d while waiting for IDR", (int)video_receiver->frame_index_cur);
			video_receiver->frame_index_prev = video_receiver->frame_index_cur;
			return CHIAKI_ERR_SUCCESS;
		}
	}

	if(slice_ok && slice.slice_type == CHIAKI_BITSTREAM_SLICE_P)
	{
		ChiakiSeqNum16 ref_frame_index = video_receiver->frame_index_cur - slice.reference_frame - 1;
		if(slice.reference_frame != 0xff && !have_ref_frame(video_receiver, ref_frame_index))
		{
			for(unsigned i=slice.reference_frame+1; i<16; i++)
			{
				ChiakiSeqNum16 ref_frame_index_new = video_receiver->frame_index_cur - i - 1;
				if(have_ref_frame(video_receiver, ref_frame_index_new))
				{
					if(chiaki_bitstream_slice_set_reference_frame(&video_receiver->bitstream, frame, frame_size, i))
					{
						recovered = true;
						CHIAKI_LOGW(video_receiver->log, "Missing reference frame %d for decoding frame %d -> changed to %d", (int)ref_frame_index, (int)video_receiver->frame_index_cur, (int)ref_frame_index_new);
					}
					break;
				}
			}
			if(!recovered)
			{
				succ = false;
				chiaki_mutex_lock(&video_receiver->frames_lost_mutex);
				video_receiver->frames_lost++;
				video_receiver->frames_lost_total++;
				chiaki_mutex_unlock(&video_receiver->frames_lost_mutex);
				CHIAKI_LOGW(video_receiver->log, "Missing reference frame %d for decoding frame %d", (int)ref_frame_index, (int)video_receiver->frame_index_cur);
			}
			// AnyPlay: an older reference only approximates the picture; a key frame makes it right again
			video_receiver_corrupt(video_receiver, recovered ? "reference_replaced" : "reference_missing", video_receiver->frame_index_cur, false);
		}
	}

	if(succ && video_receiver->session->video_sample_cb)
	{
		bool cb_succ = video_receiver->session->video_sample_cb(frame, frame_size, video_receiver->frames_lost, recovered, video_receiver->session->video_sample_cb_user);
		chiaki_mutex_lock(&video_receiver->frames_lost_mutex);
		video_receiver->frames_lost = 0;
		chiaki_mutex_unlock(&video_receiver->frames_lost_mutex);
		if(!cb_succ)
		{
			succ = false;
			CHIAKI_LOGW(video_receiver->log, "Video callback did not process frame successfully.");
			// AnyPlay: the decoder refused the frame (broken data, hardware decoder reset): its state is unknown now
			video_receiver_corrupt(video_receiver, "decoder_rejected_frame", video_receiver->frame_index_cur, true);
		}
		else
		{
			add_ref_frame(video_receiver, video_receiver->frame_index_cur);
			CHIAKI_LOGV(video_receiver->log, "Added reference %c frame %d", frame_type == CHIAKI_IDR_FRAME_I ? 'I' : 'P', (int)video_receiver->frame_index_cur);
		}
	}

	video_receiver->frame_index_prev = video_receiver->frame_index_cur;

	if(succ)
		video_receiver->frame_index_prev_complete = video_receiver->frame_index_cur;

	return CHIAKI_ERR_SUCCESS;
}
