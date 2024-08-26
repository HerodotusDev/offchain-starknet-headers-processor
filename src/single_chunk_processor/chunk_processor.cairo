%builtins output range_check bitwise poseidon

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.cairo_builtins import BitwiseBuiltin, PoseidonBuiltin
from starkware.cairo.common.registers import get_fp_and_pc

from starkware.cairo.common.uint256 import Uint256, uint256_reverse_endian
from starkware.cairo.common.builtin_keccak.keccak import keccak
from starkware.cairo.common.keccak_utils.keccak_utils import keccak_add_uint256
from starkware.cairo.common.builtin_poseidon.poseidon import poseidon_hash, poseidon_hash_many
from starkware.cairo.common.default_dict import default_dict_new, default_dict_finalize
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.dict import dict_write
from starkware.cairo.common.math import unsigned_div_rem as felt_divmod

from src.libs.starknet_block_header import (
    extract_parent_hash,
    extract_block_number,
    compute_starknet_blockhash,
    read_block_headers
)
from src.libs.utils import pow2alloc127

from src.libs.mmr import (
    compute_height_pre_alloc_pow2 as compute_height,
    compute_peaks_positions,
    bag_peaks,
    get_roots,
    get_full_mmr_peak_values,
    assert_mmr_size_is_valid,
)


// Recursively verifies that Cairo_Keccak(block_header_i) = parent_hash(block_header_i+1)_little_endian for all from i=index to i=0
// Reverses each block_header_i back to big endian and hashes it with poseidon_hash_many
// Stores the poseidon hash of each block header in poseidon_hash_array
// Reverses endianness of the keccak hash of each block header back to big endian and stores it in keccak_hash_array
//
// Implicit arguments :
// - poseidon_hash_array: felt* - array of poseidon hashes of block headers to fill
// - keccak_hash_array: Uint256* - array of keccak hashes of block headers to fill
// - block_headers_array: felt** - array of block headers to verify
//
// Params:
// - index: felt - index of block header to verify in block_headers_array
//   Should initially be equal to the number of blocks in the batch - 1
// - expected_block_hash: Uint256 - should be the parent hash of block header i+1 (little endian)
//
// Returns:
// - block_n_minus_r_plus_one_parent_hash: Uint256 - extracted parent hash of block_headers_array[0] (little endian)
// - last_block_header_big: felt* - reversed block header of block_headers_array[0] (big endian)
func verify_block_headers_and_hash_them{
    range_check_ptr,
    bitwise_ptr: BitwiseBuiltin*,
    poseidon_ptr: PoseidonBuiltin*,
    poseidon_hash_array: felt*,
    block_headers_array: felt**,
}(index: felt, expected_block_hash: felt) -> (
    block_n_minus_r_plus_one_parent_hash: felt, last_block_header: felt*
) {
    alloc_locals;
    let (block_header_hash: felt) = compute_starknet_blockhash(block_headers_array[index]);

    assert 0 = block_header_hash - expected_block_hash;

    // Store poseidon hash in the respective array
    assert poseidon_hash_array[index] = block_header_hash;

    // Get parent hash of block i (little endian)
    let (block_i_parent_hash: felt) = extract_parent_hash(block_headers_array[index]);

    if (index == 0) {
        // If we are at the last block header in the batch, return the parent hash of block 0 and the reversed block header.
        return (
            block_n_minus_r_plus_one_parent_hash=block_i_parent_hash,
            last_block_header=block_headers_array[index],
        );
    } else {
        // Otherwise, verify the (previous) block header at index (index-1)
        return verify_block_headers_and_hash_them(
            index=index - 1, expected_block_hash=block_i_parent_hash
        );
    }
}

