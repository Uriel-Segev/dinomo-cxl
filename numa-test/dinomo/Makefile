CXX ?= g++
CC ?= gcc
ROOT := ../..
CLHT := $(ROOT)/src/kvs/Indexes/P-CLHT
CACHE := $(ROOT)/src/kvs/Cache/cuckoo-based
BLOOM := $(ROOT)/src/kvs/libbloom
CPPFLAGS := -DDINOMO_NUMA_MILESTONE -DENABLE_INT_KEYS -DCLFLUSH -DADD_PADDING \
 -I$(ROOT)/include -I$(ROOT)/include/kvs -I$(CLHT)/include \
 -I$(CLHT)/external/include -I$(CACHE) -I$(CACHE)/libcaches/include \
 -I$(CACHE)/libcuckoo/include -I$(BLOOM)
CXXFLAGS := -std=gnu++17 -O2 -g -pthread -mcx16 -ffunction-sections -fdata-sections \
 -Wno-format -Wno-unused-result
CFLAGS := -std=gnu11 -O2 -g -mcx16 -ffunction-sections -fdata-sections
LDLIBS := -lpmemobj -lpmem -libverbs -ltbb -latomic -pthread -lm
OBJECTS := build/milestone.o build/numa_backend.o build/clht.o build/gc.o \
 build/ssmem.o build/sspfd.o build/bloom.o build/murmur.o

.PHONY: all clean
all: build/dinomo-numa-milestone

build:
	mkdir -p build

build/milestone.o: milestone.cpp $(ROOT)/include/kvs/dinomo_compute.hpp | build
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@
build/numa_backend.o: $(ROOT)/src/kvs/numa_backend.cpp $(ROOT)/include/kvs/numa_backend.hpp | build
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@
build/clht.o: $(CLHT)/src/clht_lb_res.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@
build/gc.o: $(CLHT)/src/clht_gc.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@
build/ssmem.o: $(CLHT)/external/ssmem/src/ssmem.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@
build/sspfd.o: $(CLHT)/external/sspfd/sspfd.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@
build/bloom.o: $(BLOOM)/bloom.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -I$(BLOOM)/murmur2 -c $< -o $@
build/murmur.o: $(BLOOM)/murmur2/MurmurHash2.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@
build/dinomo-numa-milestone: $(OBJECTS)
	$(CXX) $(CXXFLAGS) -Wl,--gc-sections $^ $(LDLIBS) -o $@

clean:
	rm -f build/*.o build/dinomo-numa-milestone
