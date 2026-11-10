#include "include/moo_crash_writer.h"

#include <sys/ucontext.h>
#include <errno.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/*
 * 信号处理器运行在被中断的线程上，只能调用异步信号安全函数。
 * 这里只做三件事：填静态结构体 → 一次 write(2) → 恢复默认处理并重新抛出。
 * 不 malloc、不加锁、不碰 Swift 运行时——在被中断的 malloc 上再 malloc 会死锁，
 * 结果是「加了监控之后崩溃报告反而没了」。
 */

static int g_fd = -1;
static volatile sig_atomic_t g_enabled = 1;
static moo_crash_frame g_frame;
static uintptr_t g_image_bases[MOO_CRASH_MAX_IMAGES];
static uintptr_t g_image_ends[MOO_CRASH_MAX_IMAGES];
/* UUID 必须单独缓存：g_frame 每次崩溃都会 memset，直接写在 g_frame 里会被清掉。 */
static uint8_t g_image_uuids[MOO_CRASH_MAX_IMAGES][16];
static uint32_t g_image_count = 0;
static atomic_flag g_handling = ATOMIC_FLAG_INIT;
/* ObjC 未捕获异常最后会 abort() 成 SIGABRT；Swift 侧既然已经落盘，就别再写一条。 */
static volatile sig_atomic_t g_exception_captured = 0;

/*
 * 每个 image 的结束地址。没有它，image_index_for 只能按「最后一个基址小于 addr 的
 * image」猜，地址落在两个 image 之间时会归错 image，算出看似合理的错误偏移。
 */
static uintptr_t image_end_for(const struct mach_header *header, intptr_t slide) {
    if (header == NULL) {
        return 0;
    }
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    uintptr_t end = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            uintptr_t segment_end = (uintptr_t)(seg->vmaddr + seg->vmsize) + (uintptr_t)slide;
            if (segment_end > end) {
                end = segment_end;
            }
        }
        cursor += cmd->cmdsize;
    }
    return end;
}

static void capture_signal(int sig, siginfo_t *info, void *context);

int moo_crash_install(const char *path) {
    if (path == NULL) {
        return -1;
    }
    if (g_fd >= 0) { return -1; }
    g_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (g_fd < 0) {
        return -1;
    }
    struct stat existing;
    if (fstat(g_fd, &existing) == 0 && existing.st_size % sizeof(moo_crash_frame) != 0) {
        if (ftruncate(g_fd, existing.st_size - existing.st_size % sizeof(moo_crash_frame)) != 0) {
            close(g_fd); g_fd = -1; return -1;
        }
    }
    g_enabled = 1;
    atomic_flag_clear_explicit(&g_handling, memory_order_relaxed);
    g_exception_captured = 0;

    // image 表只在启动时取一次：_dyld_image_count / _dyld_get_image_header 内部有锁，
    // 信号恰好落在持锁线程上会死锁，所以处理器里只读这份缓存。
    uint32_t total = _dyld_image_count();
    g_image_count = total < MOO_CRASH_MAX_IMAGES ? total : MOO_CRASH_MAX_IMAGES;
    for (uint32_t i = 0; i < g_image_count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        g_image_bases[i] = (uintptr_t)header;
        g_image_ends[i] = image_end_for(header, _dyld_get_image_vmaddr_slide(i));
        const struct uuid_command *uuid = NULL;
        if (header != NULL) {
            const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
            for (uint32_t c = 0; c < header->ncmds; c++) {
                const struct load_command *cmd = (const struct load_command *)cursor;
                if (cmd->cmd == LC_UUID) {
                    uuid = (const struct uuid_command *)cmd;
                    break;
                }
                cursor += cmd->cmdsize;
            }
        }
        if (uuid != NULL) {
            memcpy(g_image_uuids[i], uuid->uuid, 16);
        } else {
            memset(g_image_uuids[i], 0, 16);
        }
    }

    // 六个致命信号：Swift 的 fatalError 走 SIGTRAP/SIGILL，ObjC 异常走 SIGABRT。
    const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        sigemptyset(&action.sa_mask);
        action.sa_sigaction = capture_signal;
        action.sa_flags = SA_SIGINFO;
        if (sigaction(signals[i], &action, NULL) != 0) { return -1; }
    }

    return 0;
}

/* 返回包含 addr 的 image 下标；不在缓存的 image 里就返回哨兵，绝不猜。 */
static uint32_t image_index_for(uintptr_t addr) {
    for (uint32_t i = 0; i < g_image_count; i++) {
        if (g_image_bases[i] != 0 && addr >= g_image_bases[i] && addr < g_image_ends[i]) {
            return i;
        }
    }
    return MOO_CRASH_UNKNOWN_IMAGE;
}

void moo_crash_skip_signal_after_exception(void) {
    g_exception_captured = 1;
}

