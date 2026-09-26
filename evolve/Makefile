CFLAGS = -Wall -Wshadow -O3 -g -march=native -I../lib -I../pcg-c/include
LDLIBS = -L../pcg-c/src -lm -lpcg_random

OBJS = evolve.o

.PHONY: test evolvetest clean

default: evolve

%.dep : %.c
	$(CC) -M -MP $(CFLAGS) $< > $@
include $(OBJS:.o=.dep)

evolve: $(OBJS) main.o ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

# The summary line's fields, space-separated: operator, parent, structure,
# activation_changed, differs_from_first, differs_from_second.
SUMMARY = sed -n 's/^summary operator=\([a-z]*\) parent=\([a-z]*\) structure=\([a-z_]*\) activation_changed=\([01]\) differs_from_first=\(-\{0,1\}[0-9]*\) differs_from_second=\(-\{0,1\}[0-9]*\)$$/\1 \2 \3 \4 \5 \6/p'
# The arguments before the parents: cross_over_rate is given per call, then
# meta_rate, max_hidden_layers, max_layer_size, add_layer_size.
BOUNDS = 0.2 1 5 5

# evolve must write the child where it is told, and fail without writing
# anything when an input cannot be read, an argument is not a number in its
# range, or no output path is given.
evolvetest: evolve
	rm -f child.ann child-missing.ann child-dir.ann
	./evolve 0.9 $(BOUNDS) ../engine/example.ann ../engine/example.ann child.ann
	test -s child.ann
	! ./evolve 0.9 $(BOUNDS) missing.ann ../engine/example.ann child-missing.ann
	test ! -e child-missing.ann
	! ./evolve 0.9 $(BOUNDS) . ../engine/example.ann child-dir.ann
	test ! -e child-dir.ann
	! ./evolve 0.9 $(BOUNDS) ../engine/example.ann ../engine/example.ann
	! ./evolve 0.9 ../engine/example.ann ../engine/example.ann child-dir.ann
	for args in '1.5 0.2 1 5 5' 'x 0.2 1 5 5' '0.5x 0.2 1 5 5' '0.5 -0.1 1 5 5' '0.5 nan 1 5 5' '0.5 inf 1 5 5' \
	    '0.5 0.2 -1 5 5' '0.5 0.2 1.5 5 5' '0.5 0.2 1 0 1' '0.5 0.2 1 5x 5' '0.5 0.2 1 5 0' '0.5 0.2 1 5 6' '0.5 0.2 1 5 ""'; do \
	  eval "! ./evolve $$args ../engine/example.ann ../engine/example.ann child-dir.ann 1" || exit 1; \
	  test ! -e child-dir.ann || exit 1; \
	done
	! ./evolve 0.5 $(BOUNDS) ../engine/example.ann child.ann child-dir.ann not-a-seed
	test ! -e child-dir.ann
	rm -rf parents && mkdir parents
	# Two parents with different genes (as are all their weights). The first
	# switches activations often.
	cd parents && ../../initial-population/initial-population 1 9 1 5 0.01 1 0.5 0.5 0.02 none 0.3 0.01 42 > first.out
	mkdir parents/other
	# Their features differ too: the second's feature_step (the 8 bytes after
	# the genes and the 4-byte group mask, at byte 78) is 0.02.
	cd parents/other && ../../../initial-population/initial-population 2 9 1 5 0.02 2 0.25 0.04 0.03 none 0.3 0.02 42 > ../second.out
	mv parents/other/0002.ann parents/0002.ann
	! cmp -s -n 8 parents/0001.ann parents/0002.ann 78 78
	grep '^genes ' parents/first.out > parents/first.genes
	grep '^genes ' parents/second.out | sed -n 2p > parents/second.genes
	grep -q ' features=none feature_step=0.02$$' parents/second.genes
	# Rate 1 always crosses over. The same seed gives the same child, another
	# seed another one. Random parents differ in all 907 weights, and each of
	# the child's weights comes from one of them, so the counts add up to 907.
	./evolve 1 $(BOUNDS) parents/0001.ann parents/0002.ann cross-a.ann 7 > cross-a.out
	./evolve 1 $(BOUNDS) parents/0001.ann parents/0002.ann cross-b.ann 7 > /dev/null
	./evolve 1 $(BOUNDS) parents/0001.ann parents/0002.ann cross-c.ann 8 > /dev/null
	cmp cross-a.ann cross-b.ann
	! cmp -s cross-a.ann cross-c.ann
	set -- $$($(SUMMARY) cross-a.out) && test "$$1 $$2 $$3 $$4" = "crossover second none 0" && test $$(($$5 + $$6)) -eq 907
	# The child keeps the sizes, activations, genes, and features (the first
	# 86 bytes, as these parents have no feature groups and so no feature
	# weights) of the parent named in the summary, in argument order: with
	# the order swapped, the same seed picks the other file.
	cmp -n 86 cross-a.ann parents/0002.ann
	tail -n 1 cross-a.out | cmp - parents/second.genes
	./evolve 1 $(BOUNDS) parents/0002.ann parents/0001.ann cross-d.ann 7 > cross-d.out
	set -- $$($(SUMMARY) cross-d.out) && test "$$1 $$2" = "crossover second"
	cmp -n 86 cross-d.ann parents/0001.ann
	tail -n 1 cross-d.out | cmp - parents/first.genes
	# Rate 0 always mutates. With its parent's copy_chance (seed 28 draws
	# it) the child is a byte-identical copy, genes included.
	./evolve 0 $(BOUNDS) parents/0001.ann parents/0002.ann copy.ann 28 > copy.out
	set -- $$($(SUMMARY) copy.out) && test "$$*" = "copy second none 0 907 0"
	cmp copy.ann parents/0002.ann
	tail -n 1 copy.out | cmp - parents/second.genes
	# Otherwise the genes mutate, and with the first parent's activation_rate
	# of 0.5 seed 8 switches both activations: the sizes (the first 26 bytes)
	# stay, the activation codes (the next 8) and the genes (the next 40)
	# change, and the features (the next 12) are the parent's.
	./evolve 0 $(BOUNDS) parents/0001.ann parents/0002.ann mutated.ann 8 > mutated.out
	set -- $$($(SUMMARY) mutated.out) && test "$$1 $$2 $$3 $$4" = "mutation first none 1" && test "$$5" -gt 0 && test "$$5" -le 5 && test "$$6" -eq 907
	tail -n 1 mutated.out | grep -qx 'genes layers=1 width=5 act_hidden=linear act_output=relu copy_chance=[0-9.e-]* weight_changes=[0-9.e-]* weight_step=[0-9.e-]* activation_rate=[0-9.e-]* structure_rate=[0-9.e-]* features=none feature_step=0.01'
	cmp -n 26 mutated.ann parents/0001.ann
	! cmp -s -n 34 mutated.ann parents/0001.ann
	! tail -n 1 mutated.out | cmp -s - parents/first.genes
	cmp -n 12 mutated.ann parents/0001.ann 74 74
	# Seed 4 mutates the second parent without switching an activation.
	./evolve 0 $(BOUNDS) parents/0001.ann parents/0002.ann kept.ann 4 > kept.out
	set -- $$($(SUMMARY) kept.out) && test "$$1 $$2 $$3 $$4" = "mutation second none 0"
	cmp -n 34 kept.ann parents/0002.ann
	! cmp -s -n 74 kept.ann parents/0002.ann
	cmp -n 12 kept.ann parents/0002.ann 74 74
	# Parents whose activations differ still cross over.
	./evolve 1 $(BOUNDS) mutated.ann parents/0002.ann cross-e.ann 7 > cross-e.out
	set -- $$($(SUMMARY) cross-e.out) && test "$$1" = crossover
	# A parent that changes its structure half the time. With room for a
	# second hidden layer, seed 3 adds one: the child is 2x5, of another
	# shape than either parent, so both differs counts are -1, and the engine
	# plays it.
	mkdir parents/shaped
	cd parents/shaped && ../../../initial-population/initial-population 1 9 1 5 0.01 1 0.5 0.02 0.5 none 0.3 0.01 42 > /dev/null
	./evolve 0 0.2 2 6 5 parents/shaped/0001.ann parents/shaped/0001.ann deep.ann 3 > deep.out
	set -- $$($(SUMMARY) deep.out) && test "$$*" = "mutation first add_layer 0 -1 -1"
	tail -n 1 deep.out | grep -q '^genes layers=2 width=5 '
	printf 'boardsize 9\ngenmove b\nquit\n' | ../engine/evo deep.ann | grep -q '^= [A-Z]'
	# Parents of different shapes never cross over, even at rate 1: seed 3
	# mutates the deeper one, which keeps its shape, so only the count
	# against it is a number.
	./evolve 1 0.2 2 6 5 parents/shaped/0001.ann deep.ann mixed.ann 3 > mixed.out
	set -- $$($(SUMMARY) mixed.out) && test "$$1 $$2 $$3 $$5" = "mutation second none -1" && test "$$6" -ge 0
	# Parents with every feature group (974 inputs on 9x9), whose feature
	# weights and feature_step differ. The feature block is the 4-byte group
	# mask at byte 74, feature_step, and 7 feature weights: bytes 74 to 142.
	mkdir parents/features parents/features/other
	cd parents/features && ../../../initial-population/initial-population 1 9 1 5 0.05 1 0.5 0.02 0.02 all 0.3 0.01 42 > first.out
	cd parents/features/other && ../../../../initial-population/initial-population 2 9 1 5 0.05 2 0.25 0.04 0.03 all 0.3 0.02 43 > ../second.out
	mv parents/features/other/0002.ann parents/features/0002.ann
	grep '^genes ' parents/features/first.out > parents/features/first.genes
	grep '^genes ' parents/features/second.out | sed -n 2p > parents/features/second.genes
	! cmp -s -n 68 parents/features/0001.ann parents/features/0002.ann 74 74
	# A crossover child (seed 1 picks the second) takes the picked parent's
	# features unchanged, and its genes line says so.
	./evolve 1 $(BOUNDS) parents/features/0001.ann parents/features/0002.ann feat-cross.ann 1 > feat-cross.out
	set -- $$($(SUMMARY) feat-cross.out) && test "$$1 $$2 $$3" = "crossover second none"
	cmp -n 142 feat-cross.ann parents/features/0002.ann
	tail -n 1 feat-cross.out | cmp - parents/features/second.genes
	# A copy (seed 4) is the parent byte for byte, features included.
	./evolve 0 $(BOUNDS) parents/features/0001.ann parents/features/0002.ann feat-copy.ann 4 > feat-copy.out
	set -- $$($(SUMMARY) feat-copy.out) && test "$$1 $$2" = "copy second"
	cmp feat-copy.ann parents/features/0002.ann
	# A mutation (seed 3) keeps the groups and moves feature_step and every
	# feature weight, though here no network weight changed: the differs
	# counts cover only the network's weights.
	./evolve 0 $(BOUNDS) parents/features/0001.ann parents/features/0002.ann feat-mutated.ann 3 > feat-mutated.out
	set -- $$($(SUMMARY) feat-mutated.out) && test "$$*" = "mutation second none 0 5367 0"
	cmp -n 4 feat-mutated.ann parents/features/0002.ann 74 74
	for offset in 78 86 94 102 110 118 126 134; do \
	  ! cmp -s -n 8 feat-mutated.ann parents/features/0002.ann $$offset $$offset || exit 1; \
	done
	cmp feat-mutated.ann parents/features/0002.ann 142 142
	tail -n 1 feat-mutated.out | grep -q ' features=shapes,tactics,last_move,liberties feature_step=[0-9.e-]* fw_hane=[0-9.e-]* fw_cut=[0-9.e-]* fw_edge=[0-9.e-]* fw_capture=[0-9.e-]* fw_self_atari=-[0-9.e-]* fw_saves_atari=[0-9.e-]* fw_near_last=[0-9.e-]*$$'
	! tail -n 1 feat-mutated.out | cmp -s - parents/features/second.genes
	printf 'boardsize 9\ngenmove b\nquit\n' | ../engine/evo feat-mutated.ann | grep -q '^= [A-Z]'
	# Removing the only hidden layer (seed 28) folds the outputs onto every
	# input, the feature inputs included, and the engine plays the child.
	./evolve 0 $(BOUNDS) parents/features/0001.ann parents/features/0002.ann feat-flat.ann 28 > feat-flat.out
	set -- $$($(SUMMARY) feat-flat.out) && test "$$1 $$2 $$3" = "mutation first remove_layer"
	tail -n 1 feat-flat.out | grep -q '^genes layers=0 width=0 .* features=shapes,tactics,last_move,liberties '
	printf 'boardsize 9\ngenmove b\nquit\n' | ../engine/evo feat-flat.ann | grep -q '^= [A-Z]'
	# Parents with different feature groups cannot breed, even with as many
	# inputs: shapes and liberties both add three planes (325 inputs on 9x9).
	mkdir parents/shapes parents/liberties
	cd parents/shapes && ../../../initial-population/initial-population 1 9 1 5 0.05 1 0.5 0.02 0.02 shapes 0.3 0.01 42 > /dev/null
	cd parents/liberties && ../../../initial-population/initial-population 1 9 1 5 0.05 1 0.5 0.02 0.02 liberties 0.3 0.01 42 > /dev/null
	test $$(wc -c < parents/shapes/0001.ann) -eq $$(($$(wc -c < parents/liberties/0001.ann) + 24))
	! ./evolve 0.5 $(BOUNDS) parents/shapes/0001.ann parents/liberties/0001.ann feat-mixed.ann 1 > feat-mixed.out
	grep -q '^nn1.features = shapes, nn2.features = liberties$$' feat-mixed.out
	test ! -e feat-mixed.ann
	rm -rf parents cross-a.ann cross-b.ann cross-c.ann cross-d.ann cross-e.ann cross-a.out cross-d.out cross-e.out \
	  copy.ann copy.out mutated.ann mutated.out kept.ann kept.out deep.ann deep.out mixed.ann mixed.out \
	  feat-cross.ann feat-cross.out feat-copy.ann feat-copy.out feat-mutated.ann feat-mutated.out \
	  feat-flat.ann feat-flat.out feat-mixed.out

test: $(OBJS) test.o ../lib/libann.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)
	./$@

%.o: %.c
	$(CC) $(CFLAGS) -o $@ -c $<

clean:
	$(RM) *.o *.dep
	$(RM) evolve test child.ann
