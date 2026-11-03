#include "CArchive.h"
#include <zlib.h>
#include <string.h>
#include <limits.h>
uint32_t agy_crc32(const uint8_t *bytes, size_t count) {
    return (uint32_t)crc32(0, bytes, (uInt)count);
}
int agy_inflate_raw(const uint8_t *source, size_t source_size, uint8_t *target, size_t target_size, uint32_t crc) {
    if (source_size > UINT_MAX || target_size > UINT_MAX) return 0;
    z_stream stream; memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)source; stream.avail_in = (uInt)source_size;
    stream.next_out = target; stream.avail_out = (uInt)(target_size ? target_size : 1);
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 0;
    int result = inflate(&stream, Z_FINISH);
    int valid = result == Z_STREAM_END && stream.total_out == target_size && stream.total_in == source_size;
    inflateEnd(&stream);
    return valid && agy_crc32(target, target_size) == crc;
}
