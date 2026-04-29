EMACS ?= emacs

.PHONY: all compile test checkdoc info clean

all: compile test checkdoc info

compile:
	$(EMACS) -Q -batch -L . \
		--eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile typst-watch.el

test:
	$(EMACS) -Q -batch -L . \
		-l typst-watch.el \
		-l tests/typst-watch-tests.el \
		-f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q -batch -L . \
		--eval '(checkdoc-file "typst-watch.el")'

info:
	makeinfo doc/typst-watch.texi -o doc/typst-watch.info

clean:
	rm -f *.elc tests/*.elc doc/*.info
