-include config.mk

BUILDTYPE ?= Release
PYTHON ?= python
DESTDIR ?=
SIGN ?=
PREFIX ?= /usr/local
FLAKY_TESTS ?= run
TEST_CI_ARGS ?=
STAGINGSERVER ?= node-www
LOGLEVEL ?= silent
OSTYPE := $(shell uname -s | tr '[A-Z]' '[a-z]')
COVTESTS ?= test-cov
COV_SKIP_TESTS ?= core_line_numbers.js,testFinalizer.js,test_function/test.js
GTEST_FILTER ?= "*"
GNUMAKEFLAGS += --no-print-directory
GCOV ?= gcov
PWD = $(CURDIR)
BUILD_WITH ?= make

ifdef JOBS
	PARALLEL_ARGS = -j $(JOBS)
else
	PARALLEL_ARGS = -J
endif

ifdef ENABLE_V8_TAP
	TAP_V8 := --junitout $(PWD)/v8-tap.xml
	TAP_V8_INTL := --junitout $(PWD)/v8-intl-tap.xml
	TAP_V8_BENCHMARKS := --junitout $(PWD)/v8-benchmarks-tap.xml
endif

V8_TEST_OPTIONS = $(V8_EXTRA_TEST_OPTIONS)
ifdef DISABLE_V8_I18N
	V8_BUILD_OPTIONS += i18nsupport=off
endif

ifeq ($(OSTYPE), darwin)
	GCOV = xcrun llvm-cov gcov
endif

BUILDTYPE_LOWER := $(shell echo $(BUILDTYPE) | tr '[A-Z]' '[a-z]')

# Determine EXEEXT
EXEEXT := $(shell $(PYTHON) -c \
		"import sys; print('.exe' if sys.platform == 'win32' else '')")

NODE_EXE = node$(EXEEXT)
NODE ?= ./$(NODE_EXE)
NODE_G_EXE = node_g$(EXEEXT)
NPM ?= ./deps/npm/bin/npm-cli.js

# Flags for packaging.
BUILD_DOWNLOAD_FLAGS ?= --download=all
BUILD_INTL_FLAGS ?= --with-intl=small-icu
BUILD_RELEASE_FLAGS ?= $(BUILD_DOWNLOAD_FLAGS) $(BUILD_INTL_FLAGS)

# Default to quiet/pretty builds.
# To do verbose builds, run `make V=1` or set the V environment variable.
V ?= 0

# Use -e to double check in case it's a broken link
# Use $(PWD) so we can cd to anywhere before calling this
available-node = \
	if [ -x $(PWD)/$(NODE) ] && [ -e $(PWD)/$(NODE) ]; then \
		$(PWD)/$(NODE) $(1); \
	elif [ -x `which node` ] && [ -e `which node` ] && [ `which node` ]; then \
		`which node` $(1); \
	else \
		echo "No available node, cannot run \"node $(1)\""; \
		exit 1; \
	fi;

.PHONY: all
# BUILDTYPE=Debug builds both release and debug builds. If you want to compile
# just the debug build, run `make -C out BUILDTYPE=Debug` instead.
ifeq ($(BUILDTYPE),Release)
all: $(NODE_EXE) ## Default target, builds node in out/Release/node.
else
all: $(NODE_EXE) $(NODE_G_EXE)
endif

.PHONY: help
# To add a target to the help, add a double comment (##) on the target line.
help: ## Print help for targets with comments.
	@printf "For more targets and info see the comments in the Makefile.\n\n"
	@grep -E '^[a-zA-Z0-9._-]+:.*?## .*$$' Makefile | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

# The .PHONY is needed to ensure that we recursively use the out/Makefile
# to check for changes.
.PHONY: $(NODE_EXE) $(NODE_G_EXE)

# The -r/-L check stops it recreating the link if it is already in place,
# otherwise $(NODE_EXE) being a .PHONY target means it is always re-run.
# Without the check there is a race condition between the link being deleted
# and recreated which can break the addons build when running test-ci
# See comments on the build-addons target for some more info
ifeq ($(BUILD_WITH), make)
$(NODE_EXE): config.gypi out/Makefile
	$(MAKE) -C out BUILDTYPE=Release V=$(V)
	if [ ! -r $@ -o ! -L $@ ]; then ln -fs out/Release/$(NODE_EXE) $@; fi

$(NODE_G_EXE): config.gypi out/Makefile
	$(MAKE) -C out BUILDTYPE=Debug V=$(V)
	if [ ! -r $@ -o ! -L $@ ]; then ln -fs out/Debug/$(NODE_EXE) $@; fi
else
ifeq ($(BUILD_WITH), ninja)
ifeq ($(V),1)
	NINJA_ARGS := $(NINJA_ARGS) -v
endif
ifdef JOBS
	NINJA_ARGS := $(NINJA_ARGS) -j$(JOBS)
else
	NINJA_ARGS := $(NINJA_ARGS) $(filter -j%,$(MAKEFLAGS))
endif
$(NODE_EXE): config.gypi out/Release/build.ninja
	ninja -C out/Release $(NINJA_ARGS)
	if [ ! -r $@ -o ! -L $@ ]; then ln -fs out/Release/$(NODE_EXE) $@; fi

$(NODE_G_EXE): config.gypi out/Debug/build.ninja
	ninja -C out/Debug $(NINJA_ARGS)
	if [ ! -r $@ -o ! -L $@ ]; then ln -fs out/Debug/$(NODE_EXE) $@; fi
else
$(NODE_EXE) $(NODE_G_EXE):
	echo This Makefile currently only supports building with 'make' or 'ninja'
endif
endif


ifeq ($(BUILDTYPE),Debug)
CONFIG_FLAGS += --debug
endif

.PHONY: with-code-cache
with-code-cache:
	echo "'with-code-cache' target is a noop"

.PHONY: test-code-cache
test-code-cache: with-code-cache
	echo "'test-code-cache' target is a noop"

out/Makefile: config.gypi common.gypi node.gyp \
	deps/uv/uv.gyp deps/llhttp/llhttp.gyp deps/zlib/zlib.gyp \
	tools/v8_gypfiles/toolchain.gypi tools/v8_gypfiles/features.gypi \
	tools/v8_gypfiles/inspector.gypi tools/v8_gypfiles/v8.gyp
	$(PYTHON) tools/gyp_node.py -f make

# node_version.h is listed because the N-API version is taken from there
# and included in config.gypi
config.gypi: configure configure.py src/node_version.h
	@if [ -x config.status ]; then \
		./config.status; \
	else \
		echo Missing or stale $@, please run ./$<; \
		exit 1; \
	fi

.PHONY: install
install: all ## Installs node into $PREFIX (default=/usr/local).
	$(PYTHON) tools/install.py $@ '$(DESTDIR)' '$(PREFIX)'

.PHONY: uninstall
uninstall: ## Uninstalls node from $PREFIX (default=/usr/local).
	$(PYTHON) tools/install.py $@ '$(DESTDIR)' '$(PREFIX)'

.PHONY: clean
clean: ## Remove build artifacts.
	$(RM) -r out/Makefile $(NODE_EXE) $(NODE_G_EXE) out/$(BUILDTYPE)/$(NODE_EXE) \
		out/$(BUILDTYPE)/node.exp
	@if [ -d out ]; then find out/ -name '*.o' -o -name '*.a' -o -name '*.d' | xargs $(RM) -r; fi
	$(RM) -r node_modules
	@if [ -d deps/icu ]; then echo deleting deps/icu; $(RM) -r deps/icu; fi
	$(RM) test.tap
	$(MAKE) testclean
	$(MAKE) test-addons-clean
	$(MAKE) bench-addons-clean

.PHONY: testclean
testclean:
# Next one is legacy remove this at some point
	$(RM) -r test/tmp*
	$(RM) -r test/.tmp*

