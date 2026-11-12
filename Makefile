# Each recipe runs make with -C, which fails when the directory is missing
# (pcg-c/src in a fresh worktree before `git submodule update --init`).
# `cd DIR; $(MAKE)` would run this Makefile again instead, without end.
all: pcg lib
	$(MAKE) -C engine
	$(MAKE) -C initial-population
	$(MAKE) -C evolve

clean:
	$(MAKE) -C engine clean
	$(MAKE) -C initial-population clean
	$(MAKE) -C evolve clean
	$(MAKE) -C lib clean
	$(MAKE) -C pcg-c/src clean

test: pcg lib
	$(MAKE) -C lib test
	$(MAKE) -C engine enginetest
	$(MAKE) -C engine test
	$(MAKE) -C initial-population test
	$(MAKE) -C engine arenatest
	$(MAKE) -C evolve test
	$(MAKE) -C evolve evolvetest
	$(MAKE) -C evolve perturbtest

pcg:
	$(MAKE) -C pcg-c/src

# GENANN and Evo's layer over it (lib/ann.h), linked by every program.
lib: pcg
	$(MAKE) -C lib

.PHONY: all clean test pcg lib
