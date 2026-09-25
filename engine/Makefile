CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../lib -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = brown.o gtp.o generate_move.o interface.o

.PHONY: enginetest clean

default: evo

%.dep : %.c
	$(CC) -M -MP $(CFLAGS) $< > $@
include $(OBJS:.o=.dep)

evo: $(OBJS) main.o ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

enginetest: evo
	sh enginetest.sh

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.dep
	$(RM) evo