.PHONY: distclean
distclean:
	$(RM) -r out
	$(RM) config.gypi icu_config.gypi config_fips.gypi
	$(RM) config.mk
	$(RM) -r $(NODE_EXE) $(NODE_G_EXE)
	$(RM) -r node_modules
	$(RM) -r deps/icu
	$(RM) -r deps/icu4c*.tgz deps/icu4c*.zip deps/icu-tmp
	$(RM) $(BINARYTAR).* $(TARBALL).*

.PHONY: check
check: test

.PHONY: coverage-clean
# Remove files generated by running coverage, put the non-instrumented lib back
# in place
coverage-clean:
	if [ -d lib_ ]; then $(RM) -r lib; mv lib_ lib; fi
	$(RM) -r node_modules
	$(RM) -r gcovr build
	$(RM) -r out/$(BUILDTYPE)/.coverage
	$(RM) out/$(BUILDTYPE)/obj.target/node/gen/*.gcda
	$(RM) out/$(BUILDTYPE)/obj.target/node/src/*.gcda
	$(RM) out/$(BUILDTYPE)/obj.target/node/src/tracing/*.gcda
	$(RM) out/$(BUILDTYPE)/obj.target/node/gen/*.gcno
	$(RM) out/$(BUILDTYPE)/obj.target/node/src/*.gcno
	$(RM) out/$(BUILDTYPE)/obj.target/node/src/tracing/*.gcno
	$(RM) out/$(BUILDTYPE)/obj.target/cctest/src/*.gcno
	$(RM) out/$(BUILDTYPE)/obj.target/cctest/test/cctest/*.gcno

.PHONY: coverage
# Build and test with code coverage reporting.  Leave the lib directory
# instrumented for any additional runs the user may want to make.
# For C++ coverage reporting, this needs to be run in conjunction with configure
#  --coverage.  html coverage reports will be created under coverage/
# Related CI job: node-test-commit-linux-coverage
coverage: coverage-test ## Run the tests and generate a coverage report.

.PHONY: coverage-build
coverage-build: all
	-$(MAKE) coverage-build-js
	if [ ! -d gcovr ]; then git clone -b 3.4 --depth=1 \
		--single-branch https://github.com/gcovr/gcovr.git; fi
	if [ ! -d build ]; then git clone --depth=1 \
		--single-branch https://github.com/nodejs/build.git; fi
	if [ ! -f gcovr/scripts/gcovr.orig ]; then \
		(cd gcovr && patch -N -p1 < \
		"$(CURDIR)/build/jenkins/scripts/coverage/gcovr-patches-3.4.diff"); fi
	$(MAKE)

.PHONY: coverage-build-js
coverage-build-js:
	mkdir -p node_modules
	if [ ! -d node_modules/c8 ]; then \
		$(NODE) ./deps/npm install c8 --no-save --no-package-lock;\
	fi

.PHONY: coverage-test
coverage-test: coverage-build
	$(RM) out/$(BUILDTYPE)/obj.target/node/src/*.gcda
	$(RM) out/$(BUILDTYPE)/obj.target/node/src/*/*.gcda
	$(RM) out/$(BUILDTYPE)/obj.target/node_lib/src/*.gcda
	$(RM) out/$(BUILDTYPE)/obj.target/node_lib/src/*/*.gcda
	-NODE_V8_COVERAGE=out/$(BUILDTYPE)/.coverage \
								TEST_CI_ARGS="$(TEST_CI_ARGS) --type=coverage" $(MAKE) $(COVTESTS)
	$(MAKE) coverage-report-js
	-(cd out && "../gcovr/scripts/gcovr" \
		--gcov-exclude='.*\b(deps|usr|out|cctest)\b' -v -r Release/obj.target \
		--html --html-detail -o ../coverage/cxxcoverage.html \
		--gcov-executable="$(GCOV)")
	@echo -n "Javascript coverage %: "
	@grep -B1 Lines coverage/index.html | head -n1 \
		| sed 's/<[^>]*>//g'| sed 's/ //g'
	@echo -n "C++ coverage %: "
	@grep -A3 Lines coverage/cxxcoverage.html | grep style  \
		| sed 's/<[^>]*>//g'| sed 's/ //g'

COV_REPORT_OPTIONS = --reporter=html \
	--temp-directory=out/$(BUILDTYPE)/.coverage --omit-relative=false \
	--resolve=./lib --exclude="benchmark/" --exclude="deps/" --exclude="test/" --exclude="tools/" \
	--wrapper-length=0
ifdef COV_ENFORCE_THRESHOLD
	COV_REPORT_OPTIONS += --check-coverage --lines=$(COV_ENFORCE_THRESHOLD)
endif

.PHONY: coverage-report-js
coverage-report-js:
	$(NODE) ./node_modules/.bin/c8 report $(COV_REPORT_OPTIONS)

.PHONY: cctest
# Runs the C++ tests using the built `cctest` executable.
cctest: all
	@out/$(BUILDTYPE)/$@ --gtest_filter=$(GTEST_FILTER)

.PHONY: list-gtests
list-gtests:
ifeq (,$(wildcard out/$(BUILDTYPE)/cctest))
	$(error Please run 'make cctest' first)
endif
	@out/$(BUILDTYPE)/cctest --gtest_list_tests

.PHONY: v8
# Related CI job: node-test-commit-v8-linux
# Rebuilds deps/v8 as a git tree, pulls its third-party dependencies, and
# builds it.
v8:
	tools/make-v8.sh $(V8_ARCH).$(BUILDTYPE_LOWER) $(V8_BUILD_OPTIONS)

.PHONY: jstest
jstest: build-addons build-js-native-api-tests build-node-api-tests ## Runs addon tests and JS tests
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) \
		--skip-tests=$(CI_SKIP_TESTS) \
		$(CI_JS_SUITES) \
		$(CI_NATIVE_SUITES)

.PHONY: tooltest
tooltest:
	@$(PYTHON) test/tools/test-js2c.py

.PHONY: coverage-run-js
coverage-run-js:
	$(RM) -r out/$(BUILDTYPE)/.coverage
	$(MAKE) coverage-build-js
	-NODE_V8_COVERAGE=out/$(BUILDTYPE)/.coverage CI_SKIP_TESTS=$(COV_SKIP_TESTS) \
					TEST_CI_ARGS="$(TEST_CI_ARGS) --type=coverage" $(MAKE) jstest
	$(MAKE) coverage-report-js

.PHONY: test
# This does not run tests of third-party libraries inside deps.
test: all ## Runs default tests, linters, and builds docs.
	$(MAKE) -s tooltest
	$(MAKE) -s test-doc
	$(MAKE) -s build-addons
	$(MAKE) -s build-js-native-api-tests
	$(MAKE) -s build-node-api-tests
	$(MAKE) -s cctest
	$(MAKE) -s jstest

.PHONY: test-only
test-only: all  ## For a quick test, does not run linter or build docs.
	$(MAKE) build-addons
	$(MAKE) build-js-native-api-tests
	$(MAKE) build-node-api-tests
	$(MAKE) cctest
	$(MAKE) jstest
	$(MAKE) tooltest

# Used by `make coverage-test`
test-cov: all
	$(MAKE) build-addons
	$(MAKE) build-js-native-api-tests
	$(MAKE) build-node-api-tests
	$(MAKE) cctest
	CI_SKIP_TESTS=$(COV_SKIP_TESTS) $(MAKE) jstest

test-parallel: all
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) parallel

test-valgrind: all
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) --valgrind sequential parallel message

test-check-deopts: all
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) --check-deopts parallel sequential

benchmark/napi/function_call/build/$(BUILDTYPE)/binding.node: \
		benchmark/napi/function_call/napi_binding.c \
		benchmark/napi/function_call/binding.cc \
		benchmark/napi/function_call/binding.gyp | all
	$(NODE) deps/npm/node_modules/node-gyp/bin/node-gyp rebuild \
		--python="$(PYTHON)" \
		--directory="$(shell pwd)/benchmark/napi/function_call" \
		--nodedir="$(shell pwd)"