// Appends block headers hashes to both MMR using the previous MMR information
//
// Implicit arguments :
// - poseidon_hash_array: felt* - array of poseidon hashes of block headers
// - mmr_array_poseidon: felt* - array of new nodes to fill for the Poseidon MMR
// - mmr_array_len: felt - length of mmr arrays
// - mmr_offset: felt - offset of mmr arrays. ie : mmr_array_poseidon[i] is the i+mmr_offset-th+1 node of the MMR
// - previous_peaks_dict_poseidon: DictAccess* - previous peaks of the Poseidon MMR
// - pow2_array: felt* - array of powers of 2
//
// Params:
// - index: felt - index of block header hash to append to MMR
//   Should intially correspond to the number of blocks in the batch - 1
func construct_mmr{
    range_check_ptr,
    bitwise_ptr: BitwiseBuiltin*,
    poseidon_ptr: PoseidonBuiltin*,
    poseidon_hash_array: felt*,
    mmr_array_poseidon: felt*,
    mmr_array_len: felt,
    mmr_offset: felt,
    previous_peaks_dict_poseidon: DictAccess*,
    pow2_array: felt*,
}(index: felt) {
    alloc_locals;

    // Append leaves to mmr arrays. They are already hashed.

    assert mmr_array_poseidon[mmr_array_len] = poseidon_hash_array[index];

    let mmr_array_len = mmr_array_len + 1;

    // Append extra nodes to mmr arrays if merging is needed
    merge_subtrees_if_applicable(height=0);
    if (index == 0) {
        return ();
    } else {
        return construct_mmr(index=index - 1);
    }
}

// 3              15
//              /    \
//             /      \
//            /        \
//           /          \
// 2        7            14
//        /   \        /    \
// 1     3     6      10    13     18
//      / \   / \    / \   /  \   /  \
// 0   1   2 4   5  8   9 11  12 16  17 19
// Recursively append nodes to MMR arrays if merging is needed (ie : checks if the height of the next position is higher than the current one)
// Implicit arguments :
// - mmr_array_poseidon: felt* - array of new nodes to fill for the Poseidon MMR
//  -mmr_array_len: felt - length of mmr arrays
// - mmr_offset: felt - offset of mmr arrays. ie : mmr_array_poseidon[i] is the i+mmr_offset-th+1 node of the MMR
// - previous_peaks_dict_poseidon: DictAccess* - previous peaks of the Poseidon MMR
// - pow2_array: felt* - array of powers of 2
//
// Params:
// - height: felt - current height of the node at the last position of the MMR
func merge_subtrees_if_applicable{
    range_check_ptr,
    bitwise_ptr: BitwiseBuiltin*,
    poseidon_ptr: PoseidonBuiltin*,
    mmr_array_poseidon: felt*,
    mmr_array_len: felt,
    mmr_offset: felt,
    previous_peaks_dict_poseidon: DictAccess*,
    pow2_array: felt*,
}(height: felt) {
    alloc_locals;

    tempvar next_pos: felt = mmr_array_len + mmr_offset + 1;
    let height_next_pos = compute_height{pow2_array=pow2_array}(next_pos);

    if (height_next_pos == height + 1) {
        // The height of the next position is one level higher than the current one.
        // It means than the last element in the array is a right children.

        // Compute left and right positions of the subtree to merge
        local left_pos = next_pos - pow2_array[height + 1];
        local right_pos = next_pos - 1;

        // %{ print(f"Merging {ids.left_pos} + {ids.right_pos} at index {ids.next_pos} and height {ids.height_next_pos} ") %}

        // Get the values of the left and right children at those positions:
        let (x_poseidon: felt) = get_full_mmr_peak_values(left_pos);
        let (y_poseidon: felt) = get_full_mmr_peak_values(right_pos);

        // Compute H(left, right) for both hash functions
        let (hash_poseidon) = poseidon_hash(x_poseidon, y_poseidon);

        // Append each parent to the corresponding MMR arrays
        assert mmr_array_poseidon[mmr_array_len] = hash_poseidon;

        let mmr_array_len = mmr_array_len + 1;
        // Continue merging if needed:
        return merge_subtrees_if_applicable(height=height + 1);
    } else {
        // Next position is not a parent, no need to merge.
        return ();
    }
}

