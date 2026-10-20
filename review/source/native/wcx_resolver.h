#ifndef DSWR_WCX_RESOLVER_H
#define DSWR_WCX_RESOLVER_H
#include <stddef.h>
#include <stdint.h>

/* Observed independently in the supplied September and October 2026 EXEs.
 * Each function is resolved uniquely; there is no inter-function distance.
 * The prefixes also constrain the WorldComplete field layout used by callers.
 */
static const uint8_t WCX_INCREMENT_SIG[] = {
  0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x7c,0x24,0x10,
  0x8b,0x41,0x48,0x45,0x8b,0xd8,0x8b,0xda,0x3b,0x41,0x74
};
static const uint8_t WCX_CURRENT_SIG[] = {
  0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,
  0x48,0x89,0x7c,0x24,0x18,0x8b,0x41,0x48,0x41,0x0f,
  0xb6,0xf0,0x44,0x8b,0xda,0x3b,0x41,0x74
};
static const uint8_t WCX_TOTAL_SIG[] = {
  0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,
  0x48,0x89,0x7c,0x24,0x18,0x8b,0x81,0x98,0x00,0x00,
  0x00,0x41,0x0f,0xb6,0xf0,0x44,0x8b,0xda,0x3b,0x81,
  0xc4,0x00,0x00,0x00
};
typedef struct WcxTargets {
  size_t increment, current, total;
} WcxTargets;

static size_t wcx_find_unique(const uint8_t *data, size_t size,
                              const uint8_t *sig, size_t siglen) {
  size_t found = SIZE_MAX;
  if (!data || !sig || !siglen || size < siglen) return SIZE_MAX;
  for (size_t i = 0; i <= size - siglen; ++i) {
    if (data[i] != sig[0]) continue;
    size_t j = 1;
    while (j < siglen && data[i+j] == sig[j]) ++j;
    if (j != siglen) continue;
    if (found != SIZE_MAX) return SIZE_MAX;
    found = i;
  }
  return found;
}
static int wcx_resolve(const uint8_t *data, size_t size, WcxTargets *out) {
  WcxTargets t;
  t.increment = wcx_find_unique(data,size,WCX_INCREMENT_SIG,sizeof WCX_INCREMENT_SIG);
  t.current = wcx_find_unique(data,size,WCX_CURRENT_SIG,sizeof WCX_CURRENT_SIG);
  t.total = wcx_find_unique(data,size,WCX_TOTAL_SIG,sizeof WCX_TOTAL_SIG);
  if (t.increment == SIZE_MAX) return -4;
  if (t.current == SIZE_MAX || t.total == SIZE_MAX) return -5;
  if (out) *out = t;
  return 1;
}
#endif
