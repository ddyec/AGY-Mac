#ifndef AGY_ARCHIVE_H
#define AGY_ARCHIVE_H
#include <stddef.h>
#include <stdint.h>
int agy_inflate_raw(const uint8_t *source, size_t source_size, uint8_t *target, size_t target_size, uint32_t crc);
uint32_t agy_crc32(const uint8_t *bytes, size_t count);
#endif
