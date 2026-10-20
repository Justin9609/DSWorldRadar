#include "wcx_resolver.h"
int resolve_for_test(const uint8_t *data,size_t size,WcxTargets *out) {
  return wcx_resolve(data,size,out);
}
