%builtins output pedersen range_check ecdsa

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.dict import dict_new, dict_squash
from starkware.cairo.common.dict_access import DictAccess
from starkware.cairo.common.merkle_multi_update import merkle_multi_update
from starkware.cairo.common.squash_dict import squash_dict
from starkware.cairo.dex.dex_context import make_dex_context
from starkware.cairo.dex.execute_batch import execute_batch
from starkware.cairo.dex.execute_modification import ModificationOutput
from starkware.cairo.dex.hash_vault_ptr_dict import hash_vault_ptr_dict
from starkware.cairo.dex.l1_vault_update import L1VaultOutput, output_l1_vault_update_data
from starkware.cairo.dex.message_l1_order import L1OrderMessageOutput
from starkware.cairo.dex.vault_update import L2VaultState
from starkware.cairo.dex.volition import output_volition_data

const ONCHAIN_DATA_NONE = 0
const ONCHAIN_DATA_VAULTS = 1

struct DexOutput:
    member initial_vault_root : felt
    member final_vault_root : felt
    member initial_order_root : felt
    member final_order_root : felt
    member global_expiration_timestamp : felt
    member vault_tree_height : felt
    member order_tree_height : felt
    member onchain_data_version : felt
    member n_modifications : felt
    member n_conditional_transfers : felt
    member n_l1_vault_updates : felt
    member n_l1_order_messages : felt
end

