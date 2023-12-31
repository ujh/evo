all: pcg
	cd engine; $(MAKE)
	cd initial-population; $(MAKE)
	cd evolve; $(MAKE)

clean:
	cd engine; $(MAKE) clean
	cd initial-population; $(MAKE) clean
	cd evolve; $(MAKE) clean
	cd pcg-c/src; $(MAKE) clean

test: pcg
	cd engine; $(MAKE) enginetest
	cd engine; $(MAKE) test
	cd initial-population; $(MAKE) test
	cd evolve; $(MAKE) test
	cd evolve; $(MAKE) evolvetest

pcg:
	cd pcg-c/src; $(MAKE)
