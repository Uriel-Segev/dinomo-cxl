#define _GNU_SOURCE

#include <errno.h>
#include <linux/mempolicy.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define MAX_NUMA_NODES 1024UL
#define MAX_CPUS 1024
#define CHECK_INTERVAL 4096UL

enum workload {
    WORK_READ,
    WORK_WRITE,
    WORK_CONCURRENT,
    WORK_ATOMIC,
    WORK_MIXED
};

struct shared_state {
    volatile uint64_t *words;
    size_t word_count;
    uint64_t end_ns;
    pthread_barrier_t barrier;
};

struct worker_state {
    struct shared_state *shared;
    enum workload workload;
    unsigned thread_id;
    int cpu;
    size_t begin;
    size_t end;
    uint64_t operations;
    uint64_t checksum;
};

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s --test TEST --cpus LIST --memory-node NODE [options]\n"
            "Tests: read-bandwidth, write-bandwidth, concurrent-read, atomic, mixed\n"
            "Options:\n"
            "  --threads N       Worker threads (default: 1)\n"
            "  --size-mb MB      Total working set (default: 256)\n"
            "  --duration SEC    Measurement duration (default: 3)\n"
            "  --csv-header      Print a CSV header\n",
            program);
}

static unsigned long number(const char *text, const char *name)
{
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno || end == text || *end != '\0') {
        fprintf(stderr, "Invalid %s: %s\n", name, text);
        exit(EXIT_FAILURE);
    }
    return value;
}

static uint64_t now_ns(void)
{
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &time) != 0) {
        perror("clock_gettime");
        exit(EXIT_FAILURE);
    }
    return (uint64_t)time.tv_sec * 1000000000ULL + (uint64_t)time.tv_nsec;
}

static uint64_t random64(uint64_t *state)
{
    uint64_t value = *state;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    *state = value;
    return value;
}

static enum workload parse_workload(const char *name)
{
    if (strcmp(name, "read-bandwidth") == 0)
        return WORK_READ;
    if (strcmp(name, "write-bandwidth") == 0)
        return WORK_WRITE;
    if (strcmp(name, "concurrent-read") == 0)
        return WORK_CONCURRENT;
    if (strcmp(name, "atomic") == 0)
        return WORK_ATOMIC;
    if (strcmp(name, "mixed") == 0)
        return WORK_MIXED;
    fprintf(stderr, "Unknown test: %s\n", name);
    exit(EXIT_FAILURE);
}

static int parse_cpus(char *text, int *cpus)
{
    int count = 0;
    char *save = NULL;
    for (char *token = strtok_r(text, ",", &save); token != NULL;
         token = strtok_r(NULL, ",", &save)) {
        if (count == MAX_CPUS) {
            fprintf(stderr, "Too many CPUs in list\n");
            exit(EXIT_FAILURE);
        }
        cpus[count++] = (int)number(token, "CPU");
    }
    return count;
}

static void pin_cpu(int cpu)
{
    if (cpu < 0 || cpu >= CPU_SETSIZE) {
        fprintf(stderr, "CPU %d is outside CPU_SETSIZE\n", cpu);
        exit(EXIT_FAILURE);
    }
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        fprintf(stderr, "Unable to pin worker to CPU %d: %s\n", cpu,
                strerror(errno));
        exit(EXIT_FAILURE);
    }
}

static void bind_memory(void *address, size_t length, unsigned long node)
{
    if (node >= MAX_NUMA_NODES) {
        fprintf(stderr, "NUMA node %lu is too large\n", node);
        exit(EXIT_FAILURE);
    }
    unsigned long mask[MAX_NUMA_NODES / (8 * sizeof(unsigned long))] = {0};
    mask[node / (8 * sizeof(unsigned long))] |=
        1UL << (node % (8 * sizeof(unsigned long)));
    if (syscall(SYS_mbind, address, length, MPOL_BIND, mask,
                MAX_NUMA_NODES, 0) != 0) {
        fprintf(stderr, "mbind(node %lu): %s\n", node, strerror(errno));
        exit(EXIT_FAILURE);
    }
}

