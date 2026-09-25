CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../lib -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = brown.o gtp.o generate_move.o interface.o

.PHONY: enginetest test clean

default: evo

%.dep : %.c
	$(CC) -M -MP $(CFLAGS) $< > $@
include $(OBJS:.o=.dep) rules_test.dep

evo: $(OBJS) main.o ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

enginetest: evo
	sh enginetest.sh

# The Go rules: Brown's board code and the move filter.
test: $(OBJS) rules_test.o ../lib/libann.a
	$(CC) $(CFLAGS) -o rules_test $^ $(LDLIBS)
	./rules_test

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.dep
	$(RM) evo rules_test
