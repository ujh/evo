CFLAGS = -Wall -Wshadow -O3 -g -march=native
LDLIBS = -lm

OBJS = brown.o gtp.o genann.o

default: evo

%.dep : %.c
	$(CC) -M $< > $@
include $(OBJS:.o=.dep)

evo: $(OBJS) interface.o
	$(CC) $(CFLAGS) $(LDLIBS) -o $@ $^

test: $(OBJS) test.o
	$(CC) $(CFLAGS) $(LDLIBS) -o $@ $^
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o
	$(RM) evo test