static void verify_placement(void *address, size_t length, unsigned long node,
                             size_t *sample_count_out, size_t *matching_out)
{
    const size_t maximum = 256;
    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    size_t pages_in_mapping = length / page_size;
    size_t count = pages_in_mapping < maximum ? pages_in_mapping : maximum;
    void **pages = calloc(count, sizeof(*pages));
    int *status = calloc(count, sizeof(*status));
    if (!pages || !status) {
        fprintf(stderr, "Unable to allocate placement arrays\n");
        exit(EXIT_FAILURE);
    }
    for (size_t i = 0; i < count; ++i)
        pages[i] = (char *)address + ((i * pages_in_mapping) / count) * page_size;
    if (syscall(SYS_move_pages, 0, count, pages, NULL, status, 0) != 0) {
        fprintf(stderr, "Warning: placement query failed: %s\n",
                strerror(errno));
        *sample_count_out = 0;
        *matching_out = 0;
    } else {
        size_t matching = 0;
        for (size_t i = 0; i < count; ++i)
            matching += status[i] == (int)node;
        *sample_count_out = count;
        *matching_out = matching;
        if (matching != count) {
            fprintf(stderr, "Only %zu/%zu pages were on NUMA node %lu\n",
                    matching, count, node);
            exit(EXIT_FAILURE);
        }
    }
    free(status);
    free(pages);
}

static void *worker(void *argument)
{
    struct worker_state *state = argument;
    struct shared_state *shared = state->shared;
    volatile uint64_t *words = shared->words;
    size_t span = state->end - state->begin;
    size_t index = state->begin;
    uint64_t rng = 0x9e3779b97f4a7c15ULL ^ (state->thread_id + 1);
    uint64_t operations = 0;
    uint64_t checksum = 0;

    pin_cpu(state->cpu);
    pthread_barrier_wait(&shared->barrier);

    while (now_ns() < shared->end_ns) {
        for (size_t batch = 0; batch < CHECK_INTERVAL; ++batch) {
            switch (state->workload) {
            case WORK_READ:
                checksum += words[index++];
                if (index == state->end)
                    index = state->begin;
                break;
            case WORK_WRITE:
                words[index++] = operations;
                if (index == state->end)
                    index = state->begin;
                break;
            case WORK_CONCURRENT:
                index = state->begin + random64(&rng) % span;
                checksum += words[index];
                break;
            case WORK_ATOMIC:
                index = state->begin + random64(&rng) % span;
                __atomic_fetch_add((uint64_t *)&words[index], 1,
                                   __ATOMIC_SEQ_CST);
                break;
            case WORK_MIXED: {
                uint64_t choice = random64(&rng) % 100;
                index = state->begin + random64(&rng) % span;
                if (choice < 60)
                    checksum += words[index];
                else if (choice < 90)
                    words[index] = operations;
                else
                    __atomic_fetch_add((uint64_t *)&words[index], 1,
                                       __ATOMIC_SEQ_CST);
                break;
            }
            }
        }
        operations += CHECK_INTERVAL;
    }
    state->operations = operations;
    state->checksum = checksum;
    return NULL;
}

