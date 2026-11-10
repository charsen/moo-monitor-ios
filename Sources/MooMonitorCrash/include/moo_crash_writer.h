#ifndef MOO_CRASH_WRITER_H
#define MOO_CRASH_WRITER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MOO_CRASH_MAGIC 0x4D4F4F43u  /* 'MOOC' */
#define MOO_CRASH_VERSION 1
#define MOO_CRASH_MAX_DEPTH 64
#define MOO_CRASH_MAX_IMAGES 32
/* image_index 的哨兵值：地址不属于启动时缓存的 image。 */
#define MOO_CRASH_UNKNOWN_IMAGE 0xFF

/*
 * 崩溃帧。只存相对所在 image 基址的偏移，不存绝对地址：
 * iOS 每次启动都做 ASLR，绝对地址下次启动指向随机内存，dladdr 会给出
 * 看起来很像真的错误符号——比没有符号更糟。
 */
typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t kind;          /* 1 = signal */
    int32_t  sig;
    uint64_t timestamp_ms;
    uint64_t thread_id;
    uint32_t depth;
    uint32_t image_count;
    uint64_t offsets[MOO_CRASH_MAX_DEPTH];
    uint8_t  image_index[MOO_CRASH_MAX_DEPTH];
    uint8_t  image_uuids[MOO_CRASH_MAX_IMAGES][16];
} moo_crash_frame;

/* 安装：打开文件、缓存当前 image 表（UUID + 基址）、登记信号处理。
 * 返回 0 成功，非 0 失败。必须在启动早期调用。 */
int moo_crash_install(const char *path);

/* 从文件读回全部帧，返回写入 out 的条数（最多 max）。 */
size_t moo_crash_read(const char *path, moo_crash_frame *out, size_t max);

/* 只读最近 max 帧（坏版本可能把 crash.bin 写得很长）。 */
size_t moo_crash_read_last(const char *path, moo_crash_frame *out, size_t max);

/* 清空崩溃文件（并入队列后调用）。 */
int moo_crash_reset(const char *path);

/* 兼容测试入口：无内核上下文时仅写信号，不伪造地址。 */
void moo_crash_handle(int sig);

/* NSException 已由 Swift 侧落盘：紧随其后的 SIGABRT 不再重复写一帧。 */
void moo_crash_skip_signal_after_exception(void);

/* 撤权后停采，但仍交还系统默认终止流程。 */
void moo_crash_set_enabled(int enabled);

#ifdef __cplusplus
}
#endif

#endif