func main(
        output_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr,
        ecdsa_ptr : SignatureBuiltin*) -> (
        output_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr,
        ecdsa_ptr : SignatureBuiltin*):
    # Create the globals struct.
    let dex_output = cast(output_ptr, DexOutput*)
    %{
        from starkware.cairo.dex.objects import DexProgramInput
        dex_program_input = DexProgramInput.Schema().load(program_input)
        ids.dex_output.vault_tree_height = dex_program_input.vault_tree_height
        ids.dex_output.order_tree_height = dex_program_input.order_tree_height
        ids.dex_output.global_expiration_timestamp = dex_program_input.global_expiration_timestamp
    %}
    alloc_locals
    let (dex_context_ptr) = make_dex_context(
        vault_tree_height=dex_output.vault_tree_height,
        order_tree_height=dex_output.order_tree_height,
        global_expiration_timestamp=dex_output.global_expiration_timestamp)

    local vault_dict : DictAccess*
    local order_dict : DictAccess*
    let modification_ptr = cast(output_ptr + DexOutput.SIZE, ModificationOutput*)
    local conditional_transfer_ptr : felt*
    local l1_vault_update_output_ptr : L1VaultOutput*
    local l1_order_message_ptr : L1OrderMessageOutput*
    %{
        from common.objects.transaction.common_transaction import OrderL1
        from common.objects.transaction.raw_transaction import ConditionalTransfer, Settlement
        from starkware.cairo.dex.main_hint_functions import update_l1_vault_balances
        from starkware.cairo.dex.vault_state_manager import L2VaultStateManager
        vault_state_segment = segments.add()
        vault_state_mgr = L2VaultStateManager(vault_state_segment=vault_state_segment)

        # Compute conditional_transfer_ptr based on n_modifications.
        transactions = dex_program_input.transactions
        n_modifications = sum(
          transaction.is_modification for transaction in transactions)
        ids.conditional_transfer_ptr = ids.modification_ptr.address_ + n_modifications * 3

        # Compute l1_vault_update_output_ptr based on n_conditional_transfers.
        n_conditional_transfers = len([
            tx for tx in transactions if isinstance(tx, ConditionalTransfer)])
        ids.l1_vault_update_output_ptr = \
            ids.conditional_transfer_ptr + n_conditional_transfers

        ids.vault_dict = segments.add()
        ids.order_dict = segments.add()
        ids.dex_output.initial_vault_root = int.from_bytes(
            dex_program_input.initial_vault_root, 'big')

        # initial_dict is a mapping from every L1 vault hash key to its minimal initial balance.
        # l1_vault_hash_key_to_explicit is a mapping from every L1 vault hash key (the key used in
        # DictAccess) to the original L1VaultKey object (the keys prior to the hash operation).
        initial_dict, l1_vault_hash_key_to_explicit = \
            update_l1_vault_balances(transactions=transactions)

        # Compute l1_order_message_ptr based on n_l1_vault_updates.
        n_l1_vault_updates = len(initial_dict)
        ids.l1_order_message_ptr = \
            ids.l1_vault_update_output_ptr.address_ + \
            n_l1_vault_updates * ids.L1VaultOutput.SIZE
    %}
    let (local l1_vault_dict : DictAccess*) = dict_new()
    %{
        vm_enter_scope({
            'transactions': transactions,
            'transaction_witnesses': dex_program_input.witnesses,
            'vault_state_mgr': vault_state_mgr,
            '__dict_manager': __dict_manager,
        })
    %}
    # Call execute_batch.
    # Advance output_ptr by DexOutput.SIZE, since DexOutput appears before other stuff.
    let executed_batch = execute_batch(
        modification_ptr=modification_ptr,
        conditional_transfer_ptr=conditional_transfer_ptr,
        l1_order_message_ptr=l1_order_message_ptr,
        l1_order_message_start_ptr=l1_order_message_ptr,
        hash_ptr=pedersen_ptr,
        range_check_ptr=range_check_ptr,
        ecdsa_ptr=ecdsa_ptr,
        vault_dict=vault_dict,
        l1_vault_dict=l1_vault_dict,
        order_dict=order_dict,
        dex_context_ptr=dex_context_ptr)
    let range_check_ptr = executed_batch.range_check_ptr
    %{ vm_exit_scope() %}

    # Assert conditional transfer data starts where modification data ends.
    conditional_transfer_ptr = executed_batch.modification_ptr

    # Store conditional transfer and L1 order signature end pointer.
    local conditional_transfer_end_ptr : felt* = executed_batch.conditional_transfer_ptr
    local l1_order_message_end_ptr : felt* = executed_batch.l1_order_message_ptr

    # Calculate n_modifications in the output from the number of modifications in the output.
    assert dex_output.n_modifications = (
        cast(conditional_transfer_ptr, felt) - (cast(output_ptr, felt) + DexOutput.SIZE)) /
        ModificationOutput.SIZE

    # Calculate n_conditional_transfers in the output from the number of conditional transfers in
    # the output.
    assert dex_output.n_conditional_transfers = (
        conditional_transfer_end_ptr - conditional_transfer_ptr)

    # Calculate n_l1_order_messages in the output from the number of L1 order signatures
    # in the output.
    assert dex_output.n_l1_order_messages = (
        cast(l1_order_message_end_ptr, felt) - cast(l1_order_message_ptr, felt)) /
        L1OrderMessageOutput.SIZE

    # Store builtin pointers.
    local hash_ptr_after_execute_batch : HashBuiltin* = executed_batch.hash_ptr
    local ecdsa_ptr_after_execute_batch : SignatureBuiltin* = executed_batch.ecdsa_ptr
    local l1_vault_dict_end : DictAccess* = executed_batch.l1_vault_dict
    local order_dict_end : DictAccess* = executed_batch.order_dict

    # Check that the vault and order accesses recorded in vault_dict and dict_vault are
    # valid lists of dict accesses and squash them to obtain squashed dicts
    # (squashed_vault_dict and squashed_order_dict) with one entry per key
    # (value before and value after) which summarizes all the accesses to that key.

    # Squash the vault_dict.
    local squashed_vault_dict : DictAccess*
    %{ ids.squashed_vault_dict = segments.add() %}
    with range_check_ptr:
        let (squash_vault_dict_ret) = squash_dict(
            dict_accesses=vault_dict,
            dict_accesses_end=executed_batch.vault_dict,
            squashed_dict=squashed_vault_dict)
        local squashed_vault_dict_segment_size = squash_vault_dict_ret - squashed_vault_dict

        # Squash the l1_vault_dict.
        let (local squashed_l1_vault_dict, local squash_l1_vault_dict_ret) = dict_squash(
            dict_accesses_start=l1_vault_dict, dict_accesses_end=l1_vault_dict_end)

        assert dex_output.n_l1_vault_updates = (
            squash_l1_vault_dict_ret - squashed_l1_vault_dict) / DictAccess.SIZE

        # Squash the order_dict.
        local squashed_order_dict : DictAccess*
        %{ ids.squashed_order_dict = segments.add() %}
        let (squash_order_dict_ret) = squash_dict(
            dict_accesses=order_dict,
            dict_accesses_end=order_dict_end,
            squashed_dict=squashed_order_dict)
    end
    local squashed_order_dict_segment_size = squash_order_dict_ret - squashed_order_dict
    local range_check_ptr_after_squash_order_dict = range_check_ptr

    # The squashed_vault_dict holds pointers to vault states instead of vault tree leaf values.
    # Call hash_vault_ptr_dict to obtain a new dict that can be passed to merkle_multi_update.
    local hashed_vault_dict : DictAccess*
    %{ ids.hashed_vault_dict = segments.add() %}
    let (hash_ptr) = hash_vault_ptr_dict(
        hash_ptr=hash_ptr_after_execute_batch,
        vault_ptr_dict=squashed_vault_dict,
        n_entries=squashed_vault_dict_segment_size / DictAccess.SIZE,
        vault_hash_dict=hashed_vault_dict)

    %{
        def as_int(x):
          return int.from_bytes(x, 'big')

        preimage = {
          as_int(root): (as_int(left_child), as_int(right_child))
          for root, left_child, right_child in dex_program_input.merkle_facts
        }

        ids.dex_output.initial_vault_root = int.from_bytes(
            dex_program_input.initial_vault_root, 'big')
        ids.dex_output.final_vault_root = int.from_bytes(
            dex_program_input.final_vault_root, 'big')

        ids.dex_output.initial_order_root = int.from_bytes(
            dex_program_input.initial_order_root, 'big')
        ids.dex_output.final_order_root = int.from_bytes(
            dex_program_input.final_order_root, 'big')

        vm_enter_scope({'preimage': preimage})
    %}

    with hash_ptr:
        # Verify hashed_vault_dict consistency with the vault merkle root.
        merkle_multi_update(
            update_ptr=hashed_vault_dict,
            n_updates=squashed_vault_dict_segment_size / DictAccess.SIZE,
            height=dex_output.vault_tree_height,
            prev_root=dex_output.initial_vault_root,
            new_root=dex_output.final_vault_root)

        # Verify squashed_order_dict consistency with the order merkle root.
        merkle_multi_update(
            update_ptr=squashed_order_dict,
            n_updates=squashed_order_dict_segment_size / DictAccess.SIZE,
            height=dex_output.order_tree_height,
            prev_root=dex_output.initial_order_root,
            new_root=dex_output.final_order_root)
    end
    %{ vm_exit_scope() %}

    # Output L1 vault updates.
    assert l1_vault_update_output_ptr = cast(conditional_transfer_end_ptr, L1VaultOutput*)
    let range_check_ptr = range_check_ptr_after_squash_order_dict
    output_l1_vault_update_data{
        range_check_ptr=range_check_ptr,
        pedersen_ptr=hash_ptr,
        l1_vault_ptr=l1_vault_update_output_ptr}(
        squashed_dict=squashed_l1_vault_dict, squashed_dict_end_ptr=squash_l1_vault_dict_ret)
    assert l1_order_message_ptr = (
        cast(l1_vault_update_output_ptr, L1OrderMessageOutput*))
    let output_ptr : felt* = l1_order_message_end_ptr
    local pedersen_ptr_end : HashBuiltin* = hash_ptr

    # Output onchain data availability if necessary.
    %{
        assert dex_program_input.onchain_data_version in [
            ids.ONCHAIN_DATA_NONE, ids.ONCHAIN_DATA_VAULTS], \
            'Onchain-data version is not supported.'
        ids.dex_output.onchain_data_version = dex_program_input.onchain_data_version
    %}
    if dex_output.onchain_data_version == ONCHAIN_DATA_NONE:
        return (
            output_ptr=output_ptr,
            pedersen_ptr=pedersen_ptr_end,
            range_check_ptr=range_check_ptr,
            ecdsa_ptr=ecdsa_ptr_after_execute_batch)
    end

    assert dex_output.onchain_data_version = ONCHAIN_DATA_VAULTS
    %{ onchain_data_start = ids.output_ptr %}
    let (output_ptr, range_check_ptr) = output_volition_data(
        output_ptr=output_ptr,
        range_check_ptr=range_check_ptr,
        squashed_vault_dict=squashed_vault_dict,
        n_updates=squashed_vault_dict_segment_size / DictAccess.SIZE)
    %{
        from starkware.python.math_utils import div_ceil
        onchain_data_size = ids.output_ptr - onchain_data_start

        max_page_size = dex_program_input.max_n_words_per_memory_page
        n_pages = div_ceil(onchain_data_size, max_page_size)
        for i in range(n_pages):
            start_offset = i * max_page_size
            output_builtin.add_page(
                page_id=1 + i,
                page_start=onchain_data_start + start_offset,
                page_size=min(onchain_data_size - start_offset, max_page_size),
            )
        # Set the tree structure to a root with two children:
        # * A leaf which represents the main part
        # * An inner node for the onchain data part (which contains n_pages children).
        #
        # This is encoded using the following sequence:
        output_builtin.add_attribute('gps_fact_topology', [
            # Push 1 + n_pages pages (all of the pages).
            1 + n_pages,
            # Create a parent node for the last n_pages.
            n_pages,
            # Don't push additional pages.
            0,
            # Take the first page (the main part) and the node that was created (onchain data)
            # and use them to construct the root of the fact tree.
            2,
        ])
    %}

    # Return updated pointers.
    return (
        output_ptr=output_ptr,
        pedersen_ptr=pedersen_ptr_end,
        range_check_ptr=range_check_ptr,
        ecdsa_ptr=ecdsa_ptr_after_execute_batch)
end