// Main processor function.
// See readme for more details.
func main{
    output_ptr: felt*,
    range_check_ptr,
    bitwise_ptr: BitwiseBuiltin*,
    poseidon_ptr: PoseidonBuiltin*,
}() {
    alloc_locals;
    local from_block_number_high: felt;
    local to_block_number_low: felt;
    local mmr_offset: felt;
    local mmr_last_root_poseidon: felt;
    local block_n_plus_one_parent_hash: felt;
    %{
        ids.from_block_number_high=program_input['from_block_number_high']
        ids.to_block_number_low=program_input['to_block_number_low']
        ids.mmr_offset=program_input['mmr_last_len']
        ids.mmr_last_root_poseidon=program_input['mmr_last_root_poseidon']
        ids.block_n_plus_one_parent_hash = program_input['block_n_plus_one_parent_hash']
    %}

    // -----------------------------------------------------
    // -----------------------------------------------------
    // INITIALIZE VARIABLES
    // -----------------------------------------------------
    tempvar number_of_blocks = from_block_number_high - to_block_number_low + 1;
    let n = number_of_blocks - 1;  // index of last block
    let pow2_array: felt* = pow2alloc127();

    // Load block headers from the program's input:
    let (block_headers_array: felt**) = read_block_headers();

    // Write previous peaks values and compute root of previous MMR:
    let (previous_peaks_values_poseidon: felt*) = alloc();  // From left to right
    %{
        segments.write_arg(ids.previous_peaks_values_poseidon, program_input['poseidon_mmr_last_peaks']) 
    %}

    // Ensure that the previous MMR size is valid.
    assert_mmr_size_is_valid{pow2_array=pow2_array}(mmr_offset);
    // Compute previous_peaks_positions given the previous MMR size (from left to right), as well:
    let (
        previous_peaks_positions: felt*, previous_peaks_positions_len: felt
    ) = compute_peaks_positions{pow2_array=pow2_array}(mmr_offset);

    // Based on the previous peaks positions, compute the previous roots:
    let (bagged_peaks_poseidon) = bag_peaks(
        previous_peaks_values_poseidon, previous_peaks_positions_len
    );

    let (root_poseidon) = poseidon_hash(mmr_offset, bagged_peaks_poseidon);

    // Check that the previous roots matche the ones provided in the program's input:
    assert 0 = root_poseidon - mmr_last_root_poseidon;

    // If previous peaks match the previous root, append the peak values to previous_peaks_dict:
    let (local previous_peaks_dict_poseidon) = default_dict_new(default_value=0);
    tempvar dict_start_poseidon = previous_peaks_dict_poseidon;
    initialize_peaks_dicts{
        dict_end_poseidon=previous_peaks_dict_poseidon
    }(
        previous_peaks_positions_len - 1,
        previous_peaks_positions,
        previous_peaks_values_poseidon,
    );

    // Initialize Poseidon MMR:
    // poseidon_hash_array will contain the poseidon_hash of each block header, with the block headers reversed back to big endian
    // More precisely: poseidon_hash_array[i] = poseidon_hash_many(reversed_block_headers_chunks(block_headers_array[i]))
    //
    // mmr_array_poseidon will contain the flattened continuation of the Poseidon MMR
    // More precisely : mmr_array_poseidon[i] = The value of the Poseidon MMR at position i+mmr_offset+1
    let (poseidon_hash_array: felt*) = alloc();
    let (mmr_array_poseidon: felt*) = alloc();

    // Common variable for both MMR :
    let mmr_array_len = 0;

    // -----------------------------------------------------
    // -----------------------------------------------------
    // MAIN LOOPS : (1) Validate RLPs and prepare hash arrays, (2) Build MMR arrays with hash array

    // (1) Validate chain of block headers for blocks [n, n-1, n-2, n-1, ..., n-r]:
    with poseidon_hash_array, block_headers_array {
        let (
            block_n_minus_r_plus_one_parent: felt, last_block_header: felt*
        ) = verify_block_headers_and_hash_them(
            index=n, expected_block_hash=block_n_plus_one_parent_hash
        );
    }

    with pow2_array {
        let (block_n_minus_r_plus_one_number) = extract_block_number(last_block_header);
    }

    // Checks that to_block_number_low from the program's input matches the extracted block number from the last block header:
    assert 0 = to_block_number_low - block_n_minus_r_plus_one_number;

    // %{ print(f"RLP successfully validated!") %}
    // (2) Build Poseidon MMR by appending all poseidon hashes of block headers stored in poseidon_hash_array:
    // %{ print(f"Building MMR...") %}
    with poseidon_hash_array, mmr_array_poseidon, mmr_array_len, pow2_array, mmr_offset, previous_peaks_dict_poseidon {
        construct_mmr(index=n);
    }
    // %{
    //     print('Final Poseidon MMR')
    //     print_mmr(ids.mmr_array_poseidon,ids.mmr_array_len)
    // %}

    // -----------------------------------------------------

    // FINALIZATION

    with mmr_array_poseidon, mmr_array_len, pow2_array, previous_peaks_dict_poseidon, mmr_offset {
        let (new_mmr_root_poseidon: felt) = get_roots();
    }

    %{ print("new root poseidon", hex(ids.new_mmr_root_poseidon)) %}
    %{ print("new size", ids.mmr_array_len + ids.mmr_offset) %}

    default_dict_finalize(dict_start_poseidon, previous_peaks_dict_poseidon, 0);

    // let (block_n_plus_one_parent_hash) = block_n_plus_one_parent_hash;
    // let (block_n_minus_r_plus_one_parent_hash) = block_n_minus_r_plus_one_parent_hash;

    // Returns "private" input as public output, as well as output of interest.

    // Output :
    // 0 : from_block_number_high
    // 1 : to_block_number_low
    // 2+3 : block_n_plus_one_parent_hash
    // 4+5 : block_n_minus_r_plus_one_parent_hash
    // 4 : block_n_minus_r_plus_one_number
    // 5 : MMR last root poseidon
    // 6 : New MMR root poseidon
    // 11 : MMR last size (<=> mmr_offset)
    // 12 : New MMR size (<=> mmr_array_len + mmr_offset)

    [ap] = from_block_number_high;
    [ap] = [output_ptr], ap++;

    [ap] = to_block_number_low;
    [ap] = [output_ptr + 1], ap++;

    [ap] = block_n_plus_one_parent_hash;
    [ap] = [output_ptr + 2], ap++;

    [ap] = block_n_minus_r_plus_one_parent;
    [ap] = [output_ptr + 3], ap++;

    [ap] = mmr_last_root_poseidon;
    [ap] = [output_ptr + 4], ap++;

    [ap] = mmr_offset;
    [ap] = [output_ptr + 5], ap++;

    [ap] = new_mmr_root_poseidon;
    [ap] = [output_ptr + 6], ap++;

    [ap] = mmr_array_len + mmr_offset;
    [ap] = [output_ptr + 7], ap++;

    [ap] = output_ptr + 8, ap++;
    let output_ptr = output_ptr + 8;

    return ();
}

