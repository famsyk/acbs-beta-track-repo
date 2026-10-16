#ifndef BOSE_DIAGNOSTICS_BRIDGE_H
#define BOSE_DIAGNOSTICS_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void BoseDiagnosticsInstall(const char *applicationPath, const char *crashPath);
void BoseDiagnosticsWrite(const char *text, size_t count);
void BoseDiagnosticsWriteCrash(const char *text, size_t count);

#ifdef __cplusplus
}
#endif

#endif
