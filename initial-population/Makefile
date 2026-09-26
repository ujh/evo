CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../lib -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = main.o

default: initial-population

%.dep : %.c
	$(CC) -M -MP $(CFLAGS) $< > $@
include $(OBJS:.o=.dep)

initial-population: $(OBJS) ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

# Today's default genes: copy_chance, weight_changes (1 for these small
# networks), weight_step, activation_rate, structure_rate.
GENES = 0.01 1 0.5 0.02 0.02
GENES_BYTES = 7b14ae47e17a843f000000000000f03f000000000000e03f7b14ae47e17a943f7b14ae47e17a943f
# 9x9 with one hidden layer of 5: 5 * 83 + 82 * 6 = 907 weights.
GENES_LINE = genes layers=1 width=5 act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.01 weight_changes=1 weight_step=0.5 activation_rate=0.02 structure_rate=0.02

# The same seed must give the same networks, another seed different ones.
# Every network gets the genes it is given, and one genes line on stdout.
# Genes outside their range, or not numbers, are refused.
test: initial-population
	rm -rf seeded-a seeded-b seeded-c && mkdir seeded-a seeded-b seeded-c
	cd seeded-a && ../initial-population 3 9 1 5 $(GENES) 42 > out
	cd seeded-b && ../initial-population 3 9 1 5 $(GENES) 42 > /dev/null
	cd seeded-c && ../initial-population 3 9 1 5 $(GENES) 43 > /dev/null
	cmp seeded-a/0001.ann seeded-b/0001.ann && cmp seeded-a/0003.ann seeded-b/0003.ann
	! cmp -s seeded-a/0001.ann seeded-c/0001.ann
	test $$(wc -c < seeded-a/0001.ann) -eq $$((34 + 5 * 8 + 907 * 8))
	# The genes follow the 34-byte header as little-endian doubles.
	test "$$(od -A n -t x1 -j 34 -N 40 seeded-a/0002.ann | tr -d ' \n')" = $(GENES_BYTES)
	test "$$(grep -c '^genes ' seeded-a/out)" -eq 3
	test "$$(grep '^genes ' seeded-a/out | sort -u)" = "$(GENES_LINE)"
	cd seeded-c && ../initial-population 1 9 0 5 0.1 1.25 10 0.0001 0.5 1 | grep -qx 'genes layers=0 width=0 act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.10000000000000001 weight_changes=1.25 weight_step=10 activation_rate=0.0001 structure_rate=0.5'
	! ./initial-population 3 9 1 5 $(GENES) not-a-seed
	! ./initial-population 3 9 1 5 42
	! ./initial-population 3 9 1 5 0.01 1 0.5 0.02 42
	cd seeded-c && ! ../initial-population 1 9 1 5 0.2 1 0.5 0.02 0.02 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 0.5 0.5 0.02 0.02 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 908 0.5 0.02 0.02 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 1 nan 0.02 0.02 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 1 0.5 0.02x 0.02 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 1 0.5 0.02 '' 1
	rm -rf seeded-a seeded-b seeded-c
	./initial-population 10 9 2 2 $(GENES)

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.ann *.dep
	$(RM) initial-population
