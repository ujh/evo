CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = genann.o

default: initial-population

%.dep : %.c
	$(CC) -M -MP $(CFLAGS) $< > $@
include $(OBJS:.o=.dep)

initial-population: $(OBJS) main.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

# The same seed must give the same networks, another seed different ones.
test: initial-population
	rm -rf seeded-a seeded-b seeded-c && mkdir seeded-a seeded-b seeded-c
	cd seeded-a && ../initial-population 3 9 1 5 42 > /dev/null
	cd seeded-b && ../initial-population 3 9 1 5 42 > /dev/null
	cd seeded-c && ../initial-population 3 9 1 5 43 > /dev/null
	cmp seeded-a/0001.ann seeded-b/0001.ann && cmp seeded-a/0003.ann seeded-b/0003.ann
	! cmp -s seeded-a/0001.ann seeded-c/0001.ann
	! ./initial-population 3 9 1 5 not-a-seed
	rm -rf seeded-a seeded-b seeded-c
	./initial-population 10 9 2 2

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.ann *.dep
	$(RM) initial-population
