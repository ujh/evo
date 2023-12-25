CFLAGS = -Wall -Wshadow -O3 -g -march=native
LDLIBS = -lm

OBJS = genann.o

default: evolve

%.dep : %.c
	$(CC) -M $< > $@
include $(OBJS:.o=.dep)

evolve: $(OBJS) main.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test: $(OBJS) test.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o
	$(RM) evo test

