#include "BoseDiagnosticsBridge.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/ucontext.h>
#include <unistd.h>

// Crash handling uses only bounded stack buffers and async-signal-safe write/fsync.
// Full symbolicated Swift backtraces must come from the iOS .ips report + dSYM.
static int appLogFD = -1;
static int crashLogFD = -1;
static volatile sig_atomic_t handlingSignal = 0;

static void writeAll(int fd, const char *buffer, size_t count) {
    if (fd < 0 || buffer == NULL || count == 0) return;
    while (count > 0) {
        ssize_t wrote = write(fd, buffer, count);
        if (wrote > 0) {
            buffer += wrote;
            count -= (size_t)wrote;
        } else if (wrote == -1 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    (void)fsync(fd);
}

typedef struct {
    char bytes[480];
    size_t used;
} CrashLine;

static void appendLiteral(CrashLine *line, const char *value) {
    while (*value && line->used < sizeof(line->bytes) - 1) {
        line->bytes[line->used++] = *value++;
    }
}

static void appendUnsigned(CrashLine *line, unsigned int number) {
    char digits[12];
    unsigned int count = 0;
    do {
        digits[count++] = (char)('0' + number % 10);
        number /= 10;
    } while (number && count < sizeof(digits));
    while (count > 0 && line->used < sizeof(line->bytes) - 1) {
        line->bytes[line->used++] = digits[--count];
    }
}

static void appendSigned(CrashLine *line, int number) {
    if (number < 0) {
        appendLiteral(line, "-");
        appendUnsigned(line, (unsigned int)(-(int64_t)number));
    } else {
        appendUnsigned(line, (unsigned int)number);
    }
}

static void appendHex(CrashLine *line, uintptr_t value) {
    static const char hex[] = "0123456789abcdef";
    appendLiteral(line, "0x");
    for (int shift = (int)(sizeof(uintptr_t) * 8) - 4; shift >= 0; shift -= 4) {
        if (line->used < sizeof(line->bytes) - 1) {
            line->bytes[line->used++] = hex[(value >> shift) & 15U];
        }
    }
}

static void fatalHandler(int signalNumber, siginfo_t *info, void *context) {
    if (handlingSignal) _exit(128 + signalNumber);
    handlingSignal = 1;

    CrashLine line = { .used = 0 };
    appendLiteral(&line, "\n[FATAL] signal=");
    appendUnsigned(&line, (unsigned int)signalNumber);
    if (signalNumber == SIGTRAP) appendLiteral(&line, " SIGTRAP (Swift trap / breakpoint)");
    if (signalNumber == SIGABRT) appendLiteral(&line, " SIGABRT");
    if (signalNumber == SIGSEGV) appendLiteral(&line, " SIGSEGV");
    if (signalNumber == SIGBUS) appendLiteral(&line, " SIGBUS");
    if (signalNumber == SIGILL) appendLiteral(&line, " SIGILL");
    if (signalNumber == SIGFPE) appendLiteral(&line, " SIGFPE");

    if (info) {
        appendLiteral(&line, " si_code=");
        appendSigned(&line, info->si_code);
        appendLiteral(&line, " faultAddress=");
        appendHex(&line, (uintptr_t)info->si_addr);
    }

#if defined(__arm64__)
    const ucontext_t *state = (const ucontext_t *)context;
    if (state && state->uc_mcontext) {
        appendLiteral(&line, " PC=");
        appendHex(&line, (uintptr_t)state->uc_mcontext->__ss.__pc);
        appendLiteral(&line, " LR=");
        appendHex(&line, (uintptr_t)state->uc_mcontext->__ss.__lr);
        appendLiteral(&line, " SP=");
        appendHex(&line, (uintptr_t)state->uc_mcontext->__ss.__sp);
    }
#endif
    appendLiteral(&line, "\n[HELP] Read Logs/last-stage.txt and the iOS .ips report for a symbolicated stack.\n");
    writeAll(crashLogFD, line.bytes, line.used);

    // SA_RESETHAND already restored the system default action.
    // Returning allows the OS's standard .ips crash-report collection.
}

void BoseDiagnosticsInstall(const char *applicationPath, const char *crashPath) {
    if (appLogFD >= 0) return;
    if (applicationPath) appLogFD = open(applicationPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (crashPath) crashLogFD = open(crashPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (crashLogFD < 0) return;

    const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE};
    struct sigaction action = {0};
    action.sa_sigaction = fatalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        (void)sigaction(signals[i], &action, NULL);
    }
}

void BoseDiagnosticsWrite(const char *text, size_t count) {
    writeAll(appLogFD, text, count);
}

void BoseDiagnosticsWriteCrash(const char *text, size_t count) {
    writeAll(crashLogFD, text, count);
}
