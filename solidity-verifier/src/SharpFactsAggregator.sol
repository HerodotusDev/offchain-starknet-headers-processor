// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";

import {IFactsRegistry} from "./interfaces/IFactsRegistry.sol";
import {IStarknet} from "./interfaces/IStarknet.sol";
import {Uint256Splitter} from "./lib/Uint256Splitter.sol";

/// @title SharpFactsAggregator
/// @dev Aggregator contract to handle SHARP job outputs and update the global aggregator state.
/// @author Herodotus Dev
/// ------------------
/// Example:
/// Blocks inside brackets are the ones processed during their SHARP job execution
//  7 [8 9 10] 11
/// n = 10
/// r = 3
/// `r` is the number of blocks processed on a single SHARP job execution
/// `blockNMinusRPlusOneParentHash` = 8.parentHash (oldestHash)
/// `blockNPlusOneParentHash`       = 11.parentHash (newestHash)
/// ------------------
contract SharpFactsAggregator is Initializable, AccessControlUpgradeable {
    // Using inline library for efficient splitting and joining of uint256 values
    using Uint256Splitter for uint256;

    // Role definitions for access control
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UNLOCKER_ROLE = keccak256("UNLOCKER_ROLE");

    uint256 public constant MINIMUM_BLOCKS_CONFIRMATIONS = 20;
    uint256 public constant MAXIMUM_BLOCKS_CONFIRMATIONS = 255;

    // Sharp Facts Registry
    IFactsRegistry public immutable FACTS_REGISTRY;

    // Starknet core contract
    IStarknet public immutable STARKNET;

    // Cairo program hash (i.e., the off-chain block headers accumulator program)
    bytes32 public constant PROGRAM_HASH =
        bytes32(
            uint256(
                0x01eca36d586f5356fba096edbf7414017d51cd0ed24b8fde80f78b61a9216ed2
            )
        );

    // Global aggregator state
    struct AggregatorState {
        bytes32 poseidonMmrRoot;
        uint256 mmrSize;
        bytes32 continuableParentHash;
    }

    // Current __global__ state of this aggregator
    AggregatorState public aggregatorState;

    // Mapping to keep track of block number to its parent hash
    mapping(uint256 => bytes32) public blockNumberToParentHash;

    // Flag to control operator role requirements
    bool public isOperatorRequired;

    // Representation of the Cairo program's output (raw unpacked)
    struct JobOutput {
        uint256 fromBlockNumberHigh;
        uint256 toBlockNumberLow;
        bytes32 blockNPlusOneParentHash;
        bytes32 blockNMinusRPlusOneParentHash;
        bytes32 mmrPreviousRootPoseidon;
        uint256 mmrPreviousSize;
        bytes32 mmrNewRootPoseidon;
        uint256 mmrNewSize;
    }

    // Custom errors for better error handling and clarity
    error NotEnoughBlockConfirmations();
    error TooManyBlocksConfirmations();
    error NotEnoughJobs();
    error UnknownParentHash();
    error AggregationError(string message); // Generic error with a message
    error AggregationBlockMismatch();
    error GenesisBlockReached();
    error InvalidFact();

    // Event emitted when a new range is registered
    // (i.e, when we want to allow aggregating from a more recent block)
    event NewRangeRegistered(
        uint256 targetBlock,
        bytes32 targetBlockParentHash
    );

    // Event emitted when __at least__ one SHARP job is aggregated
    event Aggregate(
        uint256 fromBlockNumberHigh,
        uint256 toBlockNumberLow,
        bytes32 poseidonMmrRoot,
        uint256 mmrSize,
        bytes32 continuableParentHash
    );

    event OperatorRequirementChange(bool newRequirement);

    constructor(IFactsRegistry factsRegistry, IStarknet starknet) {
        FACTS_REGISTRY = factsRegistry;
        STARKNET = starknet;
    }

    /**
     * @notice Initializes the contract with given parameters.
     * @param initialAggregatorState Initial state of the aggregator (i.e., initial trees state).
     */
    function initialize(
        AggregatorState calldata initialAggregatorState
    ) public initializer {
        __AccessControl_init();

        aggregatorState = initialAggregatorState;

        _setRoleAdmin(OPERATOR_ROLE, OPERATOR_ROLE);
        _setRoleAdmin(UNLOCKER_ROLE, OPERATOR_ROLE);

        // Grant operator role to the contract deployer
        // to be able to define new aggregate ranges
        _grantRole(OPERATOR_ROLE, _msgSender());
        _grantRole(UNLOCKER_ROLE, _msgSender());

        // Set operator role requirement to true by default
        isOperatorRequired = true;
    }

    /// @notice Reverts if the caller is not an operator and the operator role requirement is enabled
    modifier onlyOperator() {
        if (isOperatorRequired) {
            require(
                hasRole(OPERATOR_ROLE, _msgSender()),
                "Caller is not an operator"
            );
        }
        _;
    }

    /// @notice Reverts if the caller is not an unlocker
    modifier onlyUnlocker() {
        require(
            hasRole(UNLOCKER_ROLE, _msgSender()),
            "Caller is not an unlocker"
        );
        _;
    }

    /// @dev Modifies the contract's operator requirement
    function setOperatorRequired(
        bool _isOperatorRequired
    ) external onlyUnlocker {
        isOperatorRequired = _isOperatorRequired;
        emit OperatorRequirementChange(_isOperatorRequired);
    }

    /// Registers a new range to aggregate from
    function registerNewRange() external onlyOperator {
        // From the starknet core contract get the latest settled block number
        uint256 latestSettledStarknetBlock = uint256(STARKNET.stateBlockNumber());

        // Extract its parent hash.
        bytes32 latestSettledStarknetBlockhash = bytes32(STARKNET.stateBlockHash());

        // Cache the parent hash so that we can later on continue accumlating from it
        blockNumberToParentHash[latestSettledStarknetBlock + 1] = latestSettledStarknetBlockhash;

        // If we cannot aggregate further in the past (e.g., genesis block is reached or it's a new tree)
        if (aggregatorState.continuableParentHash == bytes32(0)) {
            // Set the aggregator state's `continuableParentHash` to the target block's parent hash
            // so we can easily continue aggregating from it without specifying `rightBoundStartBlock` in `aggregateSharpJobs`
            aggregatorState.continuableParentHash = latestSettledStarknetBlockhash;
        }

        emit NewRangeRegistered(latestSettledStarknetBlock + 1, latestSettledStarknetBlockhash);
    }

    /// @notice Aggregate SHARP jobs outputs (min. 1) to update the global aggregator state
    /// @param rightBoundStartBlock The reference block to start from. Defaults to continuing from the global state if set to `0`
    /// @param outputs Array of SHARP jobs outputs (packed for Solidity)
    function aggregateSharpJobs(
        uint256 rightBoundStartBlock,
        JobOutput[] calldata outputs
    ) external onlyOperator {
        // Ensuring at least one job output is provided
        if (outputs.length < 1) {
            revert NotEnoughJobs();
        }

        bytes32 rightBoundStartBlockParentHash = bytes32(0);

        // Start from a different block than the current state if `rightBoundStartBlock` is specified
        if (rightBoundStartBlock != 0) {
            // Retrieve from cache the parent hash of the block to start from
            rightBoundStartBlockParentHash = blockNumberToParentHash[
                rightBoundStartBlock
            ];

            // If not present in the cache, hash is not authenticated and we cannot continue from it
            if (rightBoundStartBlockParentHash == bytes32(0)) {
                revert UnknownParentHash();
            }
        }

        JobOutput calldata firstOutput = outputs[0];
        // Ensure the first job is continuable
        ensureContinuable(rightBoundStartBlockParentHash, firstOutput);

        if (rightBoundStartBlockParentHash != bytes32(0)) {
            uint256 fromBlockHighStart = firstOutput.fromBlockNumberHigh;

            // We check that block numbers are consecutives
            if (fromBlockHighStart != rightBoundStartBlock - 1) {
                revert AggregationBlockMismatch();
            }
        }

        uint256 limit = outputs.length - 1;

        // Iterate over the jobs outputs (aside from the last one)
        // and ensure jobs are correctly linked and valid
        for (uint256 i = 0; i < limit; ++i) {
            JobOutput calldata curOutput = outputs[i];
            JobOutput calldata nextOutput = outputs[i + 1];

            ensureValidFact(curOutput);
            ensureConsecutiveJobs(curOutput, nextOutput);
        }

        JobOutput calldata lastOutput = outputs[limit];
        ensureValidFact(lastOutput);

        // We save the latest output in the contract state for future calls
        uint256 mmrNewSize = lastOutput.mmrNewSize;
        aggregatorState.poseidonMmrRoot = lastOutput.mmrNewRootPoseidon;
        aggregatorState.mmrSize = mmrNewSize;
        aggregatorState.continuableParentHash = lastOutput.blockNMinusRPlusOneParentHash;

        uint256 fromBlock = firstOutput.fromBlockNumberHigh;
        uint256 toBlock = firstOutput.toBlockNumberLow;

        emit Aggregate(
            fromBlock,
            toBlock,
            lastOutput.mmrNewRootPoseidon,
            mmrNewSize,
            lastOutput.blockNMinusRPlusOneParentHash
        );
    }

    /// @notice Ensures the fact is registered on SHARP Facts Registry
    /// @param output SHARP job output (packed for Solidity)
    function ensureValidFact(JobOutput memory output) internal view {
        uint256 fromBlock = output.fromBlockNumberHigh;
        uint256 toBlock = output.toBlockNumberLow;

        uint256 mmrPreviousSize = output.mmrPreviousSize;
        uint256 mmrNewSize = output.mmrNewSize;

        // We assemble the outputs in a uint256 array
        uint256[] memory outputs = new uint256[](8);
        outputs[0] = fromBlock;
        outputs[1] = toBlock;
        outputs[2] = uint256(output.blockNPlusOneParentHash);
        outputs[3] = uint256(output.blockNMinusRPlusOneParentHash);
        outputs[4] = uint256(output.mmrPreviousRootPoseidon);
        outputs[5] = mmrPreviousSize;
        outputs[6] = uint256(output.mmrNewRootPoseidon);
        outputs[7] = mmrNewSize;

        // We hash the outputs
        bytes32 outputHash = keccak256(abi.encodePacked(outputs));

        // We compute the deterministic fact bytes32 value
        bytes32 fact = keccak256(abi.encode(PROGRAM_HASH, outputHash));

        // We ensure this fact has been registered on SHARP Facts Registry
        if (!FACTS_REGISTRY.isValid(fact)) {
            revert InvalidFact();
        }
    }

    /// @notice Ensures the job output is cryptographically sound to continue from
    /// @param rightBoundStartParentHash The parent hash of the block to start from
    /// @param output The job output to check
    function ensureContinuable(
        bytes32 rightBoundStartParentHash,
        JobOutput memory output
    ) internal view {
        uint256 mmrPreviousSize = output.mmrPreviousSize;

        // Check that the job's previous Poseidon MMR root is the same as the one stored in the contract state
        if (output.mmrPreviousRootPoseidon != aggregatorState.poseidonMmrRoot)
            revert AggregationError("Poseidon root mismatch");

        // Check that the job's previous MMR size is the same as the one stored in the contract state
        if (mmrPreviousSize != aggregatorState.mmrSize)
            revert AggregationError("MMR size mismatch");

        if (rightBoundStartParentHash == bytes32(0)) {
            // If the right bound start parent hash __is not__ specified,
            // we check that the job's `blockN + 1 parent hash` is matching with the previously stored parent hash
            if (
                output.blockNPlusOneParentHash !=
                aggregatorState.continuableParentHash
            ) {
                revert AggregationError("Global state: Parent hash mismatch");
            }
        } else {
            // If the right bound start parent hash __is__ specified,
            // we check that the job's `blockN + 1 parent hash` is matching with a previously stored parent hash
            if (output.blockNPlusOneParentHash != rightBoundStartParentHash) {
                revert AggregationError("Parent hash mismatch");
            }
        }
    }

    /// @notice Ensures the job outputs are correctly linked
    /// @param output The job output to check
    /// @param nextOutput The next job output to check
    function ensureConsecutiveJobs(
        JobOutput memory output,
        JobOutput memory nextOutput
    ) internal pure {
        uint256 toBlock = output.toBlockNumberLow;

        // We cannot aggregate further past the genesis block
        if (toBlock == 0) {
            revert GenesisBlockReached();
        }

        uint256 nextFromBlock = nextOutput.fromBlockNumberHigh;

        // We check that the next job's `from block` is the same as the previous job's `to block + 1`
        if (toBlock - 1 != nextFromBlock) revert AggregationBlockMismatch();

        uint256 outputMmrNewSize = output.mmrNewSize;
        uint256 nextOutputMmrPreviousSize = nextOutput.mmrPreviousSize;

        // We check that the previous job's new Poseidon MMR root matches the next job's previous Poseidon MMR root
        if (output.mmrNewRootPoseidon != nextOutput.mmrPreviousRootPoseidon)
            revert AggregationError("Poseidon root mismatch");


        // We check that the previous job's new MMR size matches the next job's previous MMR size
        if (outputMmrNewSize != nextOutputMmrPreviousSize)
            revert AggregationError("MMR size mismatch");

        // We check that the previous job's lowest block hash matches the next job's highest block hash
        if (
            output.blockNMinusRPlusOneParentHash !=
            nextOutput.blockNPlusOneParentHash
        ) revert AggregationError("Parent hash mismatch");
    }

    /// @dev Helper function to verify a fact based on a job output
    function verifyFact(uint256[] memory outputs) external view returns (bool) {
        bytes32 outputHash = keccak256(abi.encodePacked(outputs));
        bytes32 fact = keccak256(abi.encode(PROGRAM_HASH, outputHash));

        return FACTS_REGISTRY.isValid(fact);
    }

    /// @notice Returns the current root hash of the Poseidon Merkle Mountain Range (MMR) tree
    function getMMRPoseidonRoot() external view returns (bytes32) {
        return aggregatorState.poseidonMmrRoot;
    }

    /// @notice Returns the current size of the Merkle Mountain Range (MMR) trees
    function getMMRSize() external view returns (uint256) {
        return aggregatorState.mmrSize;
    }
}
