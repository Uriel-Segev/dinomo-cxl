CC ?= gcc
CFLAGS ?= -O3 -g -Wall -Wextra -Wpedantic -std=gnu11
PTHREAD_FLAGS ?= -pthread

.PHONY: all clean

all: numa_latency numa_workload

numa_latency: numa_latency.c
	$(CC) $(CFLAGS) -o $@ $<

numa_workload: numa_workload.c
	$(CC) $(CFLAGS) $(PTHREAD_FLAGS) -o $@ $<

clean:
	rm -f numa_latency numa_workload
