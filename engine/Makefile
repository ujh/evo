CFLAGS = -Wall -Wshadow -O3 -g -march=native
LDLIBS = -lm -lpcg_random

OBJS = brown.o gtp.o genann.o generate_move.o interface.o

default: evo

%.dep : %.c
	$(CC) -M $< > $@
include $(OBJS:.o=.dep)

evo: $(OBJS) main.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

enginetest: evo
	./evo example.ann < enginetest.gtp

test: $(OBJS) test.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o
	$(RM) evo test

