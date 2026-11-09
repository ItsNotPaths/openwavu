#include "pack_file.h"

#include <stdlib.h>
#include <string.h>

#include "openwavu.h"

T5Bytes t5_read_pack_file(void *context, const char *path) {
    (void)context;
    uint32_t length = (uint32_t)strlen(path);
    int32_t size = ow_content_size_raw(path, length);
    uint8_t *data = size > 0 ? malloc((size_t)size) : NULL;
    if (!data || ow_content_read_raw(path, length, 0, data, (uint32_t)size) != size) {
        free(data);
        return (T5Bytes){};
    }
    return (T5Bytes){data, (size_t)size};
}

T5Bytes t5_read_set_file(void *context, const char *path) {
    T5FileSet *file_set = context;
    if (file_set->count == file_set->capacity) {
        size_t capacity = file_set->capacity ? 2 * file_set->capacity : 16;
        void **files = realloc(file_set->files, capacity * sizeof *files);
        if (!files) return (T5Bytes){};
        file_set->files = files;
        file_set->capacity = capacity;
    }
    T5Bytes file = t5_read_pack_file(NULL, path);
    if (file.data) file_set->files[file_set->count++] = (void *)file.data;
    return file;
}

void t5_file_set_free(T5FileSet *file_set) {
    for (size_t at = 0; at < file_set->count; at++) free(file_set->files[at]);
    free(file_set->files);
    *file_set = (T5FileSet){};
}

// (hole arena-reserve :tags tk5mod :sev polish) the arena comes from calloc; reserve its pages once with memory.grow instead.
const char *t5_new_arena(T5Arena *arena, size_t bytes) {
    *arena = (T5Arena){calloc(1, bytes + 1), bytes, 0};  // + 1: calloc of 0 may give NULL
    return arena->base ? NULL : "out of memory";
}
