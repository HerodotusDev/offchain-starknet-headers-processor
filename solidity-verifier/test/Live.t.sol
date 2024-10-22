// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {SharpFactsAggregator} from "../src/SharpFactsAggregator.sol";
import {MockedSharpFactsRegistry} from "../src/mocks/MockFactsRegistry.sol";
import {IStarknet} from "../src/interfaces/IStarknet.sol";
import {console} from "forge-std/Console.sol";

contract Live is Test {
    SharpFactsAggregator aggregator;
    uint256 privateKey;

    constructor() {
        privateKey = vm.envUint("PRIVATE_KEY");
        string memory SEPOLIA_RPC_URL = vm.rpcUrl("sepolia");
        vm.createSelectFork(SEPOLIA_RPC_URL);

        //? For testing of a fully live contract use this:
        // address aggregatorAddress = address(
        //     0xF92800e310a44e2cb3301e45e99Febf997A093fE
        // );
        // aggregator = SharpFactsAggregator(aggregatorAddress);

        //? For debugging and changing the contract code, but using the actual facts registry use this:
        SharpFactsAggregator.AggregatorState
            memory initialAggregatorState = SharpFactsAggregator
                .AggregatorState({
                    poseidonMmrRoot: 0x06759138078831011e3bc0b4a135af21c008dda64586363531697207fb5a2bae,
                    mmrSize: 1,
                    continuableParentHash: 0x8d38275adfe450dbb8a8961ba1f4c7891309e6d97353aa7d712bb058dd2abeab
                });
        MockedSharpFactsRegistry factsRegistry = MockedSharpFactsRegistry(
            vm.envAddress("FACTS_REGISTRY_ADDRESS")
        );
        IStarknet starknet = IStarknet(
            vm.envAddress("STARKNET_CORE_L1_ADDRESS")
        );

        vm.startBroadcast(privateKey);
        factsRegistry.setValid(
            0xa2982e1ffe4de5c8540e7ecad6152f8bcf62f8f564573e9897bb99da55bb4851
        );
        aggregator = new SharpFactsAggregator(factsRegistry, starknet);
        aggregator.initialize(initialAggregatorState);
        vm.stopBroadcast();
    }

    function test_a() external {
        //? before this sync or continuable parent hash is requried:
        //
        // registerNewRange(6892937)
        //
        //? equivalent to putting this in SharpFactsAggregator's constructor:
        //
        // blockNumberToParentHash[
        //     6892937
        // ] = 0x8d38275adfe450dbb8a8961ba1f4c7891309e6d97353aa7d712bb058dd2abeab;
        //
        //? or
        //
        // aggregatorState
        //     .continuableParentHash = 0x8d38275adfe450dbb8a8961ba1f4c7891309e6d97353aa7d712bb058dd2abeab;

        SharpFactsAggregator.JobOutput[]
            memory jobOutputs = new SharpFactsAggregator.JobOutput[](1);

        jobOutputs[0] = SharpFactsAggregator.JobOutput({
            // 692d88 - 6892936
            fromBlockNumberHigh: 0x692d88,
            // 692d85 - 6892933
            toBlockNumberLow: 0x692d85,
            blockNPlusOneParentHash: 0x8d38275adfe450dbb8a8961ba1f4c7891309e6d97353aa7d712bb058dd2abeab,
            blockNMinusRPlusOneParentHash: 0x3d557adee5e7064f164bf5918deea80508b52978a2d7876cc247ecbbd5900b71,
            mmrPreviousRootPoseidon: 0x06759138078831011e3bc0b4a135af21c008dda64586363531697207fb5a2bae,
            mmrPreviousSize: 0x1,
            mmrNewRootPoseidon: 0x021274b8cfb5ba2ae9b1e2466122f933d24b9c1f21861878e8498fbcdd0f6141,
            mmrNewSize: 0x8
        });

        vm.startBroadcast(privateKey);
        aggregator.aggregateSharpJobs(jobOutputs);
    }
}
