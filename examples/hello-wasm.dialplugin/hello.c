#include <stdint.h>

static char request[65536];
static const char response[] = "{\"message\":\"Hello from WebAssembly\"}";

int32_t dial_alloc(int32_t size) {
    return size >= 0 && size <= (int32_t)sizeof(request) ? (int32_t)(uintptr_t)request : 0;
}

int32_t dial_run(int32_t ptr, int32_t len) {
    (void)ptr;
    (void)len;
    return (int32_t)(uintptr_t)response;
}

int32_t dial_result_len(void) {
    return (int32_t)(sizeof(response) - 1);
}
