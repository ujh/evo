all: pcg lib
	cd engine; $(MAKE)
	cd initial-population; $(MAKE)
	cd evolve; $(MAKE)

clean:
	cd engine; $(MAKE) clean
	cd initial-population; $(MAKE) clean
	cd evolve; $(MAKE) clean
	cd lib; $(MAKE) clean
	cd pcg-c/src; $(MAKE) clean

test: pcg lib
	cd lib; $(MAKE) test
	cd engine; $(MAKE) enginetest
	cd engine; $(MAKE) test
	cd initial-population; $(MAKE) test
	cd evolve; $(MAKE) test
	cd evolve; $(MAKE) evolvetest

pcg:
	cd pcg-c/src; $(MAKE)

# GENANN and Evo's layer over it (lib/ann.h), linked by every program.
lib: pcg
	cd lib; $(MAKE)

.PHONY: all clean test pcg lib
