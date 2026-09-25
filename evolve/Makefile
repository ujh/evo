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

test: $(OBJS) test.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.dep
	$(RM) evolve test child.ann
