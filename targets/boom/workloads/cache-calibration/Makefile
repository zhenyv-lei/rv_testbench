TOOLCHAIN_BIN ?= /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/.conda-env/riscv-tools/bin
TOOLCHAIN_ROOT := $(abspath $(TOOLCHAIN_BIN)/..)
TOOLCHAIN_LIB := $(TOOLCHAIN_ROOT)/riscv64-unknown-elf/lib
RISCV_PREFIX := $(TOOLCHAIN_BIN)/riscv64-unknown-elf-
CC := $(RISCV_PREFIX)gcc
OBJDUMP := $(RISCV_PREFIX)objdump

SRC_DIR := src
INC_DIR := include
OUT_DIR := ../../build/exec/boom/rv64gc
BIN_DIR := $(OUT_DIR)
DUMP_DIR := $(OUT_DIR)/dump

PROGRAMS := spectre-v1 spectre-v2 spectre-v4 spectre-v5
CALIBRATION_PROGRAMS := cache-calibration
BINS := $(addprefix $(BIN_DIR)/,$(addsuffix .riscv,$(PROGRAMS)))
DUMPS := $(addprefix $(DUMP_DIR)/,$(addsuffix .dump,$(PROGRAMS)))
SMOKE_FLAGS ?= -DSPECTRE_MAX_BYTES=1 -DPROBE_ENTRIES=96 -DEVICTION_MULTIPLIER=4 -DV1_ATTACK_TRIES=1 -DV1_TRAINING_LOOPS=2 -DV2_ATTACK_TRIES=1 -DV2_TRAINING_LOOPS=2 -DV4_ROUNDS=1 -DV5_ROUNDS=1 -DV5_TRAIN_PASSES=1 -DV5_RAS_DEPTH=1 -DV5_IN_PLACE_DELAY=0

CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -std=gnu11 \
  -ffreestanding -fno-common -fno-builtin -fno-omit-frame-pointer \
  -fno-optimize-sibling-calls -march=rv64imafd -mabi=lp64d -mcmodel=medany
LDFLAGS ?= -static -specs=$(TOOLCHAIN_LIB)/htif_nano.specs \
  -T $(TOOLCHAIN_LIB)/htif.ld

BOOM_CHIPYARD ?= /nfs/home/leizhenyu/opt/DUTs/boom/chipyard
BOOM_SIM_DIR ?= $(BOOM_CHIPYARD)/sims/verilator
BOOM_CONFIG ?= MediumBoomV4CosimConfig

.PHONY: all clean dump boom-run-% boom-run-all

all: $(BINS) $(DUMPS)

$(BIN_DIR)/%.riscv: $(SRC_DIR)/%.c $(INC_DIR)/rv64_spectre.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -I$(INC_DIR) $< -o $@ $(LDFLAGS)

$(BIN_DIR)/%-smoke.riscv: $(SRC_DIR)/%.c $(INC_DIR)/rv64_spectre.h | $(BIN_DIR)
	$(CC) $(CFLAGS) $(SMOKE_FLAGS) -I$(INC_DIR) $< -o $@ $(LDFLAGS)

$(DUMP_DIR)/%.dump: $(BIN_DIR)/%.riscv | $(DUMP_DIR)
	$(OBJDUMP) -D $< > $@

$(BIN_DIR) $(DUMP_DIR):
	mkdir -p $@

dump: $(DUMPS)

smoke: $(addprefix $(BIN_DIR)/,$(addsuffix -smoke.riscv,$(PROGRAMS) $(CALIBRATION_PROGRAMS)))

boom-run-%: $(BIN_DIR)/%.riscv
	$(MAKE) -C $(BOOM_SIM_DIR) CONFIG=$(BOOM_CONFIG) BINARY=$(abspath $<) run-binary-fast

boom-run-all: $(BINS)
	for bin in $(BINS); do \
		$(MAKE) -C $(BOOM_SIM_DIR) CONFIG=$(BOOM_CONFIG) BINARY=$$(realpath $$bin) run-binary-fast; \
	done

clean:
	rm -rf $(OUT_DIR)
