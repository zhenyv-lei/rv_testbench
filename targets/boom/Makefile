###############################################################################
# BOOM Spectre bare-metal PoCs
###############################################################################

WORKLOADS := workloads
RUNTIME := runtime
INC := include
LNK := link
BUILD := build
OBJ := $(BUILD)/obj
BIN := $(BUILD)/bin
DMP := $(BUILD)/dump
DEP := $(BUILD)/dep

RISCV ?= /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/.conda-env/riscv-tools
CC = $(RISCV)/bin/riscv64-unknown-elf-gcc
OBJDUMP = $(RISCV)/bin/riscv64-unknown-elf-objdump -S

# Experiment knobs. Empty values keep the source defaults.
SECRET_SZ ?=
TRAIN_TIMES ?=
ROUNDS ?=
ATTACK_SAME_ROUNDS ?=
CACHE_HIT_THRESHOLD ?=
V4_ROUNDS ?=
V5_ROUNDS ?=
V5_TRAIN_PASSES ?=
V5_RAS_DEPTH ?=
V5_IN_PLACE_DELAY ?=
V5_GADGET_MODE ?=

OVERRIDES :=
ifneq ($(strip $(SECRET_SZ)),)
OVERRIDES += -DSECRET_SZ=$(SECRET_SZ)
OVERRIDES += -DSPECTRE_MAX_BYTES=$(SECRET_SZ)
endif
ifneq ($(strip $(TRAIN_TIMES)),)
OVERRIDES += -DTRAIN_TIMES=$(TRAIN_TIMES)
endif
ifneq ($(strip $(ROUNDS)),)
OVERRIDES += -DROUNDS=$(ROUNDS)
endif
ifneq ($(strip $(ATTACK_SAME_ROUNDS)),)
OVERRIDES += -DATTACK_SAME_ROUNDS=$(ATTACK_SAME_ROUNDS)
endif
ifneq ($(strip $(CACHE_HIT_THRESHOLD)),)
OVERRIDES += -DCACHE_HIT_THRESHOLD=$(CACHE_HIT_THRESHOLD)
endif
ifneq ($(strip $(V4_ROUNDS)),)
OVERRIDES += -DV4_ROUNDS=$(V4_ROUNDS)
endif
ifneq ($(strip $(V5_ROUNDS)),)
OVERRIDES += -DV5_ROUNDS=$(V5_ROUNDS)
endif
ifneq ($(strip $(V5_TRAIN_PASSES)),)
OVERRIDES += -DV5_TRAIN_PASSES=$(V5_TRAIN_PASSES)
endif
ifneq ($(strip $(V5_RAS_DEPTH)),)
OVERRIDES += -DV5_RAS_DEPTH=$(V5_RAS_DEPTH)
endif
ifneq ($(strip $(V5_IN_PLACE_DELAY)),)
OVERRIDES += -DV5_IN_PLACE_DELAY=$(V5_IN_PLACE_DELAY)
endif
ifeq ($(strip $(V5_GADGET_MODE)),loop)
OVERRIDES += -DV5_GADGET_MODE=1
else ifeq ($(strip $(V5_GADGET_MODE)),recursive)
OVERRIDES += -DV5_GADGET_MODE=0
else ifneq ($(strip $(V5_GADGET_MODE)),)
OVERRIDES += -DV5_GADGET_MODE=$(V5_GADGET_MODE)
endif

CFLAGS := -mcmodel=medany -l -std=gnu99 -O0 -g -fno-common -fno-builtin-printf \
          -Wall -I$(INC) -Wno-unused-function -Wno-unused-variable $(OVERRIDES)
LDFLAGS := -static -nostdlib -nostartfiles -lgcc
DEPFLAGS = -MT $@ -MMD -MP -MF $(DEP)/$(basename $(notdir $@)).d

