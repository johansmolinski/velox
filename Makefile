# Velox - build rules
#
#   make            build build/velox (stripped AmigaOS executable)
#   make test       build build/vtest and run the headless tests (vamos)
#   make size       show executable size against the target
#   make clean      remove build output

TOOLS   := tools/bin
NDK     := tools/ndk/Include_I
VASM    := $(TOOLS)/vasmm68k_mot
VLINK   := $(TOOLS)/vlink

# -x: undefined symbols are errors (catches typos instead of silently
#     creating external references)
# -opt-allbra: also resize branches written with an explicit .s/.w size
ASFLAGS := -Fhunk -m68020 -quiet -x -opt-allbra -I src -I build -I $(NDK)
# PROFILE=1: time the stages of the image decoders (prof log events)
ifeq ($(PROFILE),1)
ASFLAGS += -DPROFILE=1
endif
LDFLAGS := -bamigahunk -Bstatic -s -sc -sd

# Size target for the executable, in bytes (can be raised when needed).
BUDGET  := 65536

CORE    := $(patsubst src/%.s,build/%.o,$(filter-out src/main.s,$(wildcard src/*.s)))
INCS    := $(wildcard src/*.i)
TARGET  := build/velox
VTEST   := build/vtest

.PHONY: aminet all clean size test dist lint release

all: $(TARGET) build/wbrun build/mouse

$(TARGET): build/main.o $(CORE)
	$(VLINK) $(LDFLAGS) -o $@ $^

$(VTEST): build/vtest.o $(CORE)
	$(VLINK) -bamigahunk -Bstatic -sc -sd -o $@ $^

build/%.o: src/%.s $(INCS) build/flags | build
	$(VASM) $(ASFLAGS) -o $@ $<

# BUILD_ID: a hash of the sources; page files (pagefile.s) of another
# build are not used.  Rewritten only when it changes.
build/buildid.i: $(wildcard src/*.s) $(INCS) | build
	@echo "BUILD_ID equ \$$$$(cat src/*.s src/*.i | cksum | cut -d' ' -f1 | xargs printf '%08x')" | cmp -s - $@ || \
	 echo "BUILD_ID equ \$$$$(cat src/*.s src/*.i | cksum | cut -d' ' -f1 | xargs printf '%08x')" >$@
build/pagefile.o: build/buildid.i

# the assembler flags (PROFILE=1 or not): everything again when they change
build/flags: FORCE | build
	@echo '$(ASFLAGS)' | cmp -s - $@ || echo '$(ASFLAGS)' >$@
.PHONY: FORCE

# wbrun: starts a program as Workbench does (for the 'wb' emulator test)
build/wbrun: test/wbrun.s | build
	$(VASM) $(ASFLAGS) -o build/wbrun.o $<
	$(VLINK) $(LDFLAGS) -o $@ build/wbrun.o

# mouse: moves the pointer / uses the button (the 'select' emulator test)
build/mouse: test/mouse.s | build
	$(VASM) $(ASFLAGS) -o build/mouse.o $<
	$(VLINK) $(LDFLAGS) -o $@ build/mouse.o

build/vtest.o: test/vtest.s $(INCS) | build
	$(VASM) $(ASFLAGS) -o $@ $<

build:
	mkdir -p build

test: $(VTEST)
	test/unit.sh

# register convention checks (see tools/lint.py)
lint:
	python3 tools/lint.py

# build/dist/Velox and its drawer icon: the program, its icon, the proxy,
# the read-me and Velox.guide (the version filled in; its icon opens it
# with MultiView). The icons are MagicWB's 8 colours.
dist: $(TARGET)
	rm -rf build/dist && mkdir -p build/dist/Velox
	cp $(TARGET) build/dist/Velox/Velox
	python3 tools/mkicon.py gfx/icon-mwb.png build/dist/Velox/Velox.info
	python3 tools/mkicon.py --drawer gfx/drawer-mwb.png build/dist/Velox.info
	cp tools/velox-proxy.py README.md LICENSE build/dist/Velox/
	sed -e 's/%VERSION%/$(VERSION)/g' -e 's/%DATE%/$(DATE)/g' docs/Velox.guide >build/dist/Velox/Velox.guide
	python3 tools/mkicon.py --project SYS:Utilities/MultiView gfx/guide-mwb.png build/dist/Velox/Velox.guide.info

# release: build/Velox-VERSION.lha and .zip of the dist folder (the
# version: VERSION_STR in src/velox.i)
VERSION := $(shell awk -F'"' '/^VERSION_STR/{getline; print $$2; exit}' src/velox.i)
DATE := $(shell awk -F'"' '/^VERSION_DATE/{getline; print $$2; exit}' src/velox.i)
release: dist
	python3 tools/mklha.py build/Velox-$(VERSION).lha build/dist/Velox build/dist/Velox.info
	cd build/dist && rm -f ../Velox-$(VERSION).zip && python3 -m zipfile -c ../Velox-$(VERSION).zip Velox Velox.info
	@ls -l build/Velox-$(VERSION).lha build/Velox-$(VERSION).zip

# aminet: build/aminet/velox.lha and velox.readme for Aminet: the dist
# folder with the source in Velox/Source (the GPL: what it takes to
# build Velox from the committed tree, AMINET_SRC; the tests and
# graphics are in the repository, at the version's tag, as the readme
# says); the readme from tools/aminet.readme (its changes section: edit
# it for each release), checked by tools/aminetcheck.py
AMINET_SRC := src tools docs Makefile README.md LICENSE CLAUDE.md
aminet: dist
	rm -rf build/aminet && mkdir -p build/aminet/stage/Velox/Source
	cp -r build/dist/Velox build/dist/Velox.info build/aminet/stage/
	git archive HEAD -- $(AMINET_SRC) | tar -x -C build/aminet/stage/Velox/Source
	python3 tools/mklha.py build/aminet/velox.lha build/aminet/stage/Velox build/aminet/stage/Velox.info
	sed -e 's/@VERSION@/$(VERSION)/g' -e "s/@AUTHOR@/$$(git config user.name) ($$(git config user.email))/g" tools/aminet.readme >build/aminet/velox.readme
	python3 tools/aminetcheck.py build/aminet/velox.lha build/aminet/velox.readme
	@ls -l build/aminet/velox.lha build/aminet/velox.readme

size: $(TARGET)
	@s=$$(stat -c %s $(TARGET)); echo "$(TARGET): $$s bytes ($$((s * 100 / $(BUDGET)))% of the $(BUDGET) target)"

clean:
	rm -rf build
