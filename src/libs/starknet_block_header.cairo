
const PARENT_HASH_INDEX = 4;
func extract_parent_hash{range_check_ptr}(blockhash_preimage: felt*) -> (res: felt) {
    return blockhash_preimage[PARENT_HASH_INDEX];
}