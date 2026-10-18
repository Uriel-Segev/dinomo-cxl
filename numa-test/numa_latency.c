#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <linux/mempolicy.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define CACHE_LINE_SIZE 64UL
#define MAX_NUMA_NODES 1024UL

static volatile uint32_t result_sink;

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s --cpu CPU --memory-node NODE [options]\n"
            "Options:\n"
            "  --size-mb MB       Working-set size (default: 256)\n"
            "  --passes N         Timed pointer-chase passes (default: 3)\n"
            "  --seed N           Shuffle seed (default: 1)\n"
            "  --csv-header       Print the CSV header before the result\n",
            program);
}

static unsigned long parse_ulong(const char *value, const char *name)
{
    char *end = NULL;
    errno = 0;
    unsigned long result = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        fprintf(stderr, "Invalid %s: %s\n", name, value);
        exit(EXIT_FAILURE);
    }
    return result;
}

static uint64_t xorshift64(uint64_t *state)
{
    uint64_t x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    return x;
}

static double elapsed_seconds(const struct timespec *start,
                              const struct timespec *end)
{
    return (double)(end->tv_sec - start->tv_sec) +
           (double)(end->tv_nsec - start->tv_nsec) / 1e9;
}

static void pin_to_cpu(unsigned long cpu)
{
    if (cpu >= CPU_SETSIZE) {
        fprintf(stderr, "CPU %lu exceeds CPU_SETSIZE=%d\n", cpu, CPU_SETSIZE);
        exit(EXIT_FAILURE);
    }
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET((int)cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        fprintf(stderr, "sched_setaffinity(CPU %lu): %s\n", cpu,
                strerror(errno));
        exit(EXIT_FAILURE);
    }
}

static void bind_memory(void *address, size_t length, unsigned long node)
{
    if (node >= MAX_NUMA_NODES) {
        fprintf(stderr, "NUMA node %lu exceeds supported maximum %lu\n", node,
                MAX_NUMA_NODES - 1);
        exit(EXIT_FAILURE);
    }
    unsigned long mask[MAX_NUMA_NODES / (8 * sizeof(unsigned long))];
    memset(mask, 0, sizeof(mask));
    mask[node / (8 * sizeof(unsigned long))] |=
        1UL << (node % (8 * sizeof(unsigned long)));
    long rc = syscall(SYS_mbind, address, length, MPOL_BIND, mask,
                      MAX_NUMA_NODES, 0);
    if (rc != 0) {
        fprintf(stderr, "mbind(node %lu): %s\n", node, strerror(errno));
        exit(EXIT_FAILURE);
    }
}

static void verify_placement(void *address, size_t length,
                             unsigned long expected_node,
                             size_t *samples_out, size_t *matching_out)
{
    const size_t max_samples = 256;
    const long page_size = sysconf(_SC_PAGESIZE);
    size_t page_count = length / (size_t)page_size;
    size_t sample_count = page_count < max_samples ? page_count : max_samples;
    void **pages = calloc(sample_count, sizeof(*pages));
    int *status = calloc(sample_count, sizeof(*status));
    if (pages == NULL || status == NULL) {
        fprintf(stderr, "Unable to allocate placement-check arrays\n");
        exit(EXIT_FAILURE);
    }
    for (size_t i = 0; i < sample_count; ++i) {
        size_t page = (i * page_count) / sample_count;
        pages[i] = (char *)address + page * (size_t)page_size;
    }
    long rc = syscall(SYS_move_pages, 0, sample_count, pages, NULL, status, 0);
    if (rc != 0) {
        fprintf(stderr,
                "Warning: move_pages placement query failed: %s; "
                "mbind still succeeded\n",
                strerror(errno));
        *samples_out = 0;
        *matching_out = 0;
    } else {
        size_t matching = 0;
        for (size_t i = 0; i < sample_count; ++i) {
            if (status[i] == (int)expected_node)
                ++matching;
        }
        *samples_out = sample_count;
        *matching_out = matching;
        if (matching != sample_count) {
            fprintf(stderr,
                    "Memory placement mismatch: %zu/%zu sampled pages are on "
                    "node %lu\n",
                    matching, sample_count, expected_node);
            exit(EXIT_FAILURE);
        }
    }
    free(status);
    free(pages);
}

