// Bridging header: exposes the libsa3 C ABI to Swift.
//
// V1 is the contract: one sa3_get_api symbol and a size-tagged function table, plus the
// independently versioned training table. libsa3.h is no longer included — its historical entry
// points are compatibility shims, not the release contract (see docs/C_ABI_V1.md).
#import "libsa3_v1.h"
#import "libsa3_training_v1.h"
