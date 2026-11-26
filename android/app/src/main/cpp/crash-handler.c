// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

// AnyPlay 118.2: запис падіння рідного коду у файл. Процес на телефоні власника (Galaxy S7) гинув без жодного сліду:
// застосунок не може читати системні записи падінь (tombstone), а logcat «chatty» стирав останні рядки. Тепер обробник
// сигналів (SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP) пише у файл назву сигналу, адресу, потік і стек викликів,
// а далі передає сигнал попередньому обробнику (системному), тож звичайний запис падіння теж лишається.
// Файл відкривається заздалегідь (у сигналі файл відкривати не можна), записи — лише write().

#include <jni.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
#include <unwind.h>

#include "chiaki-jni.h"

void anyplay_crash_install(const char *path);

#define FRAMES_MAX 48

static int crash_fd = -1;
static volatile int crash_in_progress = 0;
static const int crash_signals[] = { SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP };
#define CRASH_SIGNALS_COUNT (sizeof(crash_signals) / sizeof(crash_signals[0]))
static struct sigaction old_actions[CRASH_SIGNALS_COUNT];
static int installed = 0;

static void out_str(const char *s)
{
	if(crash_fd >= 0 && s)
	{
		ssize_t r = write(crash_fd, s, strlen(s));
		(void)r;
	}
}

static void out_hex(uintptr_t v)
{
	char buf[2 + sizeof(uintptr_t) * 2 + 1];
	int n = sizeof(buf) - 1;
	buf[n] = 0;
	do
	{
		int d = (int)(v & 0xf);
		buf[--n] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
		v >>= 4;
	} while(v && n > 2);
	buf[--n] = 'x';
	buf[--n] = '0';
	out_str(buf + n);
}

static void out_dec(long v)
{
	char buf[24];
	int n = sizeof(buf) - 1;
	buf[n] = 0;
	int neg = v < 0;
	unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
	do
	{
		buf[--n] = (char)('0' + u % 10);
		u /= 10;
	} while(u && n > 1);
	if(neg)
		buf[--n] = '-';
	out_str(buf + n);
}

static const char *signal_name(int sig)
{
	switch(sig)
	{
		case SIGSEGV: return "SIGSEGV (звернення до чужої пам'яті)";
		case SIGABRT: return "SIGABRT (abort)";
		case SIGBUS: return "SIGBUS";
		case SIGFPE: return "SIGFPE";
		case SIGILL: return "SIGILL";
		case SIGTRAP: return "SIGTRAP";
		default: return "?";
	}
}

typedef struct
{
	uintptr_t *frames;
	int count;
} BacktraceState;

static _Unwind_Reason_Code unwind_cb(struct _Unwind_Context *ctx, void *arg)
{
	BacktraceState *st = arg;
	uintptr_t pc = _Unwind_GetIP(ctx);
	if(pc)
	{
		if(st->count >= FRAMES_MAX)
			return _URC_END_OF_STACK;
		st->frames[st->count++] = pc;
	}
	return _URC_NO_REASON;
}

static void out_frame(int i, uintptr_t pc)
{
	out_str("  #");
	if(i < 10)
		out_str("0");
	out_dec(i);
	out_str(" pc ");
	Dl_info info;
	if(dladdr((void *)pc, &info) && info.dli_fname)
	{
		out_hex(pc - (uintptr_t)info.dli_fbase);
		out_str(" ");
		const char *name = strrchr(info.dli_fname, '/');
		out_str(name ? name + 1 : info.dli_fname);
		if(info.dli_sname)
		{
			out_str(" (");
			out_str(info.dli_sname);
			out_str("+");
			out_hex(pc - (uintptr_t)info.dli_saddr);
			out_str(")");
		}
	}
	else
		out_hex(pc);
	out_str("\n");
}

static void crash_handler(int sig, siginfo_t *info, void *ucontext)
{
	int idx = -1;
	for(size_t i = 0; i < CRASH_SIGNALS_COUNT; i++)
		if(crash_signals[i] == sig)
			idx = (int)i;

	if(!__sync_lock_test_and_set(&crash_in_progress, 1) && crash_fd >= 0)
	{
		struct timespec ts;
		clock_gettime(CLOCK_REALTIME, &ts);
		out_str("\n=== AnyPlay: рідний код упав: ");
		out_str(signal_name(sig));
		out_str(", code ");
		out_dec(info ? info->si_code : 0);
		out_str(", адреса ");
		out_hex(info ? (uintptr_t)info->si_addr : 0);
		out_str(", час unix ");
		out_dec((long)ts.tv_sec);
		out_str(", потік ");
		out_dec((long)syscall(__NR_gettid));
		char tname[20] = { 0 };
		if(prctl(PR_GET_NAME, (unsigned long)tname, 0, 0, 0) == 0)
		{
			out_str(" «");
			out_str(tname);
			out_str("»");
		}
		out_str(" ===\n");
#if defined(__aarch64__)
		if(ucontext)
		{
			const ucontext_t *uc = ucontext;
			out_str("pc ");
			out_frame(0, (uintptr_t)uc->uc_mcontext.pc);
			out_str("lr ");
			out_frame(0, (uintptr_t)uc->uc_mcontext.regs[30]);
		}
#endif
		uintptr_t frames[FRAMES_MAX];
		BacktraceState st = { frames, 0 };
		_Unwind_Backtrace(unwind_cb, &st);
		out_str("стек (з обробника сигналу):\n");
		for(int i = 0; i < st.count; i++)
			out_frame(i, frames[i]);
		fsync(crash_fd);
	}

	// далі — як було б без нас: попередній обробник (системний запис падіння) або типова дія
	if(idx >= 0)
		sigaction(sig, &old_actions[idx], NULL);
	else
		signal(sig, SIG_DFL);
	// сигнал, надісланий програмно (abort, kill), сам не повториться — надсилаємо знову; апаратний повториться,
	// щойно потік повернеться до тієї самої інструкції
	if(!info || info->si_code <= 0 || sig == SIGABRT)
		raise(sig);
}

/** Відкрити файл для записів падінь і (один раз) поставити обробник сигналів */
void anyplay_crash_install(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
	if(fd < 0)
		return;
	int old = crash_fd;
	crash_fd = fd;
	if(old >= 0)
		close(old);
	if(installed)
		return;
	installed = 1;
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sigemptyset(&sa.sa_mask);
	sa.sa_sigaction = crash_handler;
	sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
	for(size_t i = 0; i < CRASH_SIGNALS_COUNT; i++)
		sigaction(crash_signals[i], &sa, &old_actions[i]);
}

JNIEXPORT void JNICALL JNI_FCN(setCrashFile)(JNIEnv *env, jobject obj, jstring path_string)
{
	if(!path_string)
		return;
	const char *path = (*env)->GetStringUTFChars(env, path_string, NULL);
	if(!path)
		return;
	anyplay_crash_install(path);
	(*env)->ReleaseStringUTFChars(env, path_string, path);
}
