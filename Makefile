UNAME_S := $(shell uname -s)
CXX ?= c++
SUFFIX ?= .so
ifeq ($(UNAME_S),Darwin)
SUFFIX = .dylib
endif

TARGET = src/liberime-regexp-core$(SUFFIX)
SOURCE = src/liberime-regexp-core.cc
RIME_PATH ?= vendor/librime
EMACS_INCLUDE ?= $(shell emacs --batch -Q --eval \
	'(princ (concat (replace-regexp-in-string "/share/emacs/.*" "" \
	(or (locate-library "files") "/usr")) "/include"))' 2>/dev/null)
RIME_CFLAGS := $(shell pkg-config --cflags rime 2>/dev/null)
RIME_LIBS := $(shell pkg-config --libs rime 2>/dev/null || echo -lrime)
RIME_VERSION := $(shell pkg-config --modversion rime 2>/dev/null)

CXXFLAGS += -std=c++17 -fPIC -O2 -Wall -I$(EMACS_INCLUDE) -Isrc $(RIME_CFLAGS)
LDFLAGS += -shared $(RIME_LIBS)

ifdef RIME_PATH
CXXFLAGS += -I$(RIME_PATH)/src -I$(RIME_PATH)/include
endif
ifdef BOOST_INCLUDE
CXXFLAGS += -I$(BOOST_INCLUDE)
endif
ifdef RIME_INTERNAL_CXXFLAGS
CXXFLAGS += $(RIME_INTERNAL_CXXFLAGS)
endif

.PHONY: all clean prepare-rime-source
all: $(TARGET)

prepare-rime-source:
	@if test "$(RIME_PATH)" = "vendor/librime" && test -e .git; then \
		git submodule update --init --depth 1 -- vendor/librime; \
	fi
	@test -f "$(RIME_PATH)/src/rime/candidate.h" || { \
		echo "librime sources are missing from $(RIME_PATH)"; \
		exit 1; \
	}
	@source_version=$$(grep -m 1 '^set.rime_version ' \
		"$(RIME_PATH)/CMakeLists.txt" | tr -cd '0-9.'); \
	if test -n "$(RIME_VERSION)" && test -n "$$source_version" && \
		test "$(RIME_VERSION)" != "$$source_version"; then \
		echo "librime version mismatch: installed $(RIME_VERSION), sources $$source_version"; \
		exit 1; \
	fi

$(TARGET): $(SOURCE) Makefile | prepare-rime-source
	$(CXX) $(CXXFLAGS) $< $(LDFLAGS) -o $@

clean:
	rm -f $(TARGET)
