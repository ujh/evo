CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../lib -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = brown.o gtp.o generate_move.o interface.o

.PHONY: enginetest arenatest test clean

default: evo arena

%.dep : %.c
	$(CC) -M -MP $(CFLAGS) $< > $@
include $(OBJS:.o=.dep) score.dep arena.dep rules_test.dep score_test.dep

evo: $(OBJS) main.o ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

enginetest: evo
	sh enginetest.sh

# Plays network-against-network games in one process, scored by the
# Tromp-Taylor count. Linked without the GTP code (gtp.o, interface.o).
arena: brown.o generate_move.o score.o arena.o ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

# Needs ../initial-population/initial-population for its random networks.
arenatest: evo arena
	sh arenatest.sh

# The Go rules: Brown's board code and the move filter. Linked without the
# GTP code (gtp.o, interface.o), which also checks that a program other than
# evo can play networks with brown.o and generate_move.o alone.
test: brown.o generate_move.o rules_test.o ../lib/libann.a score_test
	$(CC) $(CFLAGS) -o rules_test $(filter-out score_test,$^) $(LDLIBS)
	./rules_test
	./score_test

# The Tromp-Taylor count, over Brown's board alone.
score_test: brown.o score.o score_test.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.dep
	$(RM) evo arena rules_test score_test
