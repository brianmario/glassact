// The Metal port of av1gpu's GPU entropy coder (Glass Act): symbolization and range coding of a
// DecisionRecord, byte-identical to av1core's CPU writer. Its own library: AV1MetalEntropy
// compiles it without the encoder's kernels.
#include "entropy.h"
