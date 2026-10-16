#include "BoseDiagnosticsBridge.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// The signal handler deliberately uses only async-signal-safe POSIX calls.
// No Swift, malloc, Objective-C, locks, or Foundation are invoked in a signal.
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

static void signalHandler(int number) {
    if (handlingSignal) _exit(128 + number);
    handlingSignal = 1;
    char message[] = "\n[FATAL SIGNAL] number=000\n";
    // signal numbers are normally < 100, but use three fixed digits.
    int numberValue = number < 0 ? 0 : number % 1000;
    message[23] = (char)('0' + (numberValue / 100) % 10);
    message[24] = (char)('0' + (numberValue / 10) % 10);
    message[25] = (char)('0' + numberValue % 10);
    writeAll(crashLogFD, message, sizeof(message) - 1);

    // Restore the default behavior so iOS can still produce its native crash report.
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    (void)sigaction(number, &action, NULL);
    (void)kill(getpid(), number);
    _exit(128 + number);
}

void BoseDiagnosticsInstall(const char *applicationPath, const char *crashPath) {
    if (appLogFD >= 0) return;
    if (applicationPath != NULL) {
        appLogFD = open(applicationPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    }
    if (crashPath != NULL) {
        crashLogFD = open(crashPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    }
    if (crashLogFD < 0) return;

    const int fatalSignals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = signalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESETHAND;
    for (size_t i = 0; i < sizeof(fatalSignals) / sizeof(fatalSignals[0]); i++) {
        (void)sigaction(fatalSignals[i], &action, NULL);
    }
}

void BoseDiagnosticsWrite(const char *text, size_t count) {
    writeAll(appLogFD, text, count);
}

void BoseDiagnosticsWriteCrash(const char *text, size_t count) {
    writeAll(crashLogFD, text, count);
}