int main(int argc, char **argv)
{
    const char *test_name = NULL;
    char *cpu_text = NULL;
    unsigned long memory_node = (unsigned long)-1;
    unsigned long threads = 1;
    unsigned long size_mb = 256;
    unsigned long duration = 3;
    int csv_header = 0;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--test") == 0 && i + 1 < argc)
            test_name = argv[++i];
        else if (strcmp(argv[i], "--cpus") == 0 && i + 1 < argc)
            cpu_text = strdup(argv[++i]);
        else if (strcmp(argv[i], "--memory-node") == 0 && i + 1 < argc)
            memory_node = number(argv[++i], "memory node");
        else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc)
            threads = number(argv[++i], "threads");
        else if (strcmp(argv[i], "--size-mb") == 0 && i + 1 < argc)
            size_mb = number(argv[++i], "size");
        else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc)
            duration = number(argv[++i], "duration");
        else if (strcmp(argv[i], "--csv-header") == 0)
            csv_header = 1;
        else {
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }
    if (!test_name || !cpu_text || memory_node == (unsigned long)-1 ||
        threads == 0 || size_mb == 0 || duration == 0) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    enum workload workload = parse_workload(test_name);
    int cpus[MAX_CPUS];
    int cpu_count = parse_cpus(cpu_text, cpus);
    if (cpu_count < (int)threads) {
        fprintf(stderr, "Need at least %lu CPUs, but list contains %d\n",
                threads, cpu_count);
        return EXIT_FAILURE;
    }

    size_t length = size_mb * 1024UL * 1024UL;
    size_t word_count = length / sizeof(uint64_t);
    if (word_count < threads * CHECK_INTERVAL) {
        fprintf(stderr, "Working set is too small for %lu threads\n", threads);
        return EXIT_FAILURE;
    }
    volatile uint64_t *words = mmap(NULL, length, PROT_READ | PROT_WRITE,
                                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (words == MAP_FAILED) {
        fprintf(stderr, "mmap: %s\n", strerror(errno));
        return EXIT_FAILURE;
    }
    bind_memory((void *)words, length, memory_node);
    (void)madvise((void *)words, length, MADV_NOHUGEPAGE);
    for (size_t i = 0; i < word_count; ++i)
        words[i] = i;

    size_t placement_samples = 0;
    size_t placement_matching = 0;
    verify_placement((void *)words, length, memory_node, &placement_samples,
                     &placement_matching);

    struct shared_state shared = {
        .words = words,
        .word_count = word_count
    };
    pthread_barrier_init(&shared.barrier, NULL, (unsigned)threads + 1);
    pthread_t *handles = calloc(threads, sizeof(*handles));
    struct worker_state *states = calloc(threads, sizeof(*states));
    if (!handles || !states) {
        fprintf(stderr, "Unable to allocate worker state\n");
        return EXIT_FAILURE;
    }

    for (unsigned long i = 0; i < threads; ++i) {
        states[i].shared = &shared;
        states[i].workload = workload;
        states[i].thread_id = (unsigned)i;
        states[i].cpu = cpus[i];
        states[i].begin = (word_count * i) / threads;
        states[i].end = (word_count * (i + 1)) / threads;
        int rc = pthread_create(&handles[i], NULL, worker, &states[i]);
        if (rc != 0) {
            fprintf(stderr, "pthread_create: %s\n", strerror(rc));
            return EXIT_FAILURE;
        }
    }

    uint64_t start_ns = now_ns();
    shared.end_ns = start_ns + duration * 1000000000ULL;
    pthread_barrier_wait(&shared.barrier);
    uint64_t total_operations = 0;
    uint64_t checksum = 0;
    for (unsigned long i = 0; i < threads; ++i) {
        pthread_join(handles[i], NULL);
        total_operations += states[i].operations;
        checksum ^= states[i].checksum;
    }
    uint64_t finish_ns = now_ns();
    double seconds = (double)(finish_ns - start_ns) / 1e9;
    double mops = (double)total_operations / seconds / 1e6;
    double bandwidth = (double)total_operations * sizeof(uint64_t) /
                       seconds / (1024.0 * 1024.0 * 1024.0);
    double ns_per_op = seconds * 1e9 * threads / total_operations;

    if (csv_header)
        puts("test,memory_node,threads,size_mb,duration_s,operations,"
             "mops,logical_gib_s,ns_per_op,placement_samples,"
             "placement_on_target");
    printf("%s,%lu,%lu,%lu,%.6f,%llu,%.3f,%.3f,%.3f,%zu,%zu\n",
           test_name, memory_node, threads, size_mb, seconds,
           (unsigned long long)total_operations, mops, bandwidth, ns_per_op,
           placement_samples, placement_matching);

    if (checksum == UINT64_MAX)
        fprintf(stderr, "checksum=%llu\n", (unsigned long long)checksum);
    pthread_barrier_destroy(&shared.barrier);
    free(states);
    free(handles);
    free(cpu_text);
    munmap((void *)words, length);
    return EXIT_SUCCESS;
}
