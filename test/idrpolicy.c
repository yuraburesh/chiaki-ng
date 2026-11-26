// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

// AnyPlay 115: when the receiver asks for a key frame and which frames it holds back (chiaki/idrpolicy.h),
// and that the slice parser recognises key frames packed with parameter sets or labelled IDR_W_RADL.

#include <munit.h>

#include <chiaki/idrpolicy.h>
#include <chiaki/bitstream.h>
#include <string.h>

#define ARRAY_SIZE(a) sizeof(a) / sizeof(a[0])

static bool frame(ChiakiIdrPolicy *p, uint64_t t, ChiakiIdrFrameType type, bool *send)
{
	return chiaki_idr_policy_frame(p, t, type, send);
}

static MunitResult test_idr_start_clean(const MunitParameter params[], void *fixture)
{
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	munit_assert(frame(&p, 1000, CHIAKI_IDR_FRAME_I, &send));
	munit_assert(!send);
	for(uint64_t t = 1016; t < 3000; t += 16)
	{
		munit_assert(frame(&p, t, CHIAKI_IDR_FRAME_P, &send));
		munit_assert(!send);
	}
	munit_assert_uint32(p.requests, ==, 0);
	return MUNIT_OK;
}

static MunitResult test_idr_start_key_lost(const MunitParameter params[], void *fixture)
{
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	// the first key frame was lost: P-frames are held back and an IDR is asked for at once
	munit_assert(!frame(&p, 1000, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(send);
	munit_assert(!frame(&p, 1016, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!send);
	munit_assert(!frame(&p, 1990, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!send);
	// no answer within a second: asked again
	munit_assert(!frame(&p, 2000, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(send);
	munit_assert_uint32(p.requests, ==, 2);
	// the key frame comes: it and everything after it go to the decoder
	munit_assert(frame(&p, 2100, CHIAKI_IDR_FRAME_I, &send));
	munit_assert(!send);
	munit_assert(!p.wanted);
	munit_assert(frame(&p, 2116, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!send);
	munit_assert(frame(&p, 4000, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!send);
	munit_assert_uint32(p.held_frames, ==, 4);
	return MUNIT_OK;
}

static MunitResult test_idr_start_hold_limit(const MunitParameter params[], void *fixture)
{
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	munit_assert(!frame(&p, 1000, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!frame(&p, 5999, CHIAKI_IDR_FRAME_P, &send));
	// the console never answered: after 5 s frames go through, the request keeps repeating
	munit_assert(frame(&p, 6000, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(p.wanted);
	munit_assert(frame(&p, 7000, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(send);
	return MUNIT_OK;
}

static MunitResult test_idr_start_unknown(const MunitParameter params[], void *fixture)
{
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	// a frame that could not be parsed at the start is taken for the key frame
	munit_assert(frame(&p, 1000, CHIAKI_IDR_FRAME_UNKNOWN, &send));
	munit_assert(!send);
	munit_assert(frame(&p, 1016, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!send);
	return MUNIT_OK;
}

static MunitResult test_idr_corrupt_soft(const MunitParameter params[], void *fixture)
{
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	munit_assert(frame(&p, 1000, CHIAKI_IDR_FRAME_I, &send));
	// a lost frame mid-game (soft mode): ask at once, frames keep going to the decoder
	munit_assert(chiaki_idr_policy_corrupt(&p, 5000, false));
	munit_assert(!chiaki_idr_policy_corrupt(&p, 5010, false));   // the same break, already asked
	munit_assert(frame(&p, 5016, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!send);
	munit_assert(frame(&p, 6000, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(send);   // repeated after a second
	munit_assert(frame(&p, 6100, CHIAKI_IDR_FRAME_I, &send));
	munit_assert(!p.wanted);
	// a new break 150 ms after the last request: put off until 250 ms have passed, then sent with the next frame
	munit_assert(!chiaki_idr_policy_corrupt(&p, 6150, false));
	munit_assert(p.wanted);
	munit_assert(frame(&p, 6200, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!send);
	munit_assert(frame(&p, 6250, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(send);
	munit_assert_uint32(p.requests, ==, 3);
	return MUNIT_OK;
}

static MunitResult test_idr_corrupt_hold(const MunitParameter params[], void *fixture)
{
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	munit_assert(frame(&p, 1000, CHIAKI_IDR_FRAME_I, &send));
	// hold mode: the last good picture stays until the key frame
	munit_assert(chiaki_idr_policy_corrupt(&p, 5000, true));
	munit_assert(!frame(&p, 5016, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!frame(&p, 5500, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(frame(&p, 5600, CHIAKI_IDR_FRAME_I, &send));
	munit_assert(frame(&p, 5616, CHIAKI_IDR_FRAME_P, &send));
	// the console does not answer: after 1 s frames go through, the request repeats
	munit_assert(chiaki_idr_policy_corrupt(&p, 8000, true));
	munit_assert(!frame(&p, 8999, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(frame(&p, 9000, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(send);
	// more breaks while still waiting don't start a new hold
	munit_assert(!chiaki_idr_policy_corrupt(&p, 9100, true));
	munit_assert(frame(&p, 9116, CHIAKI_IDR_FRAME_P, &send));
	return MUNIT_OK;
}

static MunitResult test_idr_external(const MunitParameter params[], void *fixture)
{
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	munit_assert(frame(&p, 1000, CHIAKI_IDR_FRAME_I, &send));
	chiaki_idr_policy_sent_externally(&p, 2000, true);
	munit_assert(!frame(&p, 2016, CHIAKI_IDR_FRAME_P, &send));
	munit_assert(!send);
	munit_assert(frame(&p, 2100, CHIAKI_IDR_FRAME_I, &send));
	munit_assert(!p.wanted && !p.hold);
	return MUNIT_OK;
}

// AnyPlay 118.1: a decoder that refuses every key frame (Galaxy S7 log) made the receiver ask every 250 ms
static uint32_t storm_requests(bool guard)
{
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	frame(&p, 1000, CHIAKI_IDR_FRAME_I, &send);
	uint32_t sent = 0;
	// the decoder rejects every frame for 4 s (each rejection is a new break), the console sends a key frame every 3rd
	for(uint64_t t = 2000; t < 6000; t += 16)
	{
		if(!guard)
			p.burst_requests = 0;
		if(chiaki_idr_policy_corrupt(&p, t, true))
			sent++;
		if(!guard)
			p.burst_requests = 0;
		if(frame(&p, t + 8, (t / 16) % 3 ? CHIAKI_IDR_FRAME_P : CHIAKI_IDR_FRAME_I, &send) && send)
			sent++;
		else if(send)
			sent++;
	}
	return sent;
}

// AnyPlay 118.1: a decoder that refuses every frame (Galaxy S7 log) made the receiver ask every 250 ms
static MunitResult test_idr_storm_guard(const MunitParameter params[], void *fixture)
{
	uint32_t without = storm_requests(false);
	uint32_t with = storm_requests(true);
	munit_logf(MUNIT_LOG_INFO, "requests in 4 s: %u without the guard, %u with it", without, with);
	munit_assert_uint32(without, >=, 15);
	// first CHIAKI_IDR_STORM_REQUESTS as before, then one per 1.5 s
	munit_assert_uint32(with, <=, CHIAKI_IDR_STORM_REQUESTS + 3);
	// a normal loss later (new window) is answered at once again
	ChiakiIdrPolicy p;
	bool send;
	chiaki_idr_policy_init(&p);
	munit_assert(frame(&p, 1000, CHIAKI_IDR_FRAME_I, &send));
	munit_assert(chiaki_idr_policy_corrupt(&p, 20000, false));
	return MUNIT_OK;
}

static MunitResult test_corrupt_report_limit(const MunitParameter params[], void *fixture)
{
	ChiakiCorruptReportLimit l;
	chiaki_corrupt_report_limit_init(&l);
	munit_assert(chiaki_corrupt_report_allow(&l, 1000, 2849));
	// the same growing range every frame: once per second
	uint32_t n = 1;
	for(uint64_t t = 1016; t < 3000; t += 16)
		if(chiaki_corrupt_report_allow(&l, t, 2849))
			n++;
	munit_assert_uint32(n, ==, 2);
	// a new break is reported at once
	munit_assert(chiaki_corrupt_report_allow(&l, 3005, 3100));
	// many different breaks in one second: at most 8
	chiaki_corrupt_report_limit_init(&l);
	n = 0;
	for(uint16_t i = 0; i < 30; i++)
		if(chiaki_corrupt_report_allow(&l, 5000 + i * 10, (uint16_t)(100 + i * 5)))
			n++;
	munit_assert_uint32(n, ==, CHIAKI_CORRUPT_REPORT_MAX_PER_S);
	return MUNIT_OK;
}

static const uint8_t h265_header[] = {
	0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00,
	0xb0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x96, 0x0a, 0xc0, 0x90, 0x00, 0x00, 0x00, 0x01,
	0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xb0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
	0x00, 0x96, 0xa0, 0x03, 0xc0, 0x80, 0x11, 0x07, 0xcb, 0xc2, 0xb9, 0x24, 0x29, 0x52, 0x70, 0x16,
	0xa0, 0x20, 0x20, 0x20, 0x80, 0x00, 0x07, 0xd2, 0x00, 0x01, 0xd4, 0xc0, 0x20, 0xe5, 0xa1, 0xe3,
	0xd0, 0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xc0, 0xf3, 0xc0, 0x4c, 0x90,
};

static const uint8_t h265_slice_i[] = {
	0x00, 0x00, 0x00, 0x01, 0x28, 0x01, 0xac, 0x25, 0xcf, 0x83, 0xff, 0x23, 0x54, 0xab, 0x5c, 0xf5,
	0x7a, 0x06, 0x7c, 0x3f, 0x31, 0x9b, 0xe6, 0x10, 0x57, 0xe8, 0x0e, 0xcf, 0xdd, 0xda, 0xdb, 0x3f,
};

static const uint8_t h265_slice_p[] = {
	0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0xd7, 0x85, 0x6a, 0xae, 0xa6, 0x11, 0x80, 0x95, 0x80, 0x0a,
	0xec, 0x5e, 0xdf, 0x39, 0x86, 0xe6, 0xd9, 0x07, 0x49, 0x17, 0xe2, 0x62, 0x57, 0x14, 0xd7, 0x08,
};

static MunitResult test_bitstream_key_frame_packing(const MunitParameter params[], void *fixture)
{
	ChiakiBitstream bs;
	ChiakiBitstreamSlice slice;
	chiaki_bitstream_init(&bs, NULL, CHIAKI_CODEC_H265);
	munit_assert(chiaki_bitstream_header(&bs, (uint8_t *)h265_header, ARRAY_SIZE(h265_header)));

	// key frame with VPS/SPS/PPS in front of the slice
	uint8_t packed[ARRAY_SIZE(h265_header) + ARRAY_SIZE(h265_slice_i)];
	memcpy(packed, h265_header, ARRAY_SIZE(h265_header));
	memcpy(packed + ARRAY_SIZE(h265_header), h265_slice_i, ARRAY_SIZE(h265_slice_i));
	memset(&slice, -1, sizeof(slice));
	munit_assert(chiaki_bitstream_slice(&bs, packed, ARRAY_SIZE(packed), &slice));
	munit_assert(slice.slice_type == CHIAKI_BITSTREAM_SLICE_I);

	// the same with an access unit delimiter (NAL 35) and a 3-byte start code before the slice
	uint8_t aud[] = { 0x00, 0x00, 0x00, 0x01, 0x46, 0x01, 0x10, 0x00, 0x00, 0x01 };
	uint8_t packed2[ARRAY_SIZE(aud) + ARRAY_SIZE(h265_slice_i) - 4];
	memcpy(packed2, aud, ARRAY_SIZE(aud));
	memcpy(packed2 + ARRAY_SIZE(aud), h265_slice_i + 4, ARRAY_SIZE(h265_slice_i) - 4);
	memset(&slice, -1, sizeof(slice));
	munit_assert(chiaki_bitstream_slice(&bs, packed2, ARRAY_SIZE(packed2), &slice));
	munit_assert(slice.slice_type == CHIAKI_BITSTREAM_SLICE_I);

	// IDR_W_RADL (19) instead of IDR_N_LP (20): same slice header
	uint8_t radl[ARRAY_SIZE(h265_slice_i)];
	memcpy(radl, h265_slice_i, ARRAY_SIZE(radl));
	radl[4] = 19 << 1;
	memset(&slice, -1, sizeof(slice));
	munit_assert(chiaki_bitstream_slice(&bs, radl, ARRAY_SIZE(radl), &slice));
	munit_assert(slice.slice_type == CHIAKI_BITSTREAM_SLICE_I);

	// a plain P slice is unchanged (and the parser did not keep anything from the copies above)
	memset(&slice, -1, sizeof(slice));
	munit_assert(chiaki_bitstream_slice(&bs, (uint8_t *)h265_slice_p, ARRAY_SIZE(h265_slice_p), &slice));
	munit_assert(slice.slice_type == CHIAKI_BITSTREAM_SLICE_P);
	munit_assert(slice.reference_frame == 5);

	// only parameter sets, no slice: not a frame we can judge
	memset(&slice, -1, sizeof(slice));
	munit_assert(!chiaki_bitstream_slice(&bs, (uint8_t *)h265_header, ARRAY_SIZE(h265_header), &slice));
	return MUNIT_OK;
}

MunitTest tests_idrpolicy[] = {
	{ "/start_clean", test_idr_start_clean, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/start_key_lost", test_idr_start_key_lost, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/start_hold_limit", test_idr_start_hold_limit, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/start_unknown", test_idr_start_unknown, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/corrupt_soft", test_idr_corrupt_soft, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/corrupt_hold", test_idr_corrupt_hold, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/external", test_idr_external, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/storm_guard", test_idr_storm_guard, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/corrupt_report_limit", test_corrupt_report_limit, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/bitstream_key_frame_packing", test_bitstream_key_frame_packing, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL }
};