PROGRAMS := spectre-v1 spectre-v2 spectre-v4 spectre-v5
SPECTRE_V1_SRC := $(WORKLOADS)/spectre-v1/src/spectre-v1.c
SPECTRE_V2_SRC := $(WORKLOADS)/spectre-v2/src/spectre-v2.c
SPECTRE_V4_SRC := $(WORKLOADS)/spectre-v4/src/spectre-v4.c
SPECTRE_V5_SRC := $(WORKLOADS)/spectre-v5/src/spectre-v5.c
SPECTRE_V4_GADGET := $(WORKLOADS)/spectre-v4/src/spectre-v4-gadget.S
SPECTRE_V5_GADGET := $(WORKLOADS)/spectre-v5/src/spectre-v5-gadget.S
BINS := $(addprefix $(BIN)/,$(addsuffix .riscv,$(PROGRAMS)))
DUMPS := $(addprefix $(DMP)/,$(addsuffix .dump,$(PROGRAMS)))

.PHONY: all clean dumps v1 v2 v4 v5
all: $(BINS) $(DUMPS)

v1: $(BIN)/spectre-v1.riscv $(DMP)/spectre-v1.dump
v2: $(BIN)/spectre-v2.riscv $(DMP)/spectre-v2.dump
v4: $(BIN)/spectre-v4.riscv $(DMP)/spectre-v4.dump
v5: $(BIN)/spectre-v5.riscv $(DMP)/spectre-v5.dump

dumps: $(DUMPS)

$(OBJ)/%.o: $(RUNTIME)/%.S
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -D__ASSEMBLY__=1 -c $< -o $@

$(OBJ)/%.o: $(RUNTIME)/%.c
	@mkdir -p $(OBJ) $(DEP)
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

$(OBJ)/spectre-v1.o: $(SPECTRE_V1_SRC)
	@mkdir -p $(OBJ) $(DEP)
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

$(OBJ)/spectre-v2.o: $(SPECTRE_V2_SRC)
	@mkdir -p $(OBJ) $(DEP)
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

$(OBJ)/spectre-v4.o: $(SPECTRE_V4_SRC)
	@mkdir -p $(OBJ) $(DEP)
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

$(OBJ)/spectre-v5.o: $(SPECTRE_V5_SRC)
	@mkdir -p $(OBJ) $(DEP)
	$(CC) $(CFLAGS) $(DEPFLAGS) -c $< -o $@

$(OBJ)/spectre-v4-gadget.o: $(SPECTRE_V4_GADGET)
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -D__ASSEMBLY__=1 -c $< -o $@

$(OBJ)/spectre-v5-gadget.o: $(SPECTRE_V5_GADGET)
	@mkdir -p $(OBJ)
	$(CC) $(CFLAGS) -D__ASSEMBLY__=1 -c $< -o $@

$(BIN)/%.riscv: $(OBJ)/%.o $(OBJ)/crt.o $(OBJ)/syscalls.o $(OBJ)/stack.o $(LNK)/link.ld
	@mkdir -p $(BIN)
	$(CC) -T $(LNK)/link.ld $(LDFLAGS) $< $(OBJ)/crt.o $(OBJ)/stack.o $(OBJ)/syscalls.o -o $@

$(BIN)/spectre-v4.riscv: $(OBJ)/spectre-v4.o $(OBJ)/spectre-v4-gadget.o $(OBJ)/crt.o $(OBJ)/syscalls.o $(OBJ)/stack.o $(LNK)/link.ld
	@mkdir -p $(BIN)
	$(CC) -T $(LNK)/link.ld $(LDFLAGS) $(OBJ)/spectre-v4.o $(OBJ)/spectre-v4-gadget.o $(OBJ)/crt.o $(OBJ)/stack.o $(OBJ)/syscalls.o -o $@

$(BIN)/spectre-v5.riscv: $(OBJ)/spectre-v5.o $(OBJ)/spectre-v5-gadget.o $(OBJ)/crt.o $(OBJ)/syscalls.o $(OBJ)/stack.o $(LNK)/link.ld
	@mkdir -p $(BIN)
	$(CC) -T $(LNK)/link.ld $(LDFLAGS) $(OBJ)/spectre-v5.o $(OBJ)/spectre-v5-gadget.o $(OBJ)/crt.o $(OBJ)/stack.o $(OBJ)/syscalls.o -o $@

$(DMP)/%.dump: $(BIN)/%.riscv
	@mkdir -p $(DMP)
	$(OBJDUMP) -D $< > $@

clean:
	rm -rf $(BIN) $(OBJ) $(DMP) $(DEP)

-include $(addprefix $(DEP)/,$(addsuffix .d,$(PROGRAMS)))