void moo_crash_set_enabled(int enabled) { g_enabled = enabled != 0; }

/* 原始 fault PC 来自内核上下文，不能在 handler 里用 backtrace()/dyld/malloc 猜栈。
 * arm64 额外保留 LR；不遍历可能损坏或不在当前线程范围内的栈内存。 */
static void capture_signal(int sig, siginfo_t *info, void *context) {
    int saved_errno = errno;
    if (!g_exception_captured && g_enabled && g_fd >= 0 &&
        !atomic_flag_test_and_set_explicit(&g_handling, memory_order_relaxed)) {
        memset(&g_frame, 0, sizeof(g_frame));
        memcpy(g_frame.image_uuids, g_image_uuids, sizeof(g_image_uuids));
        g_frame.magic = MOO_CRASH_MAGIC;
        g_frame.version = MOO_CRASH_VERSION;
        g_frame.kind = 1;
        g_frame.sig = sig;
        g_frame.image_count = g_image_count;
        struct timespec ts = {0};
        clock_gettime(CLOCK_REALTIME, &ts);
        g_frame.timestamp_ms = (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
        uintptr_t addresses[2] = {0};
        size_t count = 0;
        ucontext_t *uc = (ucontext_t *)context;
        if (uc != NULL && uc->uc_mcontext != NULL) {
#if defined(__arm64__)
            addresses[count++] = (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
            addresses[count++] = (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
#elif defined(__x86_64__)
            addresses[count++] = (uintptr_t)uc->uc_mcontext->__ss.__rip;
#endif
        }
        for (size_t i = 0; i < count; i++) {
            uint32_t idx = image_index_for(addresses[i]);
            g_frame.image_index[i] = (uint8_t)idx;
            if (idx != MOO_CRASH_UNKNOWN_IMAGE) {
                g_frame.offsets[i] = addresses[i] - g_image_bases[idx];
            }
        }
        g_frame.depth = (uint32_t)count;
        ssize_t ignored = write(g_fd, &g_frame, sizeof(g_frame));
        (void)ignored;
    }
    signal(sig, SIG_DFL);
    errno = saved_errno;
    /* 同步硬件 fault 返回原 PC 后由系统按原故障终止，保留原始现场。
     * raise/abort 等用户产生的信号需要重新投递，否则返回后可能继续运行。 */
    if (info == NULL || info->si_code <= 0 || sig == SIGABRT) { raise(sig); }
}

void moo_crash_handle(int sig) { capture_signal(sig, NULL, NULL); }

size_t moo_crash_read(const char *path, moo_crash_frame *out, size_t max) {
    if (path == NULL || out == NULL || max == 0) {
        return 0;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }

    size_t count = 0;
    moo_crash_frame frame;
    while (count < max) {
        ssize_t n = read(fd, &frame, sizeof(frame));
        if (n != (ssize_t)sizeof(frame)) { break; }
        if (frame.magic != MOO_CRASH_MAGIC || frame.version != MOO_CRASH_VERSION ||
            frame.depth > MOO_CRASH_MAX_DEPTH || frame.image_count > MOO_CRASH_MAX_IMAGES) { continue; }
        out[count++] = frame;
    }
    close(fd);
    return count;
}

size_t moo_crash_read_last(const char *path, moo_crash_frame *out, size_t max) {
    if (path == NULL || out == NULL || max == 0) {
        return 0;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(moo_crash_frame)) {
        close(fd);
        return 0;
    }

    size_t total = (size_t)st.st_size / sizeof(moo_crash_frame);
    size_t skip = total > max ? total - max : 0;
    if (lseek(fd, (off_t)(skip * sizeof(moo_crash_frame)), SEEK_SET) < 0) {
        close(fd);
        return 0;
    }

    size_t count = 0;
    moo_crash_frame frame;
    while (count < max) {
        ssize_t n = read(fd, &frame, sizeof(frame));
        if (n != (ssize_t)sizeof(frame)) { break; }
        if (frame.magic != MOO_CRASH_MAGIC || frame.version != MOO_CRASH_VERSION ||
            frame.depth > MOO_CRASH_MAX_DEPTH || frame.image_count > MOO_CRASH_MAX_IMAGES) { continue; }
        out[count++] = frame;
    }
    close(fd);
    return count;
}

int moo_crash_reset(const char *path) {
    if (path == NULL) {
        return -1;
    }
    atomic_flag_clear_explicit(&g_handling, memory_order_relaxed);
    g_exception_captured = 0;
    if (g_fd >= 0) {
        /* fd 不失效，避免处理器撞进 close/open 窗口；原 fd 始终带 O_APPEND。 */
        return ftruncate(g_fd, 0);
    } else {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0600);
        if (fd >= 0) { close(fd); return 0; }
        return -1;
    }
}
