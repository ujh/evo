CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

.PHONY: test clean

default: libann.a

ann.o: ann.c ann.h genann.c genann.h
	$(CC) $(CFLAGS) -o $@ -c ann.c

libann.a: ann.o
	$(AR) rcs $@ $^

# GENANN's own tests, and the .ann round trip. Then a network loaded for
# play in a process that never calls genann_init (play_test.c) computes what
# the drawing load computes.
test: test.c minctest.h libann.a play_test
	$(CC) $(CFLAGS) -o $@ test.c libann.a $(LDLIBS)
	./$@
	./play_test write persist.play.ann
	./play_test play persist.play.ann > persist.play
	./play_test draw persist.play.ann > persist.draw
	cmp persist.play persist.draw

play_test: play_test.c libann.a
	$(CC) $(CFLAGS) -o $@ play_test.c libann.a $(LDLIBS)

clean:
	$(RM) -r *.o *.a test test.dSYM play_test play_test.dSYM persist.*
