CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

.PHONY: test clean

default: libann.a

ann.o: ann.c ann.h genann.c genann.h
	$(CC) $(CFLAGS) -o $@ -c ann.c

libann.a: ann.o
	$(AR) rcs $@ $^

# GENANN's own tests, and the .ann round trip.
test: test.c minctest.h libann.a
	$(CC) $(CFLAGS) -o $@ test.c libann.a $(LDLIBS)
	./$@

clean:
	$(RM) -r *.o *.a test test.dSYM persist.*