benchmark/napi/function_args/build/$(BUILDTYPE)/binding.node: \
		benchmark/napi/function_args/napi_binding.c \
		benchmark/napi/function_args/binding.cc \
		benchmark/napi/function_args/binding.gyp | all
	$(NODE) deps/npm/node_modules/node-gyp/bin/node-gyp rebuild \
		--python="$(PYTHON)" \
		--directory="$(shell pwd)/benchmark/napi/function_args" \
		--nodedir="$(shell pwd)"

DOCBUILDSTAMP_PREREQS = tools/doc/addon-verify.js doc/api/addons.md

ifeq ($(OSTYPE),aix)
DOCBUILDSTAMP_PREREQS := $(DOCBUILDSTAMP_PREREQS) out/$(BUILDTYPE)/node.exp
endif

node_use_openssl = $(call available-node,"-p" \
			 "process.versions.openssl != undefined")
test/addons/.docbuildstamp: $(DOCBUILDSTAMP_PREREQS) tools/doc/node_modules
	@if [ "$(shell $(node_use_openssl))" != "true" ]; then \
		echo "Skipping .docbuildstamp (no crypto)"; \
	else \
		$(RM) -r test/addons/??_*/; \
		[ -x $(NODE) ] && $(NODE) $< || node $< ; \
		touch $@; \
	fi