// Stores the values inside peaks_values_poseidon in two dictionaries represented by their end pointers,
// such that:
// - dict_poseidon[peak_positions[i]] = peaks_values_poseidon[i]
// Since cairo dicts only allow felts values, for keccak, the Uint256 is stored by casting a pointer of the value to a felt.
// See the function get_full_mmr_peak_values for the reverse operation.
//
// Implicit arguments:
// - dict_end_poseidon: DictAccess* - the end of the dictionary for the Poseidon MMR
// - dict_end_keccak: DictAccess* - the end of the dictionary for the Keccak MMR
//
// Params:
// - index: felt - the index of the array to be stored in the dictionary
//   Should be equal to the computed peaks_len given the validated MMR size, - 1.
// - peaks_positions: felt* - the array of positions of the peaks
// - peaks_values_poseidon: felt* - the array of values of the peaks for the Poseidon MMR
// - peaks_values_keccak: Uint256* - the array of values of the peaks for the Keccak MMR
func initialize_peaks_dicts{dict_end_poseidon: DictAccess*}(
    index: felt, peaks_positions: felt*, peaks_values_poseidon: felt*
) {
    alloc_locals;
    let (__fp__, _) = get_fp_and_pc();

    if (index == 0) {
        dict_write{dict_ptr=dict_end_poseidon}(
            key=peaks_positions[0], new_value=peaks_values_poseidon[0]
        );

        return ();
    } else {
        dict_write{dict_ptr=dict_end_poseidon}(
            key=peaks_positions[index], new_value=peaks_values_poseidon[index]
        );

        return initialize_peaks_dicts(
            index=index - 1,
            peaks_positions=peaks_positions,
            peaks_values_poseidon=peaks_values_poseidon,
        );
    }
}
