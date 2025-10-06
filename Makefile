REBAR := rebar3

.PHONY: all
all: es

.PHONY: compile
compile:
	$(REBAR) compile

.PHONY: clean
clean: distclean

.PHONY: distclean
distclean:
	@rm -rf _build erl_crash.dump rebar3.crashdump src/hocon_parser.erl src/hocon_scanner.erl

.PHONY: xref
xref:
	$(REBAR) xref

.PHONY: eunit
eunit: compile
	$(REBAR) eunit -v -c
	$(REBAR) cover

.PHONY: ct
ct: compile
	$(REBAR) as test ct -v

cover:
	$(REBAR) cover

.PHONY: dialyzer
dialyzer: compile
	$(REBAR) dialyzer

.PHONY: es
es: export HOCON_ESCRIPT = true
es:
	$(REBAR) as es escriptize

.PHONY: elvis
elvis:
	./scripts/elvis-check.sh

.PHONY: fmt erlfmt
fmt: erlfmt
erlfmt:
	$(REBAR) fmt -w

.PHONY: erlfmt-check
erlfmt-check:
	$(REBAR) fmt -c
