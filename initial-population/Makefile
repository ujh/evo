CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = genann.o

default: initial-population

%.dep : %.c
	$(CC) -M $(CFLAGS) $< > $@
include $(OBJS:.o=.dep)

initial-population: $(OBJS) main.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test: initial-population
	./initial-population 10 9 2 2

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.ann *.dep
	$(RM) initial-population

