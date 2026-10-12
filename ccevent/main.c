/* ccevent — sends Camera Control events inside a vphone guest.
 *
 * Camera Control reports a TouchSensitiveButton event (type 0x2A) with a
 * ForceStage child (type 0x29). vphone guests have no Camera Control sensor,
 * so this builds the same events and dispatches them through the HID event
 * system. Every gesture runs in one process, so its timing is the button's.
 *
 *   0x2A: 0x2A0004 touching, 0x2A0006/0x2A0002 position x/y,
 *         0x2A0007/0x2A0003 delta x/y, 0x2A0008/9 radius (mm)
 *   0x29: 0x290000 stage, 0x290001 transition, 0x290005 force,
 *         0x290004/3/2 release, press and next thresholds
 *
 * Measured on iOS 26.6.2 and 27.0.1 guests. Needs iOS 26 or later
 * (IOHIDEventCreateTouchSensitiveButtonEvent).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
static IOHIDEventRef (*CreateButtonEvent)(CFAllocatorRef, uint64_t, uint16_t, uint16_t, double, double, Boolean, uint32_t);
extern IOHIDEventRef IOHIDEventCreate(CFAllocatorRef, uint32_t, uint64_t, uint32_t);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t, long);
extern void IOHIDEventSetDoubleValue(IOHIDEventRef, uint32_t, double);
extern void IOHIDEventSetPhase(IOHIDEventRef, uint16_t);
extern void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);

enum { BEGAN = 1, CHANGED = 2, ENDED = 4 };

static IOHIDEventSystemClientRef client;
static uint16_t page = 0, usage = 0;
static uint64_t sender = 0xDEFACEDBEEFFECE5ULL;
static int verbose = 0;
static double posY = 0.5;

static void send(int phase, int touching, double x, double y, double dx, double dy, long stage, long transition, double force) {
	uint64_t t = mach_absolute_time();
	IOHIDEventRef e = CreateButtonEvent(kCFAllocatorDefault, t, page, usage, x, y, touching, 0);
	if (!e) { fprintf(stderr, "could not create the event\n"); exit(2); }
	IOHIDEventSetIntegerValue(e, 0x2A0004, touching);
	IOHIDEventSetDoubleValue(e, 0x2A0006, x);  IOHIDEventSetDoubleValue(e, 0x2A0002, y);
	IOHIDEventSetDoubleValue(e, 0x2A0007, dx); IOHIDEventSetDoubleValue(e, 0x2A0003, dy);
	IOHIDEventSetDoubleValue(e, 0x2A0008, 4.0); IOHIDEventSetDoubleValue(e, 0x2A0009, 4.0);
	IOHIDEventRef f = IOHIDEventCreate(kCFAllocatorDefault, 0x29, t, 0);
	if (f) {
		IOHIDEventSetIntegerValue(f, 0x290000, stage); IOHIDEventSetIntegerValue(f, 0x290001, transition);
		IOHIDEventSetDoubleValue(f, 0x290005, force);  IOHIDEventSetDoubleValue(f, 0x290006, 0);
		IOHIDEventSetDoubleValue(f, 0x290004, 0.3); IOHIDEventSetDoubleValue(f, 0x290003, 0.6); IOHIDEventSetDoubleValue(f, 0x290002, 0.9);
		IOHIDEventAppendEvent(e, f, 0); CFRelease(f);
	}
	IOHIDEventSetPhase(e, (uint16_t)phase);
	IOHIDEventSetSenderID(e, sender);
	IOHIDEventSystemClientDispatchEvent(client, e);
	CFRelease(e);
	if (verbose) printf("phase=%d touch=%d x=%.2f y=%.2f dx=%.3f dy=%.3f stage=%ld transition=%ld force=%.2f\n", phase, touching, x, y, dx, dy, stage, transition, force);
}

static void ms(int n) { if (n > 0) usleep((useconds_t)n * 1000); }

/* Full press: touch, stage 4, release (the release keeps stage 4). */
static void click(int holdMs) {
	send(BEGAN, 1, 0.5, 0.5, 0, 0, 0, 0, 0.1); ms(40);
	send(CHANGED, 1, 0.5, 0.5, 0, 0, 4, 1, 1.0); ms(holdMs);
	send(ENDED, 0, 0.5, 0.5, 0, 0, 4, 2, 0.1);
}

/* Light press: touch, stage 1, stage 2, back to the light stage. */
static void lightDown(void) {
	posY = 0.5;
	send(BEGAN, 1, 0.5, posY, 0, 0, 0, 0, 0.1); ms(80);
	send(CHANGED, 1, 0.5, posY, 0, 0, 1, 1, 0.3); ms(80);
	send(CHANGED, 1, 0.5, posY, 0, 0, 2, 1, 0.6); ms(250);
	send(CHANGED, 1, 0.5, posY, 0, 0, 2, 2, 0.3); ms(300);
}

/* A second light press while still touching: opens the overlay menu. */
static void lightAgain(void) {
	send(CHANGED, 1, 0.5, posY, 0, 0, 2, 1, 0.6); ms(250);
	send(CHANGED, 1, 0.5, posY, 0, 0, 2, 2, 0.3); ms(300);
}

static void lightUp(void) {
	send(CHANGED, 1, 0.5, posY, 0, 0, 1, 2, 0.1); ms(50);
	send(ENDED, 0, 0.5, posY, 0, 0, 0, 0, 0.1);
}

