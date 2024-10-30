from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, PoseidonBuiltin
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many
from starkware.cairo.common.alloc import alloc

const PARENT_HASH_INDEX = 16;
func extract_parent_hash{range_check_ptr}(blockhash_preimage: felt*) -> (res: felt) {
    return (res=blockhash_preimage[PARENT_HASH_INDEX]);
}

const BLOCK_NUMBER_INDEX = 1;
func extract_block_number{range_check_ptr}(blockhash_preimage: felt*) -> (res: felt) {
    return (res=blockhash_preimage[BLOCK_NUMBER_INDEX]);
}

const STARKNET_HEADER_N_ELEMENTS = 17;
func compute_starknet_blockhash{
    range_check_ptr, bitwise_ptr: BitwiseBuiltin*, poseidon_ptr: PoseidonBuiltin*
}(blockhash_preimage: felt*) -> (res: felt) {
    let (blockhash) = poseidon_hash_many(n=STARKNET_HEADER_N_ELEMENTS, elements=blockhash_preimage);
    return (res=blockhash);
}

func read_block_headers() -> (preimages_array: felt**) {
    let (block_headers_array: felt**) = alloc();
    %{
        block_headers_array = program_input['preimages_array']
        segments.write_arg(ids.block_headers_array, block_headers_array)
    %}
    return (block_headers_array,);
}
