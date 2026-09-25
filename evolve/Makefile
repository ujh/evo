CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../lib -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = evolve.o

.PHONY: test evolvetest clean

default: evolve

%.dep : %.c
	$(CC) -M -MP $(CFLAGS) $< > $@
include $(OBJS:.o=.dep)

evolve: $(OBJS) main.o ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

# evolve must write the child where it is told, and fail without writing
# anything when an input cannot be read or no output path is given.
evolvetest: evolve
	rm -f child.ann child-missing.ann child-dir.ann
	./evolve 0.9 ../engine/example.ann ../engine/example.ann child.ann
	test -s child.ann
	! ./evolve 0.9 missing.ann ../engine/example.ann child-missing.ann
	test ! -e child-missing.ann
	! ./evolve 0.9 . ../engine/example.ann child-dir.ann
	test ! -e child-dir.ann
	! ./evolve 0.9 ../engine/example.ann ../engine/example.ann
	rm -rf parents && mkdir parents
	cd parents && ../../initial-population/initial-population 2 9 1 5 42 > /dev/null
	# Rate 1 always crosses over. The same seed gives the same child, another
	# seed another one. Random parents differ in all 907 weights, and each of
	# the child's weights comes from one of them, so the counts add up to 907.
	./evolve 1 parents/0001.ann parents/0002.ann cross-a.ann 7 > cross-a.out
	./evolve 1 parents/0001.ann parents/0002.ann cross-b.ann 7 > /dev/null
	./evolve 1 parents/0001.ann parents/0002.ann cross-c.ann 8 > /dev/null
	cmp cross-a.ann cross-b.ann
	! cmp -s cross-a.ann cross-c.ann
	set -- $$(sed -n 's/^summary operator=\([a-z]*\) differs_from_first=\([0-9]*\) differs_from_second=\([0-9]*\)$$/\1 \2 \3/p' cross-a.out) && test "$$1" = crossover && test $$(($$2 + $$3)) -eq 907
	# Rate 0 always mutates: a copy of one parent with a few changed weights,
	# and a count of 0 means a byte-identical copy.
	./evolve 0 parents/0001.ann parents/0002.ann mutated.ann 7 > mutated.out
	set -- $$(sed -n 's/^summary operator=\([a-z]*\) differs_from_first=\([0-9]*\) differs_from_second=\([0-9]*\)$$/\1 \2 \3/p' mutated.out) && test "$$1" = mutation && test "$$3" -eq 0 && test "$$2" -eq 907 && cmp mutated.ann parents/0002.ann
	./evolve 0 parents/0001.ann parents/0002.ann mutated.ann 8 > mutated.out
	set -- $$(sed -n 's/^summary operator=\([a-z]*\) differs_from_first=\([0-9]*\) differs_from_second=\([0-9]*\)$$/\1 \2 \3/p' mutated.out) && test "$$1" = mutation && test "$$2" -gt 0 && test "$$2" -le 5 && test "$$3" -eq 907
	! ./evolve 0.5 ../engine/example.ann child.ann seeded-c.ann not-a-seed
	rm -rf parents cross-a.ann cross-b.ann cross-c.ann cross-a.out mutated.ann mutated.out

test: $(OBJS) test.o ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.dep
	$(RM) evolve test child.ann