/* Slide along the button (y axis) while touching at the light stage. */
static void slide(int steps, double dy, int stepMs) {
	for (int i = 0; i < steps; i++) {
		posY += dy; if (posY < 0) posY = 0; if (posY > 1) posY = 1;
		send(CHANGED, 1, 0.5, posY, 0, dy, 1, 0, 0.2); ms(stepMs);
	}
}

static int argInt(int argc, char **argv, int i, int fallback) { return i < argc ? atoi(argv[i]) : fallback; }
static double argDouble(int argc, char **argv, int i, double fallback) { return i < argc ? atof(argv[i]) : fallback; }

static void usage_(void) {
	fprintf(stderr,
		"ccevent — Camera Control events for vphone guests\n"
		"  ccevent click [hold_ms=120]            full press\n"
		"  ccevent double                         two full presses\n"
		"  ccevent hold [ms=1200]                 full press and hold\n"
		"  ccevent light [hold_ms=300]            light press\n"
		"  ccevent menu [hold_ms=1200]            double light press (overlay menu)\n"
		"  ccevent slide <steps> <dy> [ms=40]     light press, slide, release\n"
		"  ccevent menu-slide <steps> <dy> [ms=60]  menu, slide to another item, release\n"
		"  ccevent touch                          touch and lift, no press\n"
		"  ccevent swipe [distance=0.4]           swipe without pressing\n"
		"  ccevent raw <phase> <touch> <x> <y> <stage> [transition] [force] [dx] [dy]\n"
		"options before the command: -v (print events), -p <page> -u <usage> -s <senderID>\n"
		"dy < 0 slides up (raises a value), dy > 0 slides down.\n");
	exit(1);
}

int main(int argc, char **argv) {
	int a = 1;
	while (a < argc && argv[a][0] == '-') {
		if (!strcmp(argv[a], "-v")) { verbose = 1; a += 1; continue; }
		if (a + 1 >= argc) usage_();
		if (!strcmp(argv[a], "-p")) page = (uint16_t)strtoul(argv[a + 1], NULL, 0);
		else if (!strcmp(argv[a], "-u")) usage = (uint16_t)strtoul(argv[a + 1], NULL, 0);
		else if (!strcmp(argv[a], "-s")) sender = strtoull(argv[a + 1], NULL, 0);
		else usage_();
		a += 2;
	}
	if (a >= argc) usage_();
	CreateButtonEvent = dlsym(RTLD_DEFAULT, "IOHIDEventCreateTouchSensitiveButtonEvent");
	if (!CreateButtonEvent) { fprintf(stderr, "IOHIDEventCreateTouchSensitiveButtonEvent is missing (needs iOS 26 or later)\n"); return 3; }
	client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
	if (!client) { fprintf(stderr, "no IOHIDEventSystemClient (missing entitlements?)\n"); return 2; }

	const char *c = argv[a];
	if (!strcmp(c, "click")) {
		click(argInt(argc, argv, a + 1, 120));
	} else if (!strcmp(c, "double")) {
		click(80); ms(100); click(80);
	} else if (!strcmp(c, "hold")) {
		click(argInt(argc, argv, a + 1, 1200));
	} else if (!strcmp(c, "light")) {
		lightDown(); ms(argInt(argc, argv, a + 1, 300)); lightUp();
	} else if (!strcmp(c, "menu")) {
		lightDown(); lightAgain(); ms(argInt(argc, argv, a + 1, 1200)); lightUp();
	} else if (!strcmp(c, "slide")) {
		if (a + 2 >= argc) usage_();
		lightDown(); ms(400);
		slide(atoi(argv[a + 1]), atof(argv[a + 2]), argInt(argc, argv, a + 3, 40));
		ms(1000); lightUp();
	} else if (!strcmp(c, "menu-slide")) {
		if (a + 2 >= argc) usage_();
		lightDown(); lightAgain(); ms(600);
		slide(atoi(argv[a + 1]), atof(argv[a + 2]), argInt(argc, argv, a + 3, 60));
		ms(1000); lightUp();
	} else if (!strcmp(c, "touch")) {
		send(BEGAN, 1, 0.5, 0.5, 0, 0, 0, 0, 0.1); ms(150);
		send(ENDED, 0, 0.5, 0.5, 0, 0, 0, 0, 0.0);
	} else if (!strcmp(c, "swipe")) {
		double d = argDouble(argc, argv, a + 1, 0.4) / 10, x = 0.5;
		send(BEGAN, 1, x, 0.5, 0, 0, 0, 0, 0.1);
		for (int i = 0; i < 10; i++) { ms(30); x += d; send(CHANGED, 1, x, 0.5, d, 0, 0, 0, 0.1); }
		ms(30); send(ENDED, 0, x, 0.5, 0, 0, 0, 0, 0.0);
	} else if (!strcmp(c, "raw")) {
		if (a + 5 >= argc) usage_();
		send(atoi(argv[a + 1]), atoi(argv[a + 2]), atof(argv[a + 3]), atof(argv[a + 4]),
		     argDouble(argc, argv, a + 8, 0), argDouble(argc, argv, a + 9, 0), atol(argv[a + 5]),
		     a + 6 < argc ? atol(argv[a + 6]) : 0, argDouble(argc, argv, a + 7, 0.5));
	} else usage_();
	ms(50);
	return 0;
}
