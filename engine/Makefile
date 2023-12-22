CFLAGS = -Wall -Wshadow -O3 -g -march=native
LDLIBS = -lm

OBJS = brown.o gtp.o genann.o generate_move.o

default: evo

%.dep : %.c
	$(CC) -M $< > $@
include $(OBJS:.o=.dep)

evo: $(OBJS) interface.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

enginetest: evo
	./evo < enginetest.gtp

test: $(OBJS) test.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o
	$(RM) evo test

