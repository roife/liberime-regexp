UNAME_S := $(shell uname -s)
CXX ?= c++
SUFFIX ?= .so
ifeq ($(UNAME_S),Darwin)
SUFFIX = .dylib
endif

TARGET = src/liberime-regexp-core$(SUFFIX)
SOURCE = src/liberime-regexp-core.cc
EMACS_INCLUDE ?= $(shell emacs --batch -Q --eval \
	'(princ (concat (replace-regexp-in-string "/share/emacs/.*" "" \
	(or (locate-library "files") "/usr")) "/include"))' 2>/dev/null)
RIME_CFLAGS := $(shell pkg-config --cflags rime 2>/dev/null)
RIME_LIBS := $(shell pkg-config --libs rime 2>/dev/null || echo -lrime)

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

.PHONY: all clean
all: $(TARGET)

$(TARGET): $(SOURCE) Makefile
	$(CXX) $(CXXFLAGS) $< $(LDFLAGS) -o $@

clean:
	rm -f $(TARGET)
