use super::CustomHintProcessor;
use cairo_vm::hint_processor::builtin_hint_processor::hint_utils::get_ptr_from_var_name;
use cairo_vm::types::relocatable::MaybeRelocatable;
use cairo_vm::{
    hint_processor::builtin_hint_processor::builtin_hint_processor_definition::HintProcessorData,
    types::exec_scope::ExecutionScopes,
    vm::{errors::hint_errors::HintError, vm_core::VirtualMachine},
    Felt252,
};
use eth_essentials_cairo_vm_hints::utils;
use std::collections::HashMap;

pub const HINT_INPUT: &str = "ids.from_block_number_high=program_input['from_block_number_high']\nids.to_block_number_low=program_input['to_block_number_low']\nids.mmr_offset=program_input['mmr_last_len']\nids.mmr_last_root_poseidon=program_input['mmr_last_root_poseidon']\nids.block_n_plus_one_parent_hash = program_input['block_n_plus_one_parent_hash_little']";
pub const HINT_INPUT_PREV: &str = "segments.write_arg(ids.previous_peaks_values_poseidon, program_input['poseidon_mmr_last_peaks'])";
pub const HINT_INPUT_BLOCK_HEADERS: &str = "block_headers_array = program_input['block_headers_array']\nsegments.write_arg(ids.block_headers_array, block_headers_array)";

impl CustomHintProcessor {
    pub fn hint_input(
        &mut self,
        vm: &mut VirtualMachine,
        _exec_scope: &mut ExecutionScopes,
        hint_data: &HintProcessorData,
        _constants: &HashMap<String, Felt252>,
    ) -> Result<(), HintError> {
        let from_block_number_high: Felt252 =
            serde_json::from_value(self.private_inputs["from_block_number_high"].clone())
                .unwrap_or_default();
        let to_block_number_low: Felt252 =
            serde_json::from_value(self.private_inputs["to_block_number_low"].clone())
                .unwrap_or_default();
        let mmr_offset: Felt252 =
            serde_json::from_value(self.private_inputs["mmr_last_len"].clone()).unwrap_or_default();
        let mmr_last_root_poseidon: Felt252 =
            serde_json::from_value(self.private_inputs["mmr_last_root_poseidon"].clone())
                .unwrap_or_default();
        let block_n_plus_one_parent_hash: Felt252 =
            serde_json::from_value(self.private_inputs["block_n_plus_one_parent_hash"].clone())
                .unwrap_or_default();

        utils::write_value(
            "from_block_number_high",
            MaybeRelocatable::Int(from_block_number_high),
            vm,
            hint_data,
        )?;
        utils::write_value(
            "to_block_number_low",
            MaybeRelocatable::Int(to_block_number_low),
            vm,
            hint_data,
        )?;
        utils::write_value(
            "mmr_offset",
            MaybeRelocatable::Int(mmr_offset),
            vm,
            hint_data,
        )?;
        utils::write_value(
            "mmr_last_root_poseidon",
            MaybeRelocatable::Int(mmr_last_root_poseidon),
            vm,
            hint_data,
        )?;
        utils::write_value(
            "block_n_plus_one_parent_hash",
            MaybeRelocatable::Int(block_n_plus_one_parent_hash),
            vm,
            hint_data,
        )?;

        Ok(())
    }

    pub fn hint_input_prev(
        &mut self,
        vm: &mut VirtualMachine,
        _exec_scope: &mut ExecutionScopes,
        hint_data: &HintProcessorData,
        _constants: &HashMap<String, Felt252>,
    ) -> Result<(), HintError> {
        let poseidon_mmr_last_peaks: Vec<Felt252> =
            serde_json::from_value(self.private_inputs["poseidon_mmr_last_peaks"].clone()).unwrap();

        let previous_peaks_values_poseidon_ptr = get_ptr_from_var_name(
            "previous_peaks_values_poseidon",
            vm,
            &hint_data.ids_data,
            &hint_data.ap_tracking,
        )?;

        for (j, value) in poseidon_mmr_last_peaks
            .into_iter()
            .map(MaybeRelocatable::Int)
            .enumerate()
        {
            vm.insert_value((previous_peaks_values_poseidon_ptr + j)?, &value)?;
        }

        Ok(())
    }

    pub fn hint_input_block_headers(
        &mut self,
        vm: &mut VirtualMachine,
        _exec_scope: &mut ExecutionScopes,
        hint_data: &HintProcessorData,
        _constants: &HashMap<String, Felt252>,
    ) -> Result<(), HintError> {
        let block_headers_array: Vec<Vec<Felt252>> =
            serde_json::from_value(self.private_inputs["preimages_array"].clone()).unwrap();

        let block_headers_array_ptr = get_ptr_from_var_name(
            "block_headers_array",
            vm,
            &hint_data.ids_data,
            &hint_data.ap_tracking,
        )?;

        for (j, array) in block_headers_array.into_iter().enumerate() {
            let segment = vm.segments.add();
            for (k, value) in array.into_iter().map(MaybeRelocatable::Int).enumerate() {
                vm.insert_value((segment + k)?, &value)?;
            }
            vm.insert_value((block_headers_array_ptr + j)?, segment)?;
        }

        Ok(())
    }
}
