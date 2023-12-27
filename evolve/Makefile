CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = genann.o evolve.o

default: evolve

%.dep : %.c
	$(CC) -M $(CFLAGS) $< > $@
include $(OBJS:.o=.dep)

evolve: $(OBJS) main.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

evolvetest: evolve
	./evolve 0.9 ../engine/example.ann ../engine/example.ann

test: $(OBJS) test.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.dep
	$(RM) evolve test

