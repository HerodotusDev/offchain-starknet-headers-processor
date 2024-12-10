
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, PoseidonBuiltin, HashBuiltin
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash_many
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.hash_state import hash_felts_no_padding


func extract_parent_hash{range_check_ptr}(blockhash_preimage: felt*) -> (res: felt) {
    if (blockhash_preimage[0] == 0x535441524B4E45545F424C4F434B5F4841534830) {
        return (res=blockhash_preimage[16]);
    } else {
        return (res=blockhash_preimage[11]);
    }
}

const BLOCK_NUMBER_INDEX = 1;
func extract_block_number{range_check_ptr}(blockhash_preimage: felt*) -> (res: felt) {
    return (res=blockhash_preimage[BLOCK_NUMBER_INDEX]);
}

func compute_starknet_blockhash{
    range_check_ptr,
    bitwise_ptr: BitwiseBuiltin*,
    pedersen_ptr: HashBuiltin*,         
    poseidon_ptr: PoseidonBuiltin*,
}(blockhash_preimage: felt*) -> (res: felt) {

    if (blockhash_preimage[0] == 0x535441524B4E45545F424C4F434B5F4841534830) {
        let (blockhash) = poseidon_hash_many(n=17, elements=blockhash_preimage);
        return (res=blockhash);
    } else {
        let initial_hash = [blockhash_preimage];
        let hash_ptr = pedersen_ptr;
        with hash_ptr {
            let (blockhash) = hash_felts_no_padding(data_ptr=blockhash_preimage + 1, data_length=12, initial_hash=initial_hash);
        }
        let pedersen_ptr = hash_ptr;
        return (res=blockhash);
    }
}

func read_block_headers() -> (preimages_array: felt**) {
    let (block_headers_array: felt**) = alloc();
    %{
        block_headers_array = program_input['preimages_array']
        segments.write_arg(ids.block_headers_array, block_headers_array)
    %}
    return (block_headers_array,);
}