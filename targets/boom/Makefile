###############################################################################
# BOOM Spectre v1/v2 bare-metal PoCs
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

OVERRIDES :=
ifneq ($(strip $(SECRET_SZ)),)
OVERRIDES += -DSECRET_SZ=$(SECRET_SZ)
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

CFLAGS := -mcmodel=medany -l -std=gnu99 -O0 -g -fno-common -fno-builtin-printf \
          -Wall -I$(INC) -Wno-unused-function -Wno-unused-variable $(OVERRIDES)
LDFLAGS := -static -nostdlib -nostartfiles -lgcc
DEPFLAGS = -MT $@ -MMD -MP -MF $(DEP)/$(basename $(notdir $@)).d

PROGRAMS := spectre-v1 spectre-v2
SPECTRE_V1_SRC := $(WORKLOADS)/spectre-v1/src/spectre-v1.c
SPECTRE_V2_SRC := $(WORKLOADS)/spectre-v2/src/spectre-v2.c
BINS := $(addprefix $(BIN)/,$(addsuffix .riscv,$(PROGRAMS)))
DUMPS := $(addprefix $(DMP)/,$(addsuffix .dump,$(PROGRAMS)))

.PHONY: all clean dumps v1 v2
all: $(BINS) $(DUMPS)

v1: $(BIN)/spectre-v1.riscv $(DMP)/spectre-v1.dump
v2: $(BIN)/spectre-v2.riscv $(DMP)/spectre-v2.dump

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

$(BIN)/%.riscv: $(OBJ)/%.o $(OBJ)/crt.o $(OBJ)/syscalls.o $(OBJ)/stack.o $(LNK)/link.ld
	@mkdir -p $(BIN)
	$(CC) -T $(LNK)/link.ld $(LDFLAGS) $< $(OBJ)/crt.o $(OBJ)/stack.o $(OBJ)/syscalls.o -o $@

$(DMP)/%.dump: $(BIN)/%.riscv
	@mkdir -p $(DMP)
	$(OBJDUMP) -D $< > $@

clean:
	rm -rf $(BIN) $(OBJ) $(DMP) $(DEP)

-include $(addprefix $(DEP)/,$(addsuffix .d,$(PROGRAMS)))
