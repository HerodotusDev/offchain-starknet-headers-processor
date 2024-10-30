use cairo_vm::hint_processor::builtin_hint_processor::builtin_hint_processor_definition::HintProcessorData;
use cairo_vm::hint_processor::builtin_hint_processor::hint_utils::get_integer_from_var_name;
use cairo_vm::types::exec_scope::ExecutionScopes;
use cairo_vm::vm::{errors::hint_errors::HintError, vm_core::VirtualMachine};
use cairo_vm::Felt252;
use std::collections::HashMap;

const HINT_PRINT_FINAL: &str = "print(\"new root poseidon\", ids.new_mmr_root_poseidon)\nprint(\"new size\", ids.mmr_array_len + ids.mmr_offset)";

fn hint_print_final(
    vm: &mut VirtualMachine,
    _exec_scope: &mut ExecutionScopes,
    hint_data: &HintProcessorData,
    _constants: &HashMap<String, Felt252>,
) -> Result<(), HintError> {
    let new_mmr_root_poseidon = get_integer_from_var_name(
        "new_mmr_root_poseidon",
        vm,
        &hint_data.ids_data,
        &hint_data.ap_tracking,
    )?;

    let mmr_array_len = get_integer_from_var_name(
        "mmr_array_len",
        vm,
        &hint_data.ids_data,
        &hint_data.ap_tracking,
    )?;

    let mmr_offset = get_integer_from_var_name(
        "mmr_offset",
        vm,
        &hint_data.ids_data,
        &hint_data.ap_tracking,
    )?;

    println!("new root poseidon: {}", new_mmr_root_poseidon);

    println!("new size: {}", mmr_array_len + mmr_offset);

    Ok(())
}

pub fn run_hint(
    vm: &mut VirtualMachine,
    exec_scope: &mut ExecutionScopes,
    hint_data: &HintProcessorData,
    constants: &HashMap<String, Felt252>,
) -> Result<(), HintError> {
    match hint_data.code.as_str() {
        HINT_PRINT_FINAL => hint_print_final(vm, exec_scope, hint_data, constants),
        _ => Err(HintError::UnknownHint(
            hint_data.code.to_string().into_boxed_str(),
        )),
    }
}
