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
# networks), weight_step, activation_rate, structure_rate; then no feature
# groups, the feature weights' noise, and feature_step.
GENES = 0.01 1 0.5 0.02 0.02 none 0.3 0.01
FEATURE_GENES = 0.01 1 0.5 0.02 0.02
GENES_BYTES = 7b14ae47e17a843f000000000000f03f000000000000e03f7b14ae47e17a943f7b14ae47e17a943f
# 9x9 with one hidden layer of 5: 5 * 83 + 82 * 6 = 907 weights.
GENES_LINE = genes layers=1 width=5 act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.01 weight_changes=1 weight_step=0.5 activation_rate=0.02 structure_rate=0.02 features=none feature_step=0.01

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
	test $$(wc -c < seeded-a/0001.ann) -eq $$((34 + 5 * 8 + 4 + 8 + 907 * 8))
	# The genes follow the 34-byte header as little-endian doubles, then
	# the features: no groups (a 0 mask, so no feature weights) and the
	# default feature_step, 0.01.
	test "$$(od -A n -t x1 -j 34 -N 40 seeded-a/0002.ann | tr -d ' \n')" = $(GENES_BYTES)
	test "$$(od -A n -t x1 -j 74 -N 12 seeded-a/0002.ann | tr -d ' \n')" = 000000007b14ae47e17a843f
	test "$$(grep -c '^genes ' seeded-a/out)" -eq 3
	test "$$(grep '^genes ' seeded-a/out | sort -u)" = "$(GENES_LINE)"
	# Without feature groups nothing is drawn besides the weights, so the
	# second network starts where the first one's draws end, as before
	# networks had features.
	test "$$(od -A n -t x1 -j 86 -N 16 seeded-a/0002.ann | tr -d ' \n')" = 0000c0eea2ccd93f000080c3e95bdb3f
	cd seeded-c && ../initial-population 1 9 0 5 0.1 1.25 10 0.0001 0.5 none 1 0.5 1 | grep -qx 'genes layers=0 width=0 act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.10000000000000001 weight_changes=1.25 weight_step=10 activation_rate=0.0001 structure_rate=0.5 features=none feature_step=0.5'
	# Every group: 1 + 81 + 11 * 81 + 1 = 974 inputs on 9x9 (little-endian
	# at byte 10), the 7 feature weights after the mask and feature_step,
	# and 5 * 975 + 82 * 6 = 5367 weights. Each feature weight is its
	# starting weight times 1 + u, u within the noise, drawn per network.
	rm -rf all-a all-b all-c && mkdir all-a all-b all-c
	cd all-a && ../initial-population 3 9 1 5 $(FEATURE_GENES) all 0.3 0.02 42 > out
	cd all-b && ../initial-population 3 9 1 5 $(FEATURE_GENES) shapes,tactics,last_move,liberties 0.3 0.02 42 > out
	cd all-c && ../initial-population 3 9 1 5 $(FEATURE_GENES) all 0 0.02 42 > out
	cmp all-a/0001.ann all-b/0001.ann && cmp all-a/0003.ann all-b/0003.ann && cmp all-a/out all-b/out
	test "$$(od -A n -t x1 -j 10 -N 4 all-a/0001.ann | tr -d ' \n')" = ce030000
	test "$$(od -A n -t x1 -j 74 -N 4 all-a/0001.ann | tr -d ' \n')" = 0f000000
	test $$(wc -c < all-a/0001.ann) -eq $$((86 + 7 * 8 + 5367 * 8))
	test "$$(grep -c '^genes ' all-a/out)" -eq 3
	test "$$(grep '^genes ' all-a/out | sort -u | wc -l)" -eq 3
	grep '^genes ' all-a/out | awk -v noise=0.3 -f features.awk
	test "$$(grep '^genes ' all-c/out | sort -u)" = "genes layers=1 width=5 act_hidden=sigmoid_cached act_output=sigmoid_cached copy_chance=0.01 weight_changes=1 weight_step=0.5 activation_rate=0.02 structure_rate=0.02 features=shapes,tactics,last_move,liberties feature_step=0.02 fw_hane=0.050000000000000003 fw_cut=0.050000000000000003 fw_edge=0.050000000000000003 fw_capture=1 fw_self_atari=-1 fw_saves_atari=0.80000000000000004 fw_near_last=0.050000000000000003"
	# The noise comes after each network's weights, so it leaves them as
	# they are; and it is drawn even when it is 0, so later networks' weights
	# do not depend on it.
	cmp -i 142 all-a/0003.ann all-c/0003.ann
	# The groups in any order, one group, and a group without move features.
	cd all-b && ../initial-population 1 9 1 5 $(FEATURE_GENES) liberties,shapes 0.3 0.01 1 | grep -q ' features=shapes,liberties feature_step=0.01 fw_hane=[0-9.e-]* fw_cut=[0-9.e-]* fw_edge=[0-9.e-]*$$'
	cd all-b && ../initial-population 1 5 0 5 $(FEATURE_GENES) tactics 0.3 0.01 1 | grep -q ' features=tactics feature_step=0.01 fw_capture=[0-9.e-]* fw_self_atari=-[0-9.e-]* fw_saves_atari=[0-9.e-]*$$'
	cd all-b && ../initial-population 1 9 0 5 $(FEATURE_GENES) liberties 0.3 0.01 1 | grep -q ' features=liberties feature_step=0.01$$'
	# Groups, noise, or feature_step that are not what they must be.
	cd all-b && for groups in '' Shapes shape all,shapes none,tactics shapes,shapes shapes, ,shapes 'shapes tactics' tactics,,shapes; do \
	  ! ../initial-population 1 9 1 5 $(FEATURE_GENES) "$$groups" 0.3 0.01 1 || exit 1; \
	done
	cd all-b && for noise in -0.1 1.01 nan inf x ''; do \
	  ! ../initial-population 1 9 1 5 $(FEATURE_GENES) all "$$noise" 0.01 1 || exit 1; \
	done
	cd all-b && for step in 0 0.00009 1.5 nan x ''; do \
	  ! ../initial-population 1 9 1 5 $(FEATURE_GENES) all 0.3 "$$step" 1 || exit 1; \
	done
	cd all-b && ../initial-population 1 9 1 5 $(FEATURE_GENES) all 1 1 1 > /dev/null && ../initial-population 1 9 1 5 $(FEATURE_GENES) all 0 0.0001 1 > /dev/null
	rm -rf all-a all-b all-c
	! ./initial-population 3 9 1 5 $(GENES) not-a-seed
	# Board sizes the .ann reader refuses.
	cd seeded-c && ! ../initial-population 1 1 1 5 $(GENES) 1 && ! ../initial-population 1 24 1 5 $(GENES) 1
	cd seeded-c && ../initial-population 1 2 1 5 $(GENES) 1 > /dev/null && ../initial-population 1 23 0 5 $(GENES) 1 > /dev/null
	! ./initial-population 3 9 1 5 42
	! ./initial-population 3 9 1 5 0.01 1 0.5 0.02 42
	! ./initial-population 3 9 1 5 0.01 1 0.5 0.02 0.02 42
	! ./initial-population 3 9 1 5 0.01 1 0.5 0.02 0.02 none 0.3
	cd seeded-c && ! ../initial-population 1 9 1 5 0.2 1 0.5 0.02 0.02 none 0.3 0.01 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 0.5 0.5 0.02 0.02 none 0.3 0.01 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 908 0.5 0.02 0.02 none 0.3 0.01 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 1 nan 0.02 0.02 none 0.3 0.01 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 1 0.5 0.02x 0.02 none 0.3 0.01 1
	cd seeded-c && ! ../initial-population 1 9 1 5 0.01 1 0.5 0.02 '' none 0.3 0.01 1
	rm -rf seeded-a seeded-b seeded-c
	./initial-population 10 9 2 2 $(GENES)

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.ann *.dep
	$(RM) initial-population