int main(int argc, char **argv)
{
    unsigned long cpu = (unsigned long)-1;
    unsigned long memory_node = (unsigned long)-1;
    unsigned long size_mb = 256;
    unsigned long passes = 3;
    unsigned long seed = 1;
    int csv_header = 0;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--cpu") == 0 && i + 1 < argc)
            cpu = parse_ulong(argv[++i], "CPU");
        else if (strcmp(argv[i], "--memory-node") == 0 && i + 1 < argc)
            memory_node = parse_ulong(argv[++i], "memory node");
        else if (strcmp(argv[i], "--size-mb") == 0 && i + 1 < argc)
            size_mb = parse_ulong(argv[++i], "size");
        else if (strcmp(argv[i], "--passes") == 0 && i + 1 < argc)
            passes = parse_ulong(argv[++i], "passes");
        else if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc)
            seed = parse_ulong(argv[++i], "seed");
        else if (strcmp(argv[i], "--csv-header") == 0)
            csv_header = 1;
        else {
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }
    if (cpu == (unsigned long)-1 || memory_node == (unsigned long)-1 ||
        size_mb == 0 || passes == 0) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    pin_to_cpu(cpu);
    if (size_mb > SIZE_MAX / (1024UL * 1024UL)) {
        fprintf(stderr, "Working set is too large\n");
        return EXIT_FAILURE;
    }
    size_t length = size_mb * 1024UL * 1024UL;
    length -= length % CACHE_LINE_SIZE;
    size_t slot_count = length / CACHE_LINE_SIZE;
    if (slot_count > UINT32_MAX) {
        fprintf(stderr, "Working set has too many cache-line slots\n");
        return EXIT_FAILURE;
    }
    void *buffer = mmap(NULL, length, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buffer == MAP_FAILED) {
        fprintf(stderr, "mmap(%zu bytes): %s\n", length, strerror(errno));
        return EXIT_FAILURE;
    }
    bind_memory(buffer, length, memory_node);
    (void)madvise(buffer, length, MADV_NOHUGEPAGE);
    uint32_t *order = malloc(slot_count * sizeof(*order));
    if (order == NULL) {
        fprintf(stderr, "Unable to allocate shuffle array\n");
        return EXIT_FAILURE;
    }
    for (size_t i = 0; i < slot_count; ++i)
        order[i] = (uint32_t)i;
    uint64_t rng = seed == 0 ? 1 : seed;
    for (size_t i = slot_count - 1; i > 0; --i) {
        size_t j = xorshift64(&rng) % (i + 1);
        uint32_t temporary = order[i];
        order[i] = order[j];
        order[j] = temporary;
    }
    for (size_t i = 0; i < slot_count; ++i) {
        size_t next = (i + 1) % slot_count;
        uint32_t *slot = (uint32_t *)((char *)buffer +
                                      (size_t)order[i] * CACHE_LINE_SIZE);
        *slot = order[next];
    }
    free(order);
    size_t placement_samples = 0;
    size_t placement_matching = 0;
    verify_placement(buffer, length, memory_node, &placement_samples,
                     &placement_matching);
    volatile char *data = buffer;
    uint32_t index = 0;
    for (size_t i = 0; i < slot_count; ++i)
        index = *(volatile uint32_t *)(data + (size_t)index * CACHE_LINE_SIZE);
    uint64_t loads = (uint64_t)slot_count * passes;
    struct timespec start;
    struct timespec end;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &start) != 0) {
        perror("clock_gettime");
        return EXIT_FAILURE;
    }
    for (uint64_t i = 0; i < loads; ++i)
        index = *(volatile uint32_t *)(data + (size_t)index * CACHE_LINE_SIZE);
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &end) != 0) {
        perror("clock_gettime");
        return EXIT_FAILURE;
    }
    result_sink = index;
    double seconds = elapsed_seconds(&start, &end);
    double ns_per_load = seconds * 1e9 / (double)loads;
    if (csv_header)
        puts("cpu,memory_node,size_mb,passes,loads,seconds,ns_per_load,"
             "placement_samples,placement_on_target");
    printf("%lu,%lu,%lu,%lu,%" PRIu64 ",%.9f,%.3f,%zu,%zu\n", cpu,
           memory_node, size_mb, passes, loads, seconds, ns_per_load,
           placement_samples, placement_matching);
    munmap(buffer, length);
    return EXIT_SUCCESS;
}