ADDONS_BINDING_GYPS := \
	$(filter-out test/addons/??_*/binding.gyp, \
		$(wildcard test/addons/*/binding.gyp))

ADDONS_BINDING_SOURCES := \
	$(filter-out test/addons/??_*/*.cc, $(wildcard test/addons/*/*.cc)) \
	$(filter-out test/addons/??_*/*.h, $(wildcard test/addons/*/*.h))

ADDONS_PREREQS := config.gypi \
	deps/npm/node_modules/node-gyp/package.json tools/build-addons.js \
	deps/uv/include/*.h deps/v8/include/*.h \
	src/node.h src/node_buffer.h src/node_object_wrap.h src/node_version.h

define run_build_addons
env npm_config_loglevel=$(LOGLEVEL) npm_config_nodedir="$$PWD" \
	npm_config_python="$(PYTHON)" $(NODE) "$$PWD/tools/build-addons" \
	"$$PWD/deps/npm/node_modules/node-gyp/bin/node-gyp.js" \
	$1
touch $2
endef

# Implicitly depends on $(NODE_EXE), see the build-addons rule for rationale.
# Depends on node-gyp package.json so that build-addons is (re)executed when
# node-gyp is updated as part of an npm update.
test/addons/.buildstamp: $(ADDONS_PREREQS) \
	$(ADDONS_BINDING_GYPS) $(ADDONS_BINDING_SOURCES) \
	test/addons/.docbuildstamp
	@$(call run_build_addons,"$$PWD/test/addons",$@)

.PHONY: build-addons
# .buildstamp needs $(NODE_EXE) but cannot depend on it
# directly because it calls make recursively.  The parent make cannot know
# if the subprocess touched anything so it pessimistically assumes that
# .buildstamp is out of date and need a rebuild.
# Just goes to show that recursive make really is harmful...
# TODO(bnoordhuis) Force rebuild after gyp update.
build-addons: | $(NODE_EXE) test/addons/.buildstamp

JS_NATIVE_API_BINDING_GYPS := \
	$(filter-out test/js-native-api/??_*/binding.gyp, \
		$(wildcard test/js-native-api/*/binding.gyp))

JS_NATIVE_API_BINDING_SOURCES := \
	$(filter-out test/js-native-api/??_*/*.c, $(wildcard test/js-native-api/*/*.c)) \
	$(filter-out test/js-native-api/??_*/*.cc, $(wildcard test/js-native-api/*/*.cc)) \
	$(filter-out test/js-native-api/??_*/*.h, $(wildcard test/js-native-api/*/*.h))

# Implicitly depends on $(NODE_EXE), see the build-js-native-api-tests rule for rationale.
test/js-native-api/.buildstamp: $(ADDONS_PREREQS) \
	$(JS_NATIVE_API_BINDING_GYPS) $(JS_NATIVE_API_BINDING_SOURCES) \
	src/node_api.h src/node_api_types.h src/js_native_api.h \
	src/js_native_api_types.h src/js_native_api_v8.h src/js_native_api_v8_internals.h
	@$(call run_build_addons,"$$PWD/test/js-native-api",$@)

.PHONY: build-js-native-api-tests
# .buildstamp needs $(NODE_EXE) but cannot depend on it
# directly because it calls make recursively.  The parent make cannot know
# if the subprocess touched anything so it pessimistically assumes that
# .buildstamp is out of date and need a rebuild.
# Just goes to show that recursive make really is harmful...
# TODO(bnoordhuis) Force rebuild after gyp or node-gyp update.
build-js-native-api-tests: | $(NODE_EXE) test/js-native-api/.buildstamp

NODE_API_BINDING_GYPS := \
	$(filter-out test/node-api/??_*/binding.gyp, \
		$(wildcard test/node-api/*/binding.gyp))

NODE_API_BINDING_SOURCES := \
	$(filter-out test/node-api/??_*/*.c, $(wildcard test/node-api/*/*.c)) \
	$(filter-out test/node-api/??_*/*.cc, $(wildcard test/node-api/*/*.cc)) \
	$(filter-out test/node-api/??_*/*.h, $(wildcard test/node-api/*/*.h))

# Implicitly depends on $(NODE_EXE), see the build-node-api-tests rule for rationale.
test/node-api/.buildstamp: $(ADDONS_PREREQS) \
	$(NODE_API_BINDING_GYPS) $(NODE_API_BINDING_SOURCES) \
	src/node_api.h src/node_api_types.h src/js_native_api.h \
	src/js_native_api_types.h src/js_native_api_v8.h src/js_native_api_v8_internals.h
	@$(call run_build_addons,"$$PWD/test/node-api",$@)

.PHONY: build-node-api-tests
# .buildstamp needs $(NODE_EXE) but cannot depend on it
# directly because it calls make recursively.  The parent make cannot know
# if the subprocess touched anything so it pessimistically assumes that
# .buildstamp is out of date and need a rebuild.
# Just goes to show that recursive make really is harmful...
# TODO(bnoordhuis) Force rebuild after gyp or node-gyp update.
build-node-api-tests: | $(NODE_EXE) test/node-api/.buildstamp

.PHONY: clear-stalled
clear-stalled:
	@echo "Clean up any leftover processes but don't error if found."
	ps awwx | grep Release/node | grep -v grep | cat
	@PS_OUT=`ps awwx | grep Release/node | grep -v grep | awk '{print $$1}'`; \
	if [ "$${PS_OUT}" ]; then \
		echo $${PS_OUT} | xargs kill -9; \
	fi

test-build: | all build-addons build-js-native-api-tests build-node-api-tests

test-build-js-native-api: all build-js-native-api-tests

test-build-node-api: all build-node-api-tests

.PHONY: test-all
test-all: test-build ## Run default tests with both Debug and Release builds.
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=debug,release

test-all-valgrind: test-build
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=debug,release --valgrind

.PHONY: test-all-suites
test-all-suites: | clear-stalled test-build bench-addons-build doc-only ## Run all test suites.
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) test/*

CI_NATIVE_SUITES ?= addons js-native-api node-api
CI_JS_SUITES ?= default
ifeq ($(node_use_openssl), false)
	CI_DOC := doctool
else
	CI_DOC =
endif

.PHONY: test-ci-native
# Build and test addons without building anything else
# Related CI job: node-test-commit-arm-fanned
test-ci-native: LOGLEVEL := info
test-ci-native: | test/addons/.buildstamp test/js-native-api/.buildstamp test/node-api/.buildstamp
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) -p tap --logfile test.tap \
		--mode=$(BUILDTYPE_LOWER) --flaky-tests=$(FLAKY_TESTS) \
		$(TEST_CI_ARGS) $(CI_NATIVE_SUITES)

.PHONY: test-ci-js
# This target should not use a native compiler at all
# Related CI job: node-test-commit-arm-fanned
test-ci-js: | clear-stalled
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) -p tap --logfile test.tap \
		--mode=$(BUILDTYPE_LOWER) --flaky-tests=$(FLAKY_TESTS) \
		$(TEST_CI_ARGS) $(CI_JS_SUITES)
	@echo "Clean up any leftover processes, error if found."
	ps awwx | grep Release/node | grep -v grep | cat
	@PS_OUT=`ps awwx | grep Release/node | grep -v grep | awk '{print $$1}'`; \
	if [ "$${PS_OUT}" ]; then \
		echo $${PS_OUT} | xargs kill -9; exit 1; \
	fi

.PHONY: test-ci
# Related CI jobs: most CI tests, excluding node-test-commit-arm-fanned
test-ci: LOGLEVEL := info
test-ci: | clear-stalled build-addons build-js-native-api-tests build-node-api-tests doc-only
	out/Release/cctest --gtest_output=xml:out/junit/cctest.xml
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) -p tap --logfile test.tap \
		--mode=$(BUILDTYPE_LOWER) --flaky-tests=$(FLAKY_TESTS) \
		$(TEST_CI_ARGS) $(CI_JS_SUITES) $(CI_NATIVE_SUITES) $(CI_DOC)
	@echo "Clean up any leftover processes, error if found."
	ps awwx | grep Release/node | grep -v grep | cat
	@PS_OUT=`ps awwx | grep Release/node | grep -v grep | awk '{print $$1}'`; \
	if [ "$${PS_OUT}" ]; then \
		echo $${PS_OUT} | xargs kill -9; exit 1; \
	fi

.PHONY: build-ci
# Prepare the build for running the tests.
# Related CI jobs: most CI tests, excluding node-test-commit-arm-fanned
build-ci:
	$(PYTHON) ./configure --verbose $(CONFIG_FLAGS)
	$(MAKE)

.PHONY: run-ci
# Run by CI tests, exceptions:
# - node-test-commit-arm-fanned (Raspberry Pis), where the binaries are
#   cross-compiled, then transferred elsewhere to run different subsets
#   of tests. See `test-ci-native` and `test-ci-js`.
# - node-test-commit-linux-coverage: where the build and the tests need
#   to be instrumented, see `coverage`.
#
# Using -j1 as the sub target in `test-ci` already have internal parallelism.
# Refs: https://github.com/nodejs/node/pull/23733
run-ci: build-ci
	$(MAKE) test-ci -j1

test-release: test-build
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER)

test-debug: test-build
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=debug

test-message: test-build
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) message

test-wpt: all
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) wpt

test-simple: | cctest # Depends on 'all'.
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) parallel sequential

test-pummel: all
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) pummel

test-internet: all
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) internet

test-node-inspect: $(NODE_EXE)
	USE_EMBEDDED_NODE_INSPECT=1 $(NODE) tools/test-npm-package \
		--install deps/node-inspect test

test-benchmark: | bench-addons-build
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) benchmark

test-tick-processor: all
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) tick-processor

.PHONY: test-hash-seed
# Verifies the hash seed used by V8 for hashing is random.
test-hash-seed: all
	$(NODE) test/pummel/test-hash-seed.js

.PHONY: test-doc
test-doc: doc-only ## Builds, lints, and verifies the docs.
	@if [ "$(shell $(node_use_openssl))" != "true" ]; then \
		echo "Skipping test-doc (no crypto)"; \
	else \
		$(MAKE) lint; \
		$(PYTHON) tools/test.py $(PARALLEL_ARGS) doctool; \
	fi

test-known-issues: all
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) known_issues

# Related CI job: node-test-npm
test-npm: $(NODE_EXE) ## Run the npm test suite on deps/npm.
	$(NODE) tools/test-npm-package --install --logfile=test-npm.tap deps/npm test-node

test-npm-publish: $(NODE_EXE)
	npm_package_config_publishtest=true $(NODE) deps/npm/test/run.js

.PHONY: test-js-native-api
test-js-native-api: test-build-js-native-api
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) js-native-api

.PHONY: test-js-native-api-clean
test-js-native-api-clean:
	$(RM) -r test/js-native-api/*/build
	$(RM) test/js-native-api/.buildstamp

.PHONY: test-node-api
test-node-api: test-build-node-api
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) node-api

.PHONY: test-node-api-clean
test-node-api-clean:
	$(RM) -r test/node-api/*/build
	$(RM) test/node-api/.buildstamp

.PHONY: test-addons
test-addons: test-build test-js-native-api test-node-api
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) addons

.PHONY: test-addons-clean
test-addons-clean:
	$(RM) -r test/addons/??_*/
	$(RM) -r test/addons/*/build
	$(RM) test/addons/.buildstamp test/addons/.docbuildstamp
	$(MAKE) test-js-native-api-clean
	$(MAKE) test-node-api-clean

test-async-hooks:
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) async-hooks

test-with-async-hooks:
	$(MAKE) build-addons
	$(MAKE) build-js-native-api-tests
	$(MAKE) build-node-api-tests
	$(MAKE) cctest
	NODE_TEST_WITH_ASYNC_HOOKS=1 $(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) \
		$(CI_JS_SUITES) \
		$(CI_NATIVE_SUITES)


.PHONY: test-v8
.PHONY: test-v8-all
.PHONY: test-v8-benchmarks
.PHONY: test-v8-intl
.PHONY: test-v8-updates
ifneq ("","$(wildcard deps/v8/tools/run-tests.py)")
# Related CI job: node-test-commit-v8-linux
test-v8: v8  ## Runs the V8 test suite on deps/v8.
	deps/v8/tools/run-tests.py --gn --arch=$(V8_ARCH) \
				--mode=$(BUILDTYPE_LOWER) $(V8_TEST_OPTIONS) \
				mjsunit cctest debugger inspector message preparser \
				$(TAP_V8)
	@echo Testing hash seed
	$(MAKE) test-hash-seed

test-v8-intl: v8
	deps/v8/tools/run-tests.py --gn --arch=$(V8_ARCH) \
				--mode=$(BUILDTYPE_LOWER) intl \
				$(TAP_V8_INTL)

test-v8-benchmarks: v8
	deps/v8/tools/run-tests.py --gn --arch=$(V8_ARCH) --mode=$(BUILDTYPE_LOWER) \
				benchmarks \
				$(TAP_V8_BENCHMARKS)

test-v8-updates:
	$(PYTHON) tools/test.py $(PARALLEL_ARGS) --mode=$(BUILDTYPE_LOWER) v8-updates

test-v8-all: test-v8 test-v8-intl test-v8-benchmarks test-v8-updates
# runs all v8 tests
else
test-v8 test-v8-intl test-v8-benchmarks test-v8-all:
	@echo "Testing v8 is not available through the source tarball."
	@echo "Use the git repo instead:" \
		"$ git clone https://github.com/nodejs/node.git"
endif

apidoc_dirs = out/doc out/doc/api out/doc/api/assets
apidoc_sources = $(wildcard doc/api/*.md)
apidocs_html = $(addprefix out/,$(apidoc_sources:.md=.html))
apidocs_json = $(addprefix out/,$(apidoc_sources:.md=.json))

apiassets = $(subst api_assets,api/assets,$(addprefix out/,$(wildcard doc/api_assets/*)))

tools/doc/node_modules: tools/doc/package.json
	@if [ "$(shell $(node_use_openssl))" != "true" ]; then \
		echo "Skipping tools/doc/node_modules (no crypto)"; \
	else \
		cd tools/doc && $(call available-node,$(run-npm-ci)) \
	fi

.PHONY: doc-only
doc-only: tools/doc/node_modules \
	$(apidoc_dirs) $(apiassets)  ## Builds the docs with the local or the global Node.js binary.
	@if [ "$(shell $(node_use_openssl))" != "true" ]; then \
		echo "Skipping doc-only (no crypto)"; \
	else \
		$(MAKE) out/doc/api/all.html out/doc/api/all.json; \
	fi

.PHONY: doc
doc: $(NODE_EXE) doc-only

out/doc:
	mkdir -p $@

# If it's a source tarball, doc/api already contains the generated docs.
# Just copy everything under doc/api over.
out/doc/api: doc/api
	mkdir -p $@
	cp -r doc/api out/doc

# If it's a source tarball, assets are already in doc/api/assets
out/doc/api/assets:
	mkdir -p $@
	if [ -d doc/api/assets ]; then cp -r doc/api/assets out/doc/api; fi;

# If it's not a source tarball, we need to copy assets from doc/api_assets
out/doc/api/assets/%: doc/api_assets/% out/doc/api/assets
	@cp $< $@


run-npm-ci = $(PWD)/$(NPM) ci

LINK_DATA = out/doc/apilinks.json
gen-api = tools/doc/generate.js --node-version=$(FULLVERSION) \
		--apilinks=$(LINK_DATA) $< --output-directory=out/doc/api
gen-apilink = tools/doc/apilinks.js $(LINK_DATA) $(wildcard lib/*.js)

$(LINK_DATA): $(wildcard lib/*.js) tools/doc/apilinks.js
	$(call available-node, $(gen-apilink))

out/doc/api/%.json out/doc/api/%.html: doc/api/%.md tools/doc/generate.js \
	tools/doc/html.js tools/doc/json.js tools/doc/apilinks.js | $(LINK_DATA)
	$(call available-node, $(gen-api))

out/doc/api/all.html: $(apidocs_html) tools/doc/allhtml.js \
	tools/doc/apilinks.js
	$(call available-node, tools/doc/allhtml.js)

out/doc/api/all.json: $(apidocs_json) tools/doc/alljson.js
	$(call available-node, tools/doc/alljson.js)

.PHONY: docopen
docopen: $(apidocs_html)
	@$(PYTHON) -mwebbrowser file://$(PWD)/out/doc/api/all.html

.PHONY: docclean
docclean:
	$(RM) -r out/doc

RAWVER=$(shell $(PYTHON) tools/getnodeversion.py)
VERSION=v$(RAWVER)

# For nightly builds, you must set DISTTYPE to "nightly", "next-nightly" or
# "custom". For the nightly and next-nightly case, you need to set DATESTRING
# and COMMIT in order to properly name the build.
# For the rc case you need to set CUSTOMTAG to an appropriate CUSTOMTAG number

ifndef DISTTYPE
DISTTYPE=release
endif
ifeq ($(DISTTYPE),release)
FULLVERSION=$(VERSION)
else # ifeq ($(DISTTYPE),release)
ifeq ($(DISTTYPE),custom)
ifndef CUSTOMTAG
$(error CUSTOMTAG is not set for DISTTYPE=custom)
endif # ifndef CUSTOMTAG
TAG=$(CUSTOMTAG)
else # ifeq ($(DISTTYPE),custom)
ifndef DATESTRING
$(error DATESTRING is not set for nightly)
endif # ifndef DATESTRING
ifndef COMMIT
$(error COMMIT is not set for nightly)
endif # ifndef COMMIT
ifneq ($(DISTTYPE),nightly)
ifneq ($(DISTTYPE),next-nightly)
$(error DISTTYPE is not release, custom, nightly or next-nightly)
endif # ifneq ($(DISTTYPE),next-nightly)
endif # ifneq ($(DISTTYPE),nightly)
TAG=$(DISTTYPE)$(DATESTRING)$(COMMIT)
endif # ifeq ($(DISTTYPE),custom)
FULLVERSION=$(VERSION)-$(TAG)
endif # ifeq ($(DISTTYPE),release)

DISTTYPEDIR ?= $(DISTTYPE)
RELEASE=$(shell sed -ne 's/\#define NODE_VERSION_IS_RELEASE \([01]\)/\1/p' src/node_version.h)
PLATFORM=$(shell uname | tr '[:upper:]' '[:lower:]')
NPMVERSION=v$(shell cat deps/npm/package.json | grep '"version"' | sed 's/^[^:]*: "\([^"]*\)",.*/\1/')

UNAME_M=$(shell uname -m)
ifeq ($(findstring x86_64,$(UNAME_M)),x86_64)
DESTCPU ?= x64
else
ifeq ($(findstring amd64,$(UNAME_M)),amd64)
DESTCPU ?= x64
else
ifeq ($(findstring ppc64,$(UNAME_M)),ppc64)
DESTCPU ?= ppc64
else
ifeq ($(findstring ppc,$(UNAME_M)),ppc)
DESTCPU ?= ppc
else
ifeq ($(findstring s390x,$(UNAME_M)),s390x)
DESTCPU ?= s390x
else
ifeq ($(findstring s390,$(UNAME_M)),s390)
DESTCPU ?= s390
else
ifeq ($(findstring arm,$(UNAME_M)),arm)
DESTCPU ?= arm
else
ifeq ($(findstring aarch64,$(UNAME_M)),aarch64)
DESTCPU ?= arm64
else
ifeq ($(findstring powerpc,$(shell uname -p)),powerpc)
DESTCPU ?= ppc64
else
DESTCPU ?= x86
endif
endif
endif
endif
endif
endif
endif
endif
ifeq ($(DESTCPU),x64)
ARCH=x64
else
ifeq ($(DESTCPU),arm)
ARCH=arm
else
ifeq ($(DESTCPU),arm64)
ARCH=arm64
else
ifeq ($(DESTCPU),ppc64)
ARCH=ppc64
else
ifeq ($(DESTCPU),ppc)
ARCH=ppc
else
ifeq ($(DESTCPU),s390)
ARCH=s390
else
ifeq ($(DESTCPU),s390x)
ARCH=s390x
else
ARCH=x86
endif
endif
endif
endif
endif
endif
endif
endif

# node and v8 use different arch names (e.g. node 'x86' vs v8 'ia32').
# pass the proper v8 arch name to $V8_ARCH based on user-specified $DESTCPU.
ifeq ($(DESTCPU),x86)
V8_ARCH=ia32
else
V8_ARCH ?= $(DESTCPU)

endif

# enforce "x86" over "ia32" as the generally accepted way of referring to 32-bit intel
ifeq ($(ARCH),ia32)
override ARCH=x86
endif
ifeq ($(DESTCPU),ia32)
override DESTCPU=x86
endif

TARNAME=node-$(FULLVERSION)
TARBALL=$(TARNAME).tar
# Custom user-specified variation, use it directly
ifdef VARIATION
BINARYNAME=$(TARNAME)-$(PLATFORM)-$(ARCH)-$(VARIATION)
else
BINARYNAME=$(TARNAME)-$(PLATFORM)-$(ARCH)
endif
BINARYTAR=$(BINARYNAME).tar
# OSX doesn't have xz installed by default, http://macpkg.sourceforge.net/
HAS_XZ ?= $(shell which xz > /dev/null 2>&1; [ $$? -eq 0 ] && echo 1 || echo 0)
# Supply SKIP_XZ=1 to explicitly skip .tar.xz creation
SKIP_XZ ?= 0
XZ = $(shell [ $(HAS_XZ) -eq 1 -a $(SKIP_XZ) -eq 0 ] && echo 1 || echo 0)
XZ_COMPRESSION ?= 9e
PKG=$(TARNAME).pkg
MACOSOUTDIR=out/macos

ifeq ($(SKIP_XZ), 1)
check-xz:
	@echo "SKIP_XZ=1 supplied, skipping .tar.xz creation"
else
ifeq ($(HAS_XZ), 1)
check-xz:
else
check-xz:
	@echo "No xz command, cannot continue"
	@exit 1
endif
endif

.PHONY: release-only
release-only: check-xz
	@if [ "$(DISTTYPE)" = "release" ] && `grep -q REPLACEME doc/api/*.md`; then \
		echo 'Please update REPLACEME in Added: tags in doc/api/*.md (See doc/releases.md)' ; \
		exit 1 ; \
	fi
	@if [ "$(DISTTYPE)" = "release" ] && \
		`grep -q DEP...X doc/api/deprecations.md`; then \
		echo 'Please update DEP...X in doc/api/deprecations.md (See doc/releases.md)' ; \
		exit 1 ; \
	fi
	@if [ "$(shell git status --porcelain | egrep -v '^\?\? ')" = "" ]; then \
		exit 0 ; \
	else \
		echo "" >&2 ; \
		echo "The git repository is not clean." >&2 ; \
		echo "Please commit changes before building release tarball." >&2 ; \
		echo "" >&2 ; \
		git status --porcelain | egrep -v '^\?\?' >&2 ; \
		echo "" >&2 ; \
		exit 1 ; \
	fi
	@if [ "$(DISTTYPE)" != "release" -o "$(RELEASE)" = "1" ]; then \
		exit 0; \
	else \
		echo "" >&2 ; \
		echo "#NODE_VERSION_IS_RELEASE is set to $(RELEASE)." >&2 ; \
		echo "Did you remember to update src/node_version.h?" >&2 ; \
		echo "" >&2 ; \
		exit 1 ; \
	fi

$(PKG): release-only
	$(RM) -r $(MACOSOUTDIR)
	mkdir -p $(MACOSOUTDIR)/installer/productbuild
	cat tools/macos-installer/productbuild/distribution.xml.tmpl  \
		| sed -E "s/\\{nodeversion\\}/$(FULLVERSION)/g" \
		| sed -E "s/\\{npmversion\\}/$(NPMVERSION)/g" \
	>$(MACOSOUTDIR)/installer/productbuild/distribution.xml ; \

	@for dirname in tools/macos-installer/productbuild/Resources/*/; do \
		lang=$$(basename $$dirname) ; \
		mkdir -p $(MACOSOUTDIR)/installer/productbuild/Resources/$$lang ; \
		printf "Found localization directory $$dirname\n" ; \
		cat $$dirname/welcome.html.tmpl  \
			| sed -E "s/\\{nodeversion\\}/$(FULLVERSION)/g" \
			| sed -E "s/\\{npmversion\\}/$(NPMVERSION)/g"  \
		>$(MACOSOUTDIR)/installer/productbuild/Resources/$$lang/welcome.html ; \
		cat $$dirname/conclusion.html.tmpl  \
			| sed -E "s/\\{nodeversion\\}/$(FULLVERSION)/g" \
			| sed -E "s/\\{npmversion\\}/$(NPMVERSION)/g"  \
		>$(MACOSOUTDIR)/installer/productbuild/Resources/$$lang/conclusion.html ; \
	done
	$(PYTHON) ./configure \
		--dest-cpu=x64 \
		--tag=$(TAG) \
		--release-urlbase=$(RELEASE_URLBASE) \
		$(CONFIG_FLAGS) $(BUILD_RELEASE_FLAGS)
	$(MAKE) install V=$(V) DESTDIR=$(MACOSOUTDIR)/dist/node
	SIGN="$(CODESIGN_CERT)" PKGDIR="$(MACOSOUTDIR)/dist/node/usr/local" bash \
		tools/osx-codesign.sh
	mkdir -p $(MACOSOUTDIR)/dist/npm/usr/local/lib/node_modules
	mkdir -p $(MACOSOUTDIR)/pkgs
	mv $(MACOSOUTDIR)/dist/node/usr/local/lib/node_modules/npm \
		$(MACOSOUTDIR)/dist/npm/usr/local/lib/node_modules
	unlink $(MACOSOUTDIR)/dist/node/usr/local/bin/npm
	unlink $(MACOSOUTDIR)/dist/node/usr/local/bin/npx
	$(NODE) tools/license2rtf.js < LICENSE > \
		$(MACOSOUTDIR)/installer/productbuild/Resources/license.rtf
	cp doc/osx_installer_logo.png $(MACOSOUTDIR)/installer/productbuild/Resources
	pkgbuild --version $(FULLVERSION) \
		--identifier org.nodejs.node.pkg \
		--root $(MACOSOUTDIR)/dist/node $(MACOSOUTDIR)/pkgs/node-$(FULLVERSION).pkg
	pkgbuild --version $(NPMVERSION) \
		--identifier org.nodejs.npm.pkg \
		--root $(MACOSOUTDIR)/dist/npm \
		--scripts ./tools/macos-installer/pkgbuild/npm/scripts \
			$(MACOSOUTDIR)/pkgs/npm-$(NPMVERSION).pkg
	productbuild --distribution $(MACOSOUTDIR)/installer/productbuild/distribution.xml \
		--resources $(MACOSOUTDIR)/installer/productbuild/Resources \
		--package-path $(MACOSOUTDIR)/pkgs ./$(PKG)
	SIGN="$(PRODUCTSIGN_CERT)" PKG="$(PKG)" bash tools/osx-productsign.sh

.PHONY: pkg
# Builds the macOS installer for releases.
pkg: $(PKG)

# Note: this is strictly for release builds on release machines only.
pkg-upload: pkg
	ssh $(STAGINGSERVER) "mkdir -p nodejs/$(DISTTYPEDIR)/$(FULLVERSION)"
	chmod 664 $(TARNAME).pkg
	scp -p $(TARNAME).pkg $(STAGINGSERVER):nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME).pkg
	ssh $(STAGINGSERVER) "touch nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME).pkg.done"

$(TARBALL): release-only $(NODE_EXE) doc
	git checkout-index -a -f --prefix=$(TARNAME)/
	mkdir -p $(TARNAME)/doc/api
	cp doc/node.1 $(TARNAME)/doc/node.1
	cp -r out/doc/api/* $(TARNAME)/doc/api/
	$(RM) -r $(TARNAME)/.editorconfig
	$(RM) -r $(TARNAME)/.git*
	$(RM) -r $(TARNAME)/.mailmap
	$(RM) -r $(TARNAME)/deps/openssl/openssl/demos
	$(RM) -r $(TARNAME)/deps/openssl/openssl/doc
	$(RM) -r $(TARNAME)/deps/openssl/openssl/test
	$(RM) -r $(TARNAME)/deps/uv/docs
	$(RM) -r $(TARNAME)/deps/uv/samples
	$(RM) -r $(TARNAME)/deps/uv/test
	$(RM) -r $(TARNAME)/deps/v8/samples
	$(RM) -r $(TARNAME)/deps/v8/test
	$(RM) -r $(TARNAME)/deps/v8/tools/profviz
	$(RM) -r $(TARNAME)/deps/v8/tools/run-tests.py
	$(RM) -r $(TARNAME)/deps/zlib/contrib # too big, unused
	$(RM) -r $(TARNAME)/doc/images # too big
	$(RM) -r $(TARNAME)/test*.tap
	$(RM) -r $(TARNAME)/tools/cpplint.py
	$(RM) -r $(TARNAME)/tools/eslint-rules
	$(RM) -r $(TARNAME)/tools/license-builder.sh
	$(RM) -r $(TARNAME)/tools/node_modules
	$(RM) -r $(TARNAME)/tools/osx-*
	$(RM) -r $(TARNAME)/tools/osx-pkg.pmdoc
	find $(TARNAME)/ -name ".eslint*" -maxdepth 2 | xargs $(RM)
	find $(TARNAME)/ -type l | xargs $(RM) # annoying on windows
	tar -cf $(TARNAME).tar $(TARNAME)
	$(RM) -r $(TARNAME)
	gzip -c -f -9 $(TARNAME).tar > $(TARNAME).tar.gz
ifeq ($(XZ), 1)
	xz -c -f -$(XZ_COMPRESSION) $(TARNAME).tar > $(TARNAME).tar.xz
endif
	$(RM) $(TARNAME).tar

.PHONY: tar
tar: $(TARBALL) ## Create a source tarball.

# Note: this is strictly for release builds on release machines only.
tar-upload: tar
	ssh $(STAGINGSERVER) "mkdir -p nodejs/$(DISTTYPEDIR)/$(FULLVERSION)"
	chmod 664 $(TARNAME).tar.gz
	scp -p $(TARNAME).tar.gz $(STAGINGSERVER):nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME).tar.gz
	ssh $(STAGINGSERVER) "touch nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME).tar.gz.done"
ifeq ($(XZ), 1)
	chmod 664 $(TARNAME).tar.xz
	scp -p $(TARNAME).tar.xz $(STAGINGSERVER):nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME).tar.xz
	ssh $(STAGINGSERVER) "touch nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME).tar.xz.done"
endif

# Note: this is strictly for release builds on release machines only.
doc-upload: doc
	ssh $(STAGINGSERVER) "mkdir -p nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/docs/"
	chmod -R ug=rw-x+X,o=r+X out/doc/
	scp -pr out/doc/* $(STAGINGSERVER):nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/docs/
	ssh $(STAGINGSERVER) "touch nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/docs.done"

.PHONY: $(TARBALL)-headers
$(TARBALL)-headers: release-only
	$(PYTHON) ./configure \
		--prefix=/ \
		--dest-cpu=$(DESTCPU) \
		--tag=$(TAG) \
		--release-urlbase=$(RELEASE_URLBASE) \
		$(CONFIG_FLAGS) $(BUILD_RELEASE_FLAGS)
	HEADERS_ONLY=1 $(PYTHON) tools/install.py install '$(TARNAME)' '/'
	find $(TARNAME)/ -type l | xargs $(RM)
	tar -cf $(TARNAME)-headers.tar $(TARNAME)
	$(RM) -r $(TARNAME)
	gzip -c -f -9 $(TARNAME)-headers.tar > $(TARNAME)-headers.tar.gz
ifeq ($(XZ), 1)
	xz -c -f -$(XZ_COMPRESSION) $(TARNAME)-headers.tar > $(TARNAME)-headers.tar.xz
endif
	$(RM) $(TARNAME)-headers.tar

tar-headers: $(TARBALL)-headers ## Build the node header tarball.

tar-headers-upload: tar-headers
	ssh $(STAGINGSERVER) "mkdir -p nodejs/$(DISTTYPEDIR)/$(FULLVERSION)"
	chmod 664 $(TARNAME)-headers.tar.gz
	scp -p $(TARNAME)-headers.tar.gz $(STAGINGSERVER):nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME)-headers.tar.gz
	ssh $(STAGINGSERVER) "touch nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME)-headers.tar.gz.done"
ifeq ($(XZ), 1)
	chmod 664 $(TARNAME)-headers.tar.xz
	scp -p $(TARNAME)-headers.tar.xz $(STAGINGSERVER):nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME)-headers.tar.xz
	ssh $(STAGINGSERVER) "touch nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME)-headers.tar.xz.done"
endif

$(BINARYTAR): release-only
	$(RM) -r $(BINARYNAME)
	$(RM) -r out/deps out/Release
	$(PYTHON) ./configure \
		--prefix=/ \
		--dest-cpu=$(DESTCPU) \
		--tag=$(TAG) \
		--release-urlbase=$(RELEASE_URLBASE) \
		$(CONFIG_FLAGS) $(BUILD_RELEASE_FLAGS)
	$(MAKE) install DESTDIR=$(BINARYNAME) V=$(V) PORTABLE=1
	cp README.md $(BINARYNAME)
	cp LICENSE $(BINARYNAME)
	cp CHANGELOG.md $(BINARYNAME)
ifeq ($(OSTYPE),darwin)
	SIGN="$(CODESIGN_CERT)" PKGDIR="$(BINARYNAME)" bash tools/osx-codesign.sh
endif
	tar -cf $(BINARYNAME).tar $(BINARYNAME)
	$(RM) -r $(BINARYNAME)
	gzip -c -f -9 $(BINARYNAME).tar > $(BINARYNAME).tar.gz
ifeq ($(XZ), 1)
	xz -c -f -$(XZ_COMPRESSION) $(BINARYNAME).tar > $(BINARYNAME).tar.xz
endif
	$(RM) $(BINARYNAME).tar

.PHONY: binary
# This requires NODE_VERSION_IS_RELEASE defined as 1 in src/node_version.h.
binary: $(BINARYTAR) ## Build release binary tarballs.

# Note: this is strictly for release builds on release machines only.
binary-upload: binary
	ssh $(STAGINGSERVER) "mkdir -p nodejs/$(DISTTYPEDIR)/$(FULLVERSION)"
	chmod 664 $(TARNAME)-$(OSTYPE)-$(ARCH).tar.gz
	scp -p $(TARNAME)-$(OSTYPE)-$(ARCH).tar.gz $(STAGINGSERVER):nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME)-$(OSTYPE)-$(ARCH).tar.gz
	ssh $(STAGINGSERVER) "touch nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME)-$(OSTYPE)-$(ARCH).tar.gz.done"
ifeq ($(XZ), 1)
	chmod 664 $(TARNAME)-$(OSTYPE)-$(ARCH).tar.xz
	scp -p $(TARNAME)-$(OSTYPE)-$(ARCH).tar.xz $(STAGINGSERVER):nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME)-$(OSTYPE)-$(ARCH).tar.xz
	ssh $(STAGINGSERVER) "touch nodejs/$(DISTTYPEDIR)/$(FULLVERSION)/$(TARNAME)-$(OSTYPE)-$(ARCH).tar.xz.done"
endif

.PHONY: bench-all
bench-all: bench-addons-build
	@echo "Please use benchmark/run.js or benchmark/compare.js to run the benchmarks."

.PHONY: bench
bench: bench-addons-build
	@echo "Please use benchmark/run.js or benchmark/compare.js to run the benchmarks."

# Build required addons for benchmark before running it.
.PHONY: bench-addons-build
bench-addons-build: benchmark/napi/function_call/build/$(BUILDTYPE)/binding.node \
	benchmark/napi/function_args/build/$(BUILDTYPE)/binding.node

.PHONY: bench-addons-clean
bench-addons-clean:
	$(RM) -r benchmark/napi/function_call/build
	$(RM) -r benchmark/napi/function_args/build

.PHONY: lint-md-rollup
lint-md-rollup:
	cd tools/node-lint-md-cli-rollup && npm install
	cd tools/node-lint-md-cli-rollup && npm run build-node

.PHONY: lint-md-clean
lint-md-clean:
	$(RM) -r tools/node-lint-md-cli-rollup/node_modules
	$(RM) tools/.*mdlintstamp

.PHONY: lint-md-build
lint-md-build:
	$(warning "Deprecated no-op target 'lint-md-build'")

LINT_MD_DOC_FILES = $(shell find doc -type f -name '*.md')
run-lint-doc-md = tools/lint-md.js -q -f $(LINT_MD_DOC_FILES)
# Lint all changed markdown files under doc/
tools/.docmdlintstamp: $(LINT_MD_DOC_FILES)
	@echo "Running Markdown linter on docs..."
	@$(call available-node,$(run-lint-doc-md))
	@touch $@

LINT_MD_TARGETS = src lib benchmark test tools/doc tools/icu
LINT_MD_ROOT_DOCS := $(wildcard *.md)
LINT_MD_MISC_FILES := $(shell find $(LINT_MD_TARGETS) -type f \
	! -path '*node_modules*' ! -path 'test/fixtures/*' -name '*.md') \
	$(LINT_MD_ROOT_DOCS)
run-lint-misc-md = tools/lint-md.js -q -f $(LINT_MD_MISC_FILES)
# Lint other changed markdown files maintained by us
tools/.miscmdlintstamp: $(LINT_MD_MISC_FILES)
	@echo "Running Markdown linter on misc docs..."
	@$(call available-node,$(run-lint-misc-md))
	@touch $@

tools/.mdlintstamp: tools/.miscmdlintstamp tools/.docmdlintstamp

.PHONY: lint-md
# Lints the markdown documents maintained by us in the codebase.
lint-md: | tools/.mdlintstamp


LINT_JS_TARGETS = .eslintrc.js benchmark doc lib test tools

run-lint-js = tools/node_modules/eslint/bin/eslint.js --cache \
	--report-unused-disable-directives --ext=.js,.mjs,.md $(LINT_JS_TARGETS)
run-lint-js-fix = $(run-lint-js) --fix

.PHONY: lint-js-fix
lint-js-fix:
	@$(call available-node,$(run-lint-js-fix))

.PHONY: lint-js
# Note that on the CI `lint-js-ci` is run instead.
# Lints the JavaScript code with eslint.
lint-js:
	@if [ "$(shell $(node_use_openssl))" != "true" ]; then \
		echo "Skipping $@ (no crypto)"; \
	else \
		echo "Running JS linter..."; \
		$(call available-node,$(run-lint-js)) \
	fi

jslint: lint-js
	@echo "Please use lint-js instead of jslint"

run-lint-js-ci = tools/lint-js.js $(PARALLEL_ARGS) -f tap -o test-eslint.tap \
		$(LINT_JS_TARGETS)

.PHONY: lint-js-ci
# On the CI the output is emitted in the TAP format.
lint-js-ci:
	@echo "Running JS linter..."
	@$(call available-node,$(run-lint-js-ci))

jslint-ci: lint-js-ci
	@echo "Please use lint-js-ci instead of jslint-ci"

LINT_CPP_ADDON_DOC_FILES_GLOB = test/addons/??_*/*.cc test/addons/??_*/*.h
LINT_CPP_ADDON_DOC_FILES = $(wildcard $(LINT_CPP_ADDON_DOC_FILES_GLOB))
LINT_CPP_EXCLUDE ?=
LINT_CPP_EXCLUDE += src/node_root_certs.h
LINT_CPP_EXCLUDE += $(LINT_CPP_ADDON_DOC_FILES)
LINT_CPP_EXCLUDE += $(wildcard test/js-native-api/??_*/*.cc test/js-native-api/??_*/*.h test/node-api/??_*/*.cc test/node-api/??_*/*.h)
# These files were copied more or less verbatim from V8.
LINT_CPP_EXCLUDE += src/tracing/trace_event.h src/tracing/trace_event_common.h

LINT_CPP_FILES = $(filter-out $(LINT_CPP_EXCLUDE), $(wildcard \
	benchmark/napi/function_call/binding.cc \
	src/*.c \
	src/*.cc \
	src/*.h \
	src/*/*.c \
	src/*/*.cc \
	src/*/*.h \
	test/addons/*/*.cc \
	test/addons/*/*.h \
	test/cctest/*.cc \
	test/cctest/*.h \
	test/js-native-api/*/*.cc \
	test/js-native-api/*/*.h \
	test/node-api/*/*.cc \
	test/node-api/*/*.h \
	tools/icu/*.cc \
	tools/icu/*.h \
	tools/code_cache/*.cc \
	tools/code_cache/*.h \
	tools/snapshot/*.cc \
	tools/snapshot/*.h \
	))

# Code blocks don't have newline at the end,
# and the actual filename is generated so it won't match header guards
ADDON_DOC_LINT_FLAGS=-whitespace/ending_newline,-build/header_guard

format-cpp-build:
	cd tools/clang-format && $(call available-node,$(run-npm-ci))

format-cpp-clean:
	$(RM) -r tools/clang-format/node_modules

CLANG_FORMAT_START ?= HEAD
.PHONY: format-cpp
# To format staged changes:
#  $ make format-cpp
# To format HEAD~1...HEAD (latest commit):
#  $ CLANG_FORMAT_START=`git rev-parse HEAD~1` make format-cpp
# To format diff between master and current branch head (master...HEAD):
#  $ CLANG_FORMAT_START=master make format-cpp
format-cpp: ## Format C++ diff from $CLANG_FORMAT_START to current changes
ifneq ("","$(wildcard tools/clang-format/node_modules/)")
	@echo "Formatting C++ diff from $(CLANG_FORMAT_START).."
	@$(PYTHON) tools/clang-format/node_modules/.bin/git-clang-format \
		--binary=tools/clang-format/node_modules/.bin/clang-format \
		--style=file \
		$(CLANG_FORMAT_START) -- \
		$(LINT_CPP_FILES)
else
	@echo "clang-format is not installed."
	@echo "To install (requires internet access) run: $ make format-cpp-build"
endif

ifeq ($(V),1)
	CPPLINT_QUIET =
else
	CPPLINT_QUIET = --quiet
endif
.PHONY: lint-cpp
# Lints the C++ code with cpplint.py and check-imports.py.
lint-cpp: tools/.cpplintstamp

tools/.cpplintstamp: $(LINT_CPP_FILES)
	@echo "Running C++ linter..."
	@$(PYTHON) tools/cpplint.py $(CPPLINT_QUIET) $?
	@$(PYTHON) tools/check-imports.py
	@touch $@

.PHONY: lint-addon-docs
lint-addon-docs: tools/.doclintstamp

tools/.doclintstamp: test/addons/.docbuildstamp
	@echo "Running C++ linter on addon docs..."
	@$(PYTHON) tools/cpplint.py $(CPPLINT_QUIET) --filter=$(ADDON_DOC_LINT_FLAGS) \
		$(LINT_CPP_ADDON_DOC_FILES_GLOB)
	@touch $@

cpplint: lint-cpp
	@echo "Please use lint-cpp instead of cpplint"

.PHONY: lint-py-build
# python -m pip install flake8
# Try with '--system' is to overcome systems that blindly set '--user'
lint-py-build:
	@echo "Pip installing flake8 linter on $(shell $(PYTHON) --version)..."
	$(PYTHON) -m pip install --upgrade -t tools/pip/site-packages flake8 || \
		$(PYTHON) -m pip install --upgrade --system -t tools/pip/site-packages flake8

ifneq ("","$(wildcard tools/pip/site-packages)")
.PHONY: lint-py
# Lints the Python code with flake8.
# Flag the build if there are Python syntax errors or undefined names
lint-py:
	PYTHONPATH=tools/pip $(PYTHON) -m flake8 --count --show-source --statistics .
else
lint-py:
	@echo "Python linting with flake8 is not avalible"
	@echo "Run 'make lint-py-build'"
endif

.PHONY: lint
.PHONY: lint-ci
ifneq ("","$(wildcard tools/node_modules/eslint/)")
lint: ## Run JS, C++, MD and doc linters.
	@EXIT_STATUS=0 ; \
	$(MAKE) lint-js || EXIT_STATUS=$$? ; \
	$(MAKE) lint-cpp || EXIT_STATUS=$$? ; \
	$(MAKE) lint-addon-docs || EXIT_STATUS=$$? ; \
	$(MAKE) lint-md || EXIT_STATUS=$$? ; \
	exit $$EXIT_STATUS
CONFLICT_RE=^>>>>>>> [0-9A-Fa-f]+|^<<<<<<< [A-Za-z]+

# Related CI job: node-test-linter
lint-ci: lint-js-ci lint-cpp lint-py lint-md lint-addon-docs
	@if ! ( grep -IEqrs "$(CONFLICT_RE)" benchmark deps doc lib src test tools ) \
		&& ! ( find . -maxdepth 1 -type f | xargs grep -IEqs "$(CONFLICT_RE)" ); then \
		exit 0 ; \
	else \
		echo "" >&2 ; \
		echo "Conflict marker detected in one or more files. Please fix them first." >&2 ; \
		exit 1 ; \
	fi
else
lint:
	@echo "Linting is not available through the source tarball."
	@echo "Use the git repo instead:" \
		"$ git clone https://github.com/nodejs/node.git"

lint-ci: lint
endif

.PHONY: lint-clean
lint-clean:
	$(RM) tools/.*lintstamp
	$(RM) .eslintcache
