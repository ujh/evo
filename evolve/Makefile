CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = genann.o evolve.o

.PHONY: test evolvetest clean

default: evolve

%.dep : %.c
	$(CC) -M -MP $(CFLAGS) $< > $@
include $(OBJS:.o=.dep)

evolve: $(OBJS) main.o
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
	./evolve 0.5 ../engine/example.ann child.ann seeded-a.ann 7 > seeded-a.out
	./evolve 0.5 ../engine/example.ann child.ann seeded-b.ann 7 > seeded-b.out
	cmp seeded-a.ann seeded-b.ann
	test "$$(grep ^summary seeded-a.out)" = "$$(grep ^summary seeded-b.out)"
	grep -Eq '^summary operator=(crossover|mutation) differs_from_first=[0-9]+ differs_from_second=[0-9]+$$' seeded-a.out
	! ./evolve 0.5 ../engine/example.ann child.ann seeded-c.ann not-a-seed
	rm -f seeded-a.ann seeded-b.ann seeded-a.out seeded-b.out

test: $(OBJS) test.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.dep
	$(RM) evolve test child.ann
